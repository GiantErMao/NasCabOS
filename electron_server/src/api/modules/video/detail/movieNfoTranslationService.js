'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { XMLValidator } = require('fast-xml-parser');
const tableConfig = require('../../../../db/table/tableConfig');
const nascabAccountUtil = require('../../service/utils/nascabAccountUtil');
const { MetadataTranslateClient, normalizeTranslateApiUrl } = require('../../../../workers/videoIndex/nfoFetchWorker/metadataTranslateClient');
const { parseNfoXml } = require('../../../../workers/videoIndex/nfoParser');
const videoIndexIndexUtil = require('../../../../workers/videoIndex/videoIndexIndexUtil');
const { translateMovieNfoXml } = require('./movieNfoTranslation');

function serviceError(message, statusCode) {
  return Object.assign(new Error(message), { statusCode });
}

async function writeNfoAtomically(target, xml) {
  const oldStat = await fs.promises.stat(target);
  const mode = oldStat.mode & 0o7777;
  const temporary = path.join(path.dirname(target), `.nfo-translate-${crypto.randomUUID()}.tmp`);
  try {
    await fs.promises.writeFile(temporary, xml, { encoding: 'utf8', mode });
    await fs.promises.chmod(temporary, mode);
    try {
      await fs.promises.chown(temporary, oldStat.uid, oldStat.gid);
    } catch (error) {
      if (error.code !== 'EPERM') throw error;
    }
    await fs.promises.rename(temporary, target);
  } finally {
    await fs.promises.unlink(temporary).catch(error => {
      if (error.code !== 'ENOENT') throw error;
    });
  }
}

async function translateMovieNfo({ knexVideo, knexMain, indexId }) {
  if (!Number.isSafeInteger(indexId) || indexId <= 0) throw serviceError('Invalid movie index', 400);
  const row = await knexVideo('video_index').where({ id: indexId }).first('id', 'path', 'filename', 'media_type', 'nfo_number', 'movie_group_key');
  if (!row || !['movie', 'bdmv', 'video_ts'].includes(row.media_type)) throw serviceError('Movie not found', 404);

  const isFolder = row.media_type !== 'movie';
  const fullPath = path.join(row.path, row.filename);
  const found = isFolder
    ? await videoIndexIndexUtil.findAndParseNfoForMovieFolder(fullPath)
    : await videoIndexIndexUtil.findAndParseNfoForVideo(fullPath);
  if (!found.nfoPath || !found.parsed || found.parsed.type !== 'movie') throw serviceError('Movie NFO not found', 404);
  const original = await fs.promises.readFile(found.nfoPath, 'utf8');
  if (XMLValidator.validate(original) !== true) throw serviceError('Invalid movie NFO', 422);

  const [apiUrlRaw, apiKeyRaw] = await Promise.all([
    tableConfig.getConfigByKey('nfoTranslateApiUrl'),
    nascabAccountUtil.getDecryptedConfigValue(knexMain, tableConfig, 'nfoTranslateApiKey'),
  ]);
  const translator = new MetadataTranslateClient({
    targetLanguage: 'zh-CN',
    apiUrl: normalizeTranslateApiUrl(apiUrlRaw),
    apiKey: apiKeyRaw ? String(apiKeyRaw).trim() : '',
  });
  const result = await translateMovieNfoXml(original, found.parsed, translator, { number: row.nfo_number });
  if (result.skipped) return { skipped: true, translatedFields: [] };
  if (XMLValidator.validate(result.xml) !== true) throw serviceError('Translated movie NFO is invalid', 422);
  const parsed = parseNfoXml(result.xml);
  if (!parsed || parsed.type !== 'movie') throw serviceError('Translated movie NFO is invalid', 422);

  await writeNfoAtomically(found.nfoPath, result.xml);
  try {
    const siblings = row.media_type === 'movie' && row.movie_group_key
      ? await knexVideo('video_index').where({ path: row.path, media_type: 'movie', movie_group_key: row.movie_group_key }).select('id', 'filename', 'media_type')
      : [row];
    await knexVideo.transaction(async trx => {
      for (const sibling of siblings) {
        const fields = videoIndexIndexUtil.buildNfoFieldsFromParsed(parsed, {
          filename: sibling.filename,
          isDirectory: isFolder,
          directoryName: path.basename(row.path),
        });
        await trx('video_index').where({ id: sibling.id }).update(fields);
        await videoIndexIndexUtil.syncVideoIndex2KeyFromNfoFields({
          knex: trx,
          indexId: sibling.id,
          mediaType: sibling.media_type,
          nfoRegions: fields.nfo_regions,
          nfoGenres: fields.nfo_genres,
        });
      }
    });
  } catch (error) {
    await writeNfoAtomically(found.nfoPath, original).catch(() => {});
    throw error;
  }
  return { skipped: false, translatedFields: result.changedFields };
}

module.exports = { translateMovieNfo };
