'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const sharp = require('../../../utils/sharpConfigured');

const Logger = require('../../../utils/logger');
const FileUtil = require('../../../utils/fileUtil');
const dbUtil = require('../../../db/dbUtil');
const knexUtil = require('../../../db/knexUtil');
const tableConfig = require('../../../db/table/tableConfig');
const tableVideoSource = require('../../../db/table/tableVideoSource');
const config = require('../../../config/config');
const nascabAccountUtil = require('../../../api/modules/service/utils/nascabAccountUtil');

const { TmdbClient } = require('./tmdbClient');
const { MetaTubeClient, DEFAULT_METATUBE_BASE_URL, normalizeMetaTubeBaseUrl, parseMetaTubeScrapeId, buildMetaTubeScrapeId } = require('./metatubeClient');
const { MetadataTranslateClient, normalizeTranslateApiUrl, normalizeTranslateTargetLanguage } = require('./metadataTranslateClient');
const { buildMovieNfo, buildTvShowNfo, buildSeasonNfo, buildEpisodeNfo, writeTextIfChanged } = require('./jellyfinNfo');
const { addMetaTubeFilenameTags, mergeMovieMetadataGenres } = require('./metatubeFilenameTags');
const videoIndexIndexUtil = require('../videoIndexIndexUtil');
const { parseMoviePart, movieMetadataBaseName, moviePartBaseNamesInDirectory, whereMovieRepresentative } = require('../movieParts');
const { readAndParseNfo, hasValidNfo } = require('../nfoParser');
const { parseSeasonNumberFromName, parseEpisodeFromName, normalizeNameForNfoGuess } = require('../videoIndexUtil');
const tmdbUtil = require('./tmdbUtil');
const { extractMetaTubeNumberQueryFromText: _extractMetaTubeNumberQueryFromText, normalizeComparableMetaTubeNumber: _normalizeComparableMetaTubeNumber } = require('./metatubeNumber');
function _pickYearFromText(s) {
  const m = String(s || '').match(/\b(19|20)\d{2}\b/);
  const y = m ? Number(m[0]) : 0;
  return y >= 1900 && y <= 2100 ? y : 0;
}

function _cleanSearchText(text) {
  const raw = String(text || '').trim();
  if (!raw) return '';
  const tokens = tmdbUtil.getSearchTokens(raw).tokens || [];
  if (tokens.length > 0) return tokens.join(' ').trim();
  return raw.replace(/\s+/g, ' ').trim();
}

function _normalizeSearchTitleFromFileName(filename) {
  const part = parseMoviePart(filename);
  const base = part ? part.titleStem : path.parse(String(filename || '')).name;
  const norm = normalizeNameForNfoGuess(base);
  return norm || base;
}

function _extractMetaTubeNumberQueryFromFilename(filename) {
  const base = path.parse(String(filename || '')).name;
  return _extractMetaTubeNumberQueryFromText(base);
}

const _SKIP_NAME_HINTS = ['img_', 'video_', 'vid_', 'samsung_', 'short_', 'clip_', 'weixin_', 'wx_', 'dsc_', 'douyin_', 'xiaohongshu_', 'baiduyun_', 'mmexport'];

function _hasSkipNameHint(filename) {
  const s = String(filename || '').toLowerCase();
  if (!s) return false;
  return _SKIP_NAME_HINTS.some(t => s.includes(t));
}

function _shouldSkipByDurationSeconds(duration) {
  const d = Number(duration || 0) || 0;
  return d > 0 && d < 20 * 60;
}

function _isPureNumberText(text) {
  const s = String(text || '').trim();
  if (!s) return false;
  return /^\d+$/.test(s);
}

function _buildQueryAttemptsFromText(text) {
  const { tokens, year } = tmdbUtil.getSearchTokens(text);
  if (tokens.length === 0) return [];

  const seen = new Set();
  const out = [];
  const push = (q, y) => {
    const query = String(q || '').trim();
    const yr = Number(y || 0) || 0;
    if (!query) return;
    const key = `${query}||${yr || ''}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ query, year: yr });
  };

  for (let i = tokens.length; i >= 1; i -= 1) {
    const q = tokens.slice(0, i).join(' ').trim();
    if (!q || q.length < 2) continue;
    if (year) push(q, year);
    push(q, 0);
  }

  return out;
}

/** 与前端国际化 13 种语言一致，将 locale 规范为 TMDB 的 language 格式 */
function _normalizeToTmdbLanguage(locale) {
  const raw = String(locale || '').trim();
  if (!raw || raw === 'system') return '';
  const primary = raw.split(/[-_]/)[0].toLowerCase();
  const map = {
    zh: 'zh-CN',
    en: 'en-US',
    es: 'es-ES',
    fr: 'fr-FR',
    de: 'de-DE',
    ja: 'ja-JP',
    pt: 'pt-BR',
    ru: 'ru-RU',
    ar: 'ar-SA',
    ko: 'ko-KR',
    th: 'th-TH',
    vi: 'vi-VN',
    id: 'id-ID',
  };
  if (map[primary]) return map[primary];
  if (/^[a-z]{2}-[A-Z]{2}$/.test(raw)) return raw;
  return '';
}

function _getSystemLocale() {
  try {
    const v = Intl.DateTimeFormat().resolvedOptions().locale;
    return String(v || '').trim();
  } catch (_) {
    return '';
  }
}

function _pickList(arr, mapper, max = 0) {
  const list = Array.isArray(arr) ? arr : [];
  const out = [];
  for (const it of list) {
    const v = mapper(it);
    if (!v) continue;
    out.push(v);
    if (max > 0 && out.length >= max) break;
  }
  return out;
}

function _tmdbImageUrl(client, filePath) {
  if (!client) return '';
  return client.buildImageUrl(filePath);
}

function _mapCreditsToPeople({ client, credits }) {
  const cast = credits && Array.isArray(credits.cast) ? credits.cast : [];
  const crew = credits && Array.isArray(credits.crew) ? credits.crew : [];

  const actors = _pickList(
    cast,
    c => {
      const name = c && c.name ? String(c.name).trim() : '';
      if (!name) return null;
      const role = c && c.character ? String(c.character).trim() : '';
      const tmdbId = c && c.id ? String(c.id) : '';
      const thumb = c && c.profile_path ? _tmdbImageUrl(client, c.profile_path) : '';
      return { name, role, tmdbId, thumb };
    },
    30
  );

  const directors = _pickList(
    crew.filter(c => c && String(c.job || '').toLowerCase() === 'director'),
    c => {
      const name = c && c.name ? String(c.name).trim() : '';
      if (!name) return null;
      const tmdbId = c && c.id ? String(c.id) : '';
      const thumb = c && c.profile_path ? _tmdbImageUrl(client, c.profile_path) : '';
      return { name, tmdbId, thumb };
    },
    10
  );

  return { actors, directors };
}

function _mapMovieToNfo({ client, movie }) {
  const m = movie && typeof movie === 'object' ? movie : {};
  const { actors, directors } = _mapCreditsToPeople({ client, credits: m.credits });
  const genres = _pickList(m.genres, g => (g && g.name ? String(g.name) : ''), 0);
  const countries = _pickList(m.production_countries, c => (c && c.name ? String(c.name) : ''), 0);
  const languages = _pickList(m.spoken_languages, l => (l && l.english_name ? String(l.english_name) : l && l.name ? String(l.name) : ''), 0);
  const year = _pickYearFromText(m.release_date);
  const imdbId = m.external_ids && m.external_ids.imdb_id ? String(m.external_ids.imdb_id) : '';
  return {
    title: m.title || m.name || '',
    originalTitle: m.original_title || '',
    sortTitle: '',
    year,
    premiered: m.release_date || '',
    plot: m.overview || '',
    rating: m.vote_average ? Number(m.vote_average) : 0,
    genres,
    tags: [],
    countries,
    languages,
    tmdbId: m.id ? String(m.id) : '',
    imdbId,
    actors,
    directors,
  };
}

function _pickDateText(v) {
  const s = String(v || '').trim();
  if (!s) return '';
  const m = s.match(/^\d{4}-\d{2}-\d{2}/);
  const year = m ? Number(m[0].slice(0, 4)) : 0;
  return year >= 1900 && year <= 2100 ? m[0] : '';
}

function _mapMetaTubeMovieToNfo(movie) {
  const m = movie && typeof movie === 'object' ? movie : {};
  const provider = m.provider ? String(m.provider).trim() : '';
  const id = m.id ? String(m.id).trim() : '';
  const number = m.number ? String(m.number).trim() : '';
  const title = m.title ? String(m.title).trim() : '';
  const releaseDate = _pickDateText(m.release_date);
  const actors = _pickList(m.actors, a => {
    const name = a ? String(a).trim() : '';
    return name ? { name } : null;
  }, 40);
  const directors = _pickList([m.director], d => {
    const name = d ? String(d).trim() : '';
    return name ? { name } : null;
  }, 1);
  const tags = _pickList([number, provider, m.maker, m.label, m.series], v => (v ? String(v).trim() : ''), 0);
  const genres = _pickList(m.genres, g => (g ? String(g).trim() : ''), 0);

  return {
    title: title || number || id,
    originalTitle: number || '',
    sortTitle: number || title || '',
    year: _pickYearFromText(releaseDate),
    premiered: releaseDate,
    plot: m.summary || '',
    rating: m.score ? Number(m.score) : 0,
    genres,
    tags,
    countries: [],
    languages: [],
    tmdbId: buildMetaTubeScrapeId(provider, id) || id,
    imdbId: '',
    actors,
    directors,
  };
}

function _mapTvToNfo({ client, tv }) {
  const t = tv && typeof tv === 'object' ? tv : {};
  const { actors, directors } = _mapCreditsToPeople({ client, credits: t.credits });
  const genres = _pickList(t.genres, g => (g && g.name ? String(g.name) : ''), 0);
  const countries = _pickList(t.origin_country, c => (c ? String(c) : ''), 0);
  const languages = _pickList(t.languages, l => (l ? String(l) : ''), 0);
  const year = _pickYearFromText(t.first_air_date);
  const imdbId = t.external_ids && t.external_ids.imdb_id ? String(t.external_ids.imdb_id) : '';
  const studio = _pickList(t.networks, n => (n && n.name ? String(n.name) : ''), 1)[0] || '';
  return {
    title: t.name || '',
    originalTitle: t.original_name || '',
    sortTitle: '',
    year,
    premiered: t.first_air_date || '',
    plot: t.overview || '',
    rating: t.vote_average ? Number(t.vote_average) : 0,
    genres,
    tags: [],
    countries,
    languages,
    studio,
    tmdbId: t.id ? String(t.id) : '',
    imdbId,
    actors,
    directors,
  };
}

function _mapSeasonToNfo({ client, tvId, season }) {
  const s = season && typeof season === 'object' ? season : {};
  const { actors, directors } = _mapCreditsToPeople({ client, credits: s.credits });
  const year = _pickYearFromText(s.air_date);
  return {
    title: s.name || `Season ${s.season_number || ''}`,
    seasonNumber: Number(s.season_number || 0) || 0,
    year,
    premiered: s.air_date || '',
    plot: s.overview || '',
    rating: s.vote_average ? Number(s.vote_average) : 0,
    tmdbId: s.id ? String(s.id) : tvId ? `${tvId}:${s.season_number || ''}` : '',
    actors,
    directors,
  };
}

function _mapEpisodeToNfo({ client, episode }) {
  const e = episode && typeof episode === 'object' ? episode : {};
  const { actors, directors } = _mapCreditsToPeople({ client, credits: e.credits });
  return {
    title: e.name || '',
    seasonNumber: Number(e.season_number || 0) || 0,
    episodeNumber: Number(e.episode_number || 0) || 0,
    aired: e.air_date || '',
    plot: e.overview || '',
    rating: e.vote_average ? Number(e.vote_average) : 0,
    tmdbId: e.id ? String(e.id) : '',
    actors,
    directors,
  };
}

async function _translateNfoData(translator, data, { translateTitle = false, translateGenres = true, translatePlot = true } = {}) {
  if (!translator || !data || typeof data !== 'object') return data;
  const out = { ...data };
  try {
    const changed = [];
    if (translatePlot && out.plot) {
      const before = String(out.plot || '').trim();
      out.plot = await translator.translateText(out.plot);
      if (String(out.plot || '').trim() !== before) changed.push('plot');
    }
    if (translateGenres && Array.isArray(out.genres) && out.genres.length > 0) {
      const before = out.genres.map(v => String(v || '').trim()).filter(Boolean).join('\n');
      out.genres = await translator.translateList(out.genres);
      const after = out.genres.map(v => String(v || '').trim()).filter(Boolean).join('\n');
      if (after !== before) changed.push('genres');
    }
    if (translateTitle && out.title) {
      const before = String(out.title || '').trim();
      out.title = await translator.translateText(out.title);
      if (String(out.title || '').trim() !== before) changed.push('title');
    }
    if (changed.length > 0) {
      Logger.info(`[nfoTranslate] translated fields: ${changed.join(',')}`);
    } else if ((translatePlot && data.plot) || (translateGenres && Array.isArray(data.genres) && data.genres.length > 0) || (translateTitle && data.title)) {
      Logger.warn('[nfoTranslate] enabled but translated text unchanged');
    }
  } catch (e) {
    Logger.warn('[nfoTranslate] failed, keep original metadata', e && e.message ? e.message : e);
  }
  return out;
}

function _mergeMetaTubeMovie(searchItem, details) {
  const base = searchItem && typeof searchItem === 'object' ? searchItem : {};
  const detail = details && typeof details === 'object' ? details : {};
  return {
    ...base,
    ...detail,
    provider: detail.provider || base.provider,
    id: detail.id || base.id,
    number: detail.number || base.number,
    title: detail.title || base.title,
    summary: detail.summary || base.summary,
    genres: Array.isArray(detail.genres) && detail.genres.length > 0 ? detail.genres : base.genres,
    actors: Array.isArray(detail.actors) && detail.actors.length > 0 ? detail.actors : base.actors,
    cover_url: detail.cover_url || base.cover_url,
    big_cover_url: detail.big_cover_url || base.big_cover_url,
    thumb_url: detail.thumb_url || base.thumb_url,
    big_thumb_url: detail.big_thumb_url || base.big_thumb_url,
  };
}

function _scoreMetaTubeMovie(movie) {
  const m = movie && typeof movie === 'object' ? movie : {};
  let score = 0;
  if (String(m.title || '').trim()) score += 10;
  if (String(m.number || '').trim()) score += 5;
  if (String(m.summary || '').trim()) score += 1000 + Math.min(500, String(m.summary || '').trim().length);
  if (Array.isArray(m.genres) && m.genres.length > 0) score += 200 + Math.min(50, m.genres.length * 5);
  if (Array.isArray(m.actors) && m.actors.length > 0) score += 50;
  if (m.cover_url || m.big_cover_url || m.thumb_url || m.big_thumb_url) score += 25;
  return score;
}

function _pickLogoPathFromImages(images) {
  const logos = images && Array.isArray(images.logos) ? images.logos : [];
  if (!logos || logos.length === 0) return '';
  const pick = logos.find(l => l && String(l.iso_639_1 || '').toLowerCase() === 'zh') || logos.find(l => l && String(l.iso_639_1 || '').toLowerCase() === 'en') || logos[0];
  return pick && pick.file_path ? String(pick.file_path) : '';
}

const MAX_ARTWORK_FILENAME_BYTES = 180;

function _utf8ByteLength(value) {
  return Buffer.byteLength(String(value || ''), 'utf8');
}

function _hashText(value) {
  return crypto.createHash('sha1').update(String(value || '')).digest('hex').slice(0, 10);
}

function _safeArtworkFileName(fileName) {
  const raw = String(fileName || '').trim();
  if (!raw) return '';
  if (_utf8ByteLength(raw) <= MAX_ARTWORK_FILENAME_BYTES) return raw;

  const ext = path.extname(raw) || '.jpg';
  const base = path.basename(raw, ext);
  const normalized = base.toLowerCase();
  if (normalized.endsWith('-poster')) return `poster${ext}`;
  if (normalized.endsWith('-fanart')) return `fanart${ext}`;
  if (normalized.endsWith('-logo')) return `logo${ext}`;

  const hash = _hashText(raw);
  const suffix = `-${hash}${ext}`;
  let out = '';
  for (const ch of base) {
    const next = `${out}${ch}`;
    if (_utf8ByteLength(`${next}${suffix}`) > MAX_ARTWORK_FILENAME_BYTES) break;
    out = next;
  }
  return `${out || 'artwork'}${suffix}`;
}

function _resolveArtworkOutputPath(baseDir, fileName) {
  const dir = String(baseDir || '').trim();
  const safeName = _safeArtworkFileName(fileName);
  if (!dir || !safeName) return '';
  return path.join(dir, safeName);
}

function _resolveArtworkTempPath(baseDir, outPath, filePath) {
  const dir = String(baseDir || '').trim() || path.dirname(String(outPath || ''));
  const hash = _hashText(`${outPath || ''}|${filePath || ''}|${Date.now()}`);
  return path.join(dir, `.nfo-img-${hash}`);
}

async function _ensureDownloaded(client, baseDir, fileName, filePath) {
  const fp = String(filePath || '').trim();
  const out = _resolveArtworkOutputPath(baseDir, fileName);
  if (!fp || !out) return false;
  try {
    if (fs.existsSync(out) && fs.statSync(out).isFile()) return false;
  } catch (_) {}

  const url = client.buildImageUrl(fp);
  if (!url) return false;

  const tmp = _resolveArtworkTempPath(baseDir, out, fp);
  const ok = await client.downloadToFile(url, tmp);
  if (!ok) return false;
  try {
    await sharp(tmp)
      .jpeg({ quality: 85 })
      .toFile(out);
    try { fs.unlinkSync(tmp); } catch (_) {}
    return true;
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_) {}
    try { fs.unlinkSync(out); } catch (_) {}
    return false;
  }
}

async function _ensureDownloadedJpeg(client, baseDir, fileName, filePath) {
  const fp = String(filePath || '').trim();
  const out = _resolveArtworkOutputPath(baseDir, fileName);
  if (!fp || !out) return false;
  try {
    if (fs.existsSync(out) && fs.statSync(out).isFile()) return false;
  } catch (_) {}

  const url = client.buildImageUrl(fp);
  if (!url) return false;

  const tmp = _resolveArtworkTempPath(baseDir, out, fp);
  const ok = await client.downloadToFile(url, tmp);
  if (!ok) return false;
  try {
    await sharp(tmp)
      .jpeg({ quality: 85 })
      .toFile(out);
    try { fs.unlinkSync(tmp); } catch (_) {}
    return true;
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_) {}
    try { fs.unlinkSync(out); } catch (_) {}
    return false;
  }
}

async function _ensureDownloadedPng(client, baseDir, fileName, filePath) {
  const fp = String(filePath || '').trim();
  const out = _resolveArtworkOutputPath(baseDir, fileName);
  if (!fp || !out) return false;
  try {
    if (fs.existsSync(out) && fs.statSync(out).isFile()) return false;
  } catch (_) {}

  const url = client.buildImageUrl(fp);
  if (!url) return false;

  const tmp = _resolveArtworkTempPath(baseDir, out, fp);
  const ok = await client.downloadToFile(url, tmp);
  if (!ok) return false;
  try {
    await sharp(tmp)
      .png()
      .toFile(out);
    try { fs.unlinkSync(tmp); } catch (_) {}
    return true;
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_) {}
    try { fs.unlinkSync(out); } catch (_) {}
    return false;
  }
}

async function _updateIndexFromNfoAndArtwork({ knex, row, baseDir, searchDir, nfoPath, videoBaseName = '', onlyVideoBase = false, seasonNumber = 0 }) {
  const r = row && typeof row === 'object' ? row : {};
  if (!r.id) return false;

  const parsed = nfoPath ? await readAndParseNfo(nfoPath) : null;
  const nfoFields = videoIndexIndexUtil.buildNfoFieldsFromParsed(parsed) || { nfo_get_state: 1 };

  const current = await knex('video_index')
    .where({ id: r.id })
    .first('poster_path', 'fanart_path', 'logo_path')
    .catch(() => null);

  const part = r.media_type === 'movie' ? parseMoviePart(r.filename) : null;
  const groupBases = part ? moviePartBaseNamesInDirectory(baseDir, r.filename) : [];
  let sharedArtwork = current;
  if (part) {
    const groupArtwork = await knex('video_index')
      .where({ path: r.path, media_type: 'movie', movie_group_key: part.key })
      .orderBy('movie_part_no', 'asc').orderBy('id', 'asc')
      .select('poster_path', 'fanart_path', 'logo_path')
      .catch(() => []);
    sharedArtwork = {};
    for (const field of ['poster_path', 'fanart_path', 'logo_path']) {
      sharedArtwork[field] = groupArtwork.map(item => String(item[field] || '').trim()).find(Boolean) || '';
    }
    if (!Object.values(sharedArtwork).some(Boolean)) sharedArtwork = null;
  }
  const canonicalBase = part
    ? (parseMoviePart(groupBases[0] || '')?.titleStem || movieMetadataBaseName(r.filename, baseDir))
    : videoBaseName;
  const artwork = await videoIndexIndexUtil.resolveArtworkPaths({
    baseDir,
    searchDir,
    current: sharedArtwork,
    videoBaseName: canonicalBase,
    videoBaseAliases: part ? groupBases : [],
    onlyVideoBase,
    seasonNumber,
  });

  const patch = { ...nfoFields, ...artwork, view_time: new Date() };
  const groupRows = part
    ? await knex('video_index').where({ path: r.path, media_type: 'movie', movie_group_key: part.key }).select('id').catch(() => [])
    : [];
  const indexIds = groupRows.length > 0 ? groupRows.map(item => item.id) : [r.id];
  // 写库失败不能让整个刮削批次中断，但要留下痕迹，否则 9 个调用点的
  // 元数据更新失败会完全不可见（这里原本是静默的 .catch）。
  await knex('video_index')
    .whereIn('id', indexIds)
    .update(patch)
    .catch(error => {
      Logger.error(`[nfo] 更新 video_index 元数据失败 ids=${indexIds.join(',')}`, error);
    });

  const hasKeyFields = nfoFields && (Object.prototype.hasOwnProperty.call(nfoFields, 'nfo_regions') || Object.prototype.hasOwnProperty.call(nfoFields, 'nfo_genres'));
  if (hasKeyFields) {
    for (const indexId of indexIds) {
      await videoIndexIndexUtil.syncVideoIndex2KeyFromNfoFields({
        knex,
        indexId,
        mediaType: r.media_type,
        nfoRegions: nfoFields.nfo_regions,
        nfoGenres: nfoFields.nfo_genres,
      });
    }
  }
  return true;
}

class NfoFetchRunner {
  constructor() {
    this.knexVideo = null;
    this.tmdb = null;
    this.metatube = null;
    this.scrapeSource = 'tmdb';
    this.metatubeProvider = '';
    this.metatubeFallback = true;
    this.nfoTranslateEnable = false;
    this.nfoTranslateTitleEnable = false;
    this.nfoTranslateTargetLanguage = 'zh-CN';
    this.nfoTranslateApiUrl = '';
    this.nfoTranslateApiKey = '';
    this.metadataTranslator = null;
  }

  async init() {
    await knexUtil.init(dbUtil.DB_PATHS.MAIN_DB);
    await knexUtil.init(dbUtil.DB_PATHS.VIDEO_DB);
    this.knexVideo = knexUtil.getInstance(dbUtil.DB_PATHS.VIDEO_DB);

    const knex = knexUtil.getInstance(dbUtil.DB_PATHS.MAIN_DB);
    const [
      tmdbApiTokenDec,
      tmdbApiTokenDefaultDec,
      tmdbApiUrlDec,
      tmdbProxyEnable,
      tmdbProxyUrl,
      tmdbLanguage,
      uiLanguage,
      scrapeSourceRaw,
      metatubeBaseUrlRaw,
      metatubeToken,
      metatubeProvider,
      metatubeFallbackRaw,
      nfoTranslateEnableRaw,
      nfoTranslateTitleEnableRaw,
      nfoTranslateTargetLanguageRaw,
      nfoTranslateApiUrlRaw,
      nfoTranslateApiKeyStoredRaw,
      nfoTranslateApiKeyRaw,
    ] = await Promise.all([
      nascabAccountUtil.getDecryptedConfigValue(knex, tableConfig, 'tmdbApiToken'),
      nascabAccountUtil.getDecryptedConfigValue(knex, tableConfig, 'tmdbApiTokenDefault'),
      nascabAccountUtil.getDecryptedConfigValue(knex, tableConfig, 'tmdbApiUrl'),
      tableConfig.getConfigByKey('tmdbProxyEnable'),
      tableConfig.getConfigByKey('tmdbProxyUrl'),
      tableConfig.getConfigByKey('tmdbLanguage'),
      tableConfig.getConfigByKey(tableConfig.KEY_SERVER_UI_LANGUAGE),
      tableConfig.getConfigByKey('videoScrapeSource'),
      tableConfig.getConfigByKey('metatubeBaseUrl'),
      tableConfig.getConfigByKey('metatubeToken'),
      tableConfig.getConfigByKey('metatubeProvider'),
      tableConfig.getConfigByKey('metatubeFallback'),
      tableConfig.getConfigByKey('nfoTranslateEnable'),
      tableConfig.getConfigByKey('nfoTranslateTitleEnable'),
      tableConfig.getConfigByKey('nfoTranslateTargetLanguage'),
      tableConfig.getConfigByKey('nfoTranslateApiUrl'),
      tableConfig.getConfigByKey('nfoTranslateApiKey'),
      nascabAccountUtil.getDecryptedConfigValue(knex, tableConfig, 'nfoTranslateApiKey'),
    ]);
    let apiToken = tmdbApiTokenDec ? String(tmdbApiTokenDec).trim() : '';
    if (!apiToken && tmdbApiTokenDefaultDec) apiToken = String(tmdbApiTokenDefaultDec).trim();
    let apiUrl = tmdbApiUrlDec ? String(tmdbApiUrlDec).trim() : '';
    const proxyEnabled = tmdbProxyEnable === '1' || tmdbProxyEnable === 1;
    const proxyUrl = proxyEnabled && tmdbProxyUrl ? String(tmdbProxyUrl).trim() : '';
    const preferred = tmdbLanguage ? String(tmdbLanguage).trim() : '';
    const effectiveLanguage = _normalizeToTmdbLanguage(preferred) || _normalizeToTmdbLanguage(uiLanguage) || _normalizeToTmdbLanguage(_getSystemLocale()) || 'en-US';

    if (!apiToken || !apiUrl) {
      const defaults = config.getDefaultTmdbConfig();
      if (!apiToken && defaults.tmdbApiToken) apiToken = String(defaults.tmdbApiToken).trim();
      if (!apiUrl && defaults.tmdbApiUrl) apiUrl = String(defaults.tmdbApiUrl).trim();
    }

    this.tmdb = new TmdbClient({ apiUrl, apiToken, proxyUrl, language: effectiveLanguage });
    this.scrapeSource = String(scrapeSourceRaw || '').trim() === 'metatube' ? 'metatube' : 'tmdb';
    this.metatubeProvider = metatubeProvider ? String(metatubeProvider).trim() : '';
    this.metatubeFallback = !(metatubeFallbackRaw === '0' || metatubeFallbackRaw === 0 || metatubeFallbackRaw === false);
    const metatubeBaseUrl = normalizeMetaTubeBaseUrl(metatubeBaseUrlRaw) || normalizeMetaTubeBaseUrl(DEFAULT_METATUBE_BASE_URL);
    this.metatube = metatubeBaseUrl ? new MetaTubeClient({ baseUrl: metatubeBaseUrl, token: metatubeToken }) : null;
    this.nfoTranslateEnable = nfoTranslateEnableRaw === '1' || nfoTranslateEnableRaw === 1 || nfoTranslateEnableRaw === true;
    this.nfoTranslateTitleEnable = nfoTranslateTitleEnableRaw === '1' || nfoTranslateTitleEnableRaw === 1 || nfoTranslateTitleEnableRaw === true;
    this.nfoTranslateTargetLanguage = normalizeTranslateTargetLanguage(nfoTranslateTargetLanguageRaw);
    this.nfoTranslateApiUrl = normalizeTranslateApiUrl(nfoTranslateApiUrlRaw);
    this.nfoTranslateApiKey = nfoTranslateApiKeyRaw
      ? String(nfoTranslateApiKeyRaw).trim()
      : nfoTranslateApiKeyStoredRaw && !String(nfoTranslateApiKeyStoredRaw).trim().startsWith('enc.')
          ? String(nfoTranslateApiKeyStoredRaw).trim()
          : '';
    this.metadataTranslator = this.nfoTranslateEnable
      ? new MetadataTranslateClient({
          targetLanguage: this.nfoTranslateTargetLanguage,
          apiUrl: this.nfoTranslateApiUrl,
          apiKey: this.nfoTranslateApiKey,
        })
      : null;
  }

  async translateNfoData(nfoData) {
    return await _translateNfoData(this.metadataTranslator, nfoData, {
      translateTitle: this.nfoTranslateTitleEnable,
      translateGenres: true,
      translatePlot: true,
    });
  }

  async getPendingRoots(limit = 5) {
    const matchRoots = await tableVideoSource.getMatchNfoPaths({ knex: this.knexVideo });
    const enabledRoots = (matchRoots || []).map(p => (p ? path.resolve(String(p)) : '')).filter(Boolean);
    if (enabledRoots.length === 0) return [];
    console.log('enabledRoots', enabledRoots);
    const rows = await this.knexVideo('video_index')
      .select('id', 'path', 'filename', 'media_type', 'is_file', 'nfo_name', 'nfo_get_state', 'duration')
      .where({ nfo_get_state: 0 })
      .whereIn('media_type', ['tv', 'movie', 'bdmv', 'video_ts'])
      .modify(qb => whereMovieRepresentative(qb, 'video_index'))
      .andWhere(qb => {
        qb.where(inner => {
          for (const root of enabledRoots) {
            const prefix = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
            inner.orWhere('path', root).orWhere('path', 'like', `${prefix}%`);
            inner.orWhere({ path: path.dirname(root), filename: path.basename(root) });
          }
        });
      })
      .orderBy('id', 'asc')
      .limit(Math.max(1, Math.min(50, Number(limit || 0) || 5)))
      .catch(() => []);
    return rows || [];
  }

  async markSkipped(row) {
    if (!row || !row.id) return;
    await this.knexVideo('video_index')
      .where({ id: row.id })
      .update({ nfo_get_state: 1 })
      .catch(() => {});
  }

  async markFailed(row) {
    if (!row || !row.id) return;
    console.log('nfo获取失败', row.id, row.path, row.filename);
    await this.knexVideo('video_index')
      .where({ id: row.id })
      .update({ nfo_get_state: 1 })
      .catch(() => {});
  }

  async _writeMetaTubeMovieRow(row, details) {
    const dirPath = row && row.path ? String(row.path) : '';
    const filename = row && row.filename ? String(row.filename) : '';
    if (!dirPath || !filename || !details) return false;
    const mediaType = row && row.media_type ? String(row.media_type).trim() : '';
    const isDiscFolderMovie = mediaType === 'bdmv' || mediaType === 'video_ts';
    const movieFolder = isDiscFolderMovie ? path.join(dirPath, filename) : '';

    let nfoData = _mapMetaTubeMovieToNfo(details);
    nfoData.tags = addMetaTubeFilenameTags(nfoData.tags, filename, { isDirectory: isDiscFolderMovie, directoryName: path.basename(dirPath) });
    nfoData = await this.translateNfoData(nfoData);
    nfoData.genres = mergeMovieMetadataGenres(nfoData.genres, nfoData.tags);
    // Add the number after translation so title translation cannot alter it.
    const number = details.number ? String(details.number).trim() : '';
    if (number && details.title && String(details.title).trim()) {
      nfoData.title = `${number} ${nfoData.title}`;
    }
    const metadataBaseName = isDiscFolderMovie ? '' : movieMetadataBaseName(filename, dirPath);
    const targetDir = isDiscFolderMovie ? movieFolder : dirPath;
    const nfoPath = isDiscFolderMovie ? path.join(movieFolder, 'movie.nfo') : path.join(dirPath, `${metadataBaseName}.nfo`);
    await writeTextIfChanged(nfoPath, buildMovieNfo(nfoData));

    const posterUrl = details.cover_url || details.big_cover_url || details.thumb_url || details.big_thumb_url || '';
    const fanartUrl = details.big_thumb_url || details.thumb_url || (Array.isArray(details.preview_images) ? details.preview_images[0] : '') || '';
    if (posterUrl) await _ensureDownloadedJpeg(this.metatube, targetDir, isDiscFolderMovie ? 'poster.jpg' : `${metadataBaseName}-poster.jpg`, posterUrl);
    if (fanartUrl) await _ensureDownloadedJpeg(this.metatube, targetDir, isDiscFolderMovie ? 'fanart.jpg' : `${metadataBaseName}-fanart.jpg`, fanartUrl);

    await _updateIndexFromNfoAndArtwork({
      knex: this.knexVideo,
      row,
      baseDir: dirPath,
      searchDir: targetDir,
      nfoPath,
      videoBaseName: isDiscFolderMovie ? '' : metadataBaseName,
      onlyVideoBase: false,
      seasonNumber: 0,
    });

    return true;
  }

  async _processMovieRowByMetaTube(row) {
    if (!this.metatube) return false;
    const dirPath = row && row.path ? String(row.path) : '';
    const filename = row && row.filename ? String(row.filename) : '';
    const preferTitle = (row && row.nfo_name ? String(row.nfo_name) : '').trim();
    const numberQuery =
      _extractMetaTubeNumberQueryFromFilename(filename) ||
      _extractMetaTubeNumberQueryFromText(path.basename(dirPath));
    const fallbackTitle = _normalizeSearchTitleFromFileName(filename);
    const rawTitle = fallbackTitle || preferTitle;
    const query = numberQuery || _cleanSearchText(rawTitle) || String(rawTitle || '').trim();
    if (!query) return false;

    const results = await this.metatube.searchMovie({
      query,
      provider: this.metatubeProvider,
      fallback: this.metatubeFallback,
    });
    const picked = await this._pickMetaTubeMovieWithDetails(results, numberQuery);
    return await this._writeMetaTubeMovieRow(row, picked);
  }

  async _processMovieRowByMetaTubeId(row, scrapeId) {
    if (!this.metatube) return false;
    const parsed = parseMetaTubeScrapeId(scrapeId);
    const provider = parsed.provider || this.metatubeProvider;
    const movieId = parsed.id;
    if (!provider || !movieId) return false;
    const expectedNumber =
      _extractMetaTubeNumberQueryFromFilename(row && row.filename) ||
      _extractMetaTubeNumberQueryFromText(path.basename(String(row && row.path || '')));
    const expectedKey = _normalizeComparableMetaTubeNumber(expectedNumber);
    const details = await this.metatube.getMovieDetails(provider, movieId).catch(e => {
      Logger.warn(`[nfoFetch] MetaTube detail failed: provider=${provider} id=${movieId}`, e && e.message ? e.message : e);
      return null;
    });
    if (details && (!expectedKey || _normalizeComparableMetaTubeNumber(details.number) === expectedKey)) {
      return await this._writeMetaTubeMovieRow(row, details);
    }
    if (details && expectedKey) Logger.warn(`[nfoFetch] MetaTube selected detail number mismatches file: expected=${expectedNumber} provider=${provider} id=${movieId}`);

    const results = await this.metatube
      .searchMovie({
        query: expectedNumber || movieId,
        provider,
        fallback: this.metatubeFallback,
      })
      .catch(() => []);
    const candidates = (Array.isArray(results) ? results : []).filter(item =>
      String(item && item.id || '').trim() === movieId &&
      String(item && item.provider || '').trim().toLowerCase() === provider.toLowerCase());
    const picked = await this._pickMetaTubeMovieWithDetails(candidates, expectedNumber);
    return await this._writeMetaTubeMovieRow(row, picked);
  }

  async _pickMetaTubeMovieWithDetails(results, expectedNumber = '') {
    if (!this.metatube) return null;
    const all = Array.isArray(results) ? results.filter(Boolean) : [];
    const expectedKey = _normalizeComparableMetaTubeNumber(expectedNumber);
    let candidates = all;
    if (expectedKey) {
      const exact = all.filter(item => _normalizeComparableMetaTubeNumber(item && item.number) === expectedKey);
      // Search results may omit the number; validate it after fetching details.
      const missingNumber = all.filter(item => !String(item && item.number || '').trim());
      candidates = [...exact, ...missingNumber];
      if (candidates.length === 0) {
        Logger.warn(`[nfoFetch] MetaTube exact number not found; refusing unrelated results: query=${expectedNumber}`);
        return null;
      }
    }
    const list = candidates.slice(0, 5);
    if (list.length === 0) return null;

    let best = null;
    let bestScore = -1;
    for (const item of list) {
      const provider = item && item.provider ? String(item.provider).trim() : this.metatubeProvider;
      const movieId = item && item.id ? String(item.id).trim() : '';
      if (!provider || !movieId) continue;

      const details = await this.metatube.getMovieDetails(provider, movieId).catch(e => {
        Logger.warn(`[nfoFetch] MetaTube detail failed: provider=${provider} id=${movieId}`, e && e.message ? e.message : e);
        return null;
      });
      const merged = _mergeMetaTubeMovie(item, details);
      if (!details && !String(item && item.number || '').trim()) continue;
      if (expectedKey && _normalizeComparableMetaTubeNumber(merged.number) !== expectedKey) {
        Logger.warn(`[nfoFetch] MetaTube detail number mismatch; refusing result: query=${expectedNumber} provider=${provider} id=${movieId}`);
        continue;
      }
      const score = _scoreMetaTubeMovie(merged);
      if (score > bestScore) {
        best = merged;
        bestScore = score;
      }
      if (String(merged.summary || '').trim() && Array.isArray(merged.genres) && merged.genres.length > 0) {
        break;
      }
    }
    return best;
  }

  async processMovieRow(row) {
    const dirPath = row && row.path ? String(row.path) : '';
    const filename = row && row.filename ? String(row.filename) : '';
    if (!dirPath || !filename) return false;
    const mediaType = row && row.media_type ? String(row.media_type).trim() : '';
    const isDiscFolderMovie = mediaType === 'bdmv' || mediaType === 'video_ts';
    const movieFolder = isDiscFolderMovie ? path.join(dirPath, filename) : '';

    if (FileUtil.shouldSkipIndexingFilename(filename) || _hasSkipNameHint(path.parse(filename).name) || _shouldSkipByDurationSeconds(row && row.duration)) {
      await this.markSkipped(row);
      return true;
    }

    const preferTitle = (row.nfo_name ? String(row.nfo_name) : '').trim();
    const fallbackTitle = _normalizeSearchTitleFromFileName(filename);
    const rawTitle = preferTitle || fallbackTitle;

    const numericCheck = _cleanSearchText(rawTitle) || String(rawTitle || '').trim();
    if (_isPureNumberText(numericCheck) && numericCheck !== '1946') {
      await this.markSkipped(row);
      return true;
    }

    try {
      const st = await fs.promises.stat(isDiscFolderMovie ? movieFolder : path.join(dirPath, filename));
      if (isDiscFolderMovie ? !st.isDirectory() : !st.isFile()) return false;
    } catch (_) {
      return false;
    }

    if (this.scrapeSource === 'metatube') {
      return await this._processMovieRowByMetaTube(row);
    }

    const yearFromFilename = _pickYearFromText(filename);
    const attempts = _buildQueryAttemptsFromText(rawTitle);
    if (attempts.length === 0) {
      const q = _cleanSearchText(rawTitle);
      if (q) attempts.push({ query: q, year: yearFromFilename || 0 });
    }

    let tmdbId = 0;
    for (const a of attempts) {
      const q = a && a.query ? String(a.query) : '';
      const y = a && a.year ? Number(a.year) : 0;
      if (!q) continue;
      const results = await this.tmdb.searchMovie({ query: q, year: y || yearFromFilename || 0 });
      const picked = results && results[0] ? results[0] : null;
      const id = picked && picked.id ? Number(picked.id) : 0;
      if (id) {
        tmdbId = id;
        break;
      }
    }
    if (!tmdbId) return false;

    const details = await this.tmdb.getMovieDetails(tmdbId);
    if (!details) return false;

    let nfoData = _mapMovieToNfo({ client: this.tmdb, movie: details });
    nfoData = await this.translateNfoData(nfoData);
    const metadataBaseName = isDiscFolderMovie ? '' : movieMetadataBaseName(filename, dirPath);
    const nfoPath = isDiscFolderMovie ? path.join(movieFolder, 'movie.nfo') : path.join(dirPath, `${metadataBaseName}.nfo`);
    await writeTextIfChanged(nfoPath, buildMovieNfo(nfoData));

    if (details.poster_path) await _ensureDownloadedJpeg(this.tmdb, isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'poster.jpg' : `${metadataBaseName}-poster.jpg`, details.poster_path);
    if (details.backdrop_path) await _ensureDownloadedJpeg(this.tmdb, isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'fanart.jpg' : `${metadataBaseName}-fanart.jpg`, details.backdrop_path);
    const logo = _pickLogoPathFromImages(details.images);
    if (logo) {
      await _ensureDownloadedPng(this.tmdb, isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'logo.png' : `${metadataBaseName}-logo.png`, logo);
      const legacy = path.join(isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'logo.jpg' : `${metadataBaseName}-logo.jpg`);
      try {
        if (fs.existsSync(legacy) && fs.statSync(legacy).isFile()) fs.unlinkSync(legacy);
      } catch (_) {}
    }

    await _updateIndexFromNfoAndArtwork({
      knex: this.knexVideo,
      row,
      baseDir: dirPath,
      searchDir: isDiscFolderMovie ? movieFolder : dirPath,
      nfoPath,
      videoBaseName: isDiscFolderMovie ? '' : metadataBaseName,
      onlyVideoBase: false,
      seasonNumber: 0,
    });

    return true;
  }

  async getSeasonsUnderShow(showFolder) {
    const resolved = path.resolve(String(showFolder || ''));
    if (!resolved) return [];
    const rows = await this.knexVideo('video_index')
      .select('id', 'path', 'filename', 'media_type', 'is_file', 'nfo_get_state')
      .where({ path: resolved, is_file: 0, media_type: 'season', nfo_get_state: 0 })
      .orderBy('id', 'asc')
      .catch(() => []);
    return rows || [];
  }

  async getSeasonsWithPendingEpisodesUnderShow(showFolder) {
    const resolved = path.resolve(String(showFolder || ''));
    if (!resolved) return [];
    const prefix = resolved.endsWith(path.sep) ? resolved : `${resolved}${path.sep}`;

    const episodeFolders = await this.knexVideo('video_index')
      .distinct('path')
      .where({ is_file: 1, media_type: 'episod', nfo_get_state: 0 })
      .andWhere('path', 'like', `${prefix}%`)
      .catch(() => []);

    const seasonNames = new Set();
    for (const r of episodeFolders || []) {
      const episodeDir = r && r.path ? String(r.path) : '';
      if (!episodeDir) continue;
      const rel = path.relative(resolved, episodeDir);
      if (!rel || rel.startsWith('..')) continue;
      const first = rel.split(path.sep).filter(Boolean)[0] || '';
      if (first) seasonNames.add(first);
    }
    const names = Array.from(seasonNames);
    if (names.length === 0) return [];

    const rows = await this.knexVideo('video_index')
      .select('id', 'path', 'filename', 'media_type', 'is_file', 'nfo_get_state')
      .where({ path: resolved, is_file: 0, media_type: 'season' })
      .whereIn('filename', names)
      .orderBy('id', 'asc')
      .catch(() => []);
    return rows || [];
  }

  async getSeasonsNeedingWork(showFolder) {
    const list = [];
    const a = await this.getSeasonsUnderShow(showFolder);
    const b = await this.getSeasonsWithPendingEpisodesUnderShow(showFolder);
    for (const r of a || []) list.push(r);
    for (const r of b || []) list.push(r);
    const seen = new Set();
    const out = [];
    for (const r of list) {
      const id = r && r.id ? Number(r.id) : 0;
      if (!id || seen.has(id)) continue;
      seen.add(id);
      out.push(r);
    }
    out.sort((x, y) => Number(x.id || 0) - Number(y.id || 0));
    return out;
  }

  async getEpisodesUnderFolder(seasonFolder) {
    const resolved = path.resolve(String(seasonFolder || ''));
    if (!resolved) return [];
    const prefix = resolved.endsWith(path.sep) ? resolved : `${resolved}${path.sep}`;
    const rows = await this.knexVideo('video_index')
      .select('id', 'path', 'filename', 'media_type', 'is_file', 'nfo_get_state', 'duration')
      .where({ is_file: 1, nfo_get_state: 0 })
      .andWhere('media_type', 'in', ['episod'])
      .andWhere(qb => {
        qb.where('path', resolved).orWhere('path', 'like', `${prefix}%`);
      })
      .orderBy('id', 'asc')
      .catch(() => []);
    return rows || [];
  }

  async getEpisodesInFolder(folder) {
    const resolved = path.resolve(String(folder || ''));
    if (!resolved) return [];
    const rows = await this.knexVideo('video_index')
      .select('id', 'path', 'filename', 'media_type', 'is_file', 'nfo_get_state', 'duration')
      .where({ is_file: 1, nfo_get_state: 0, path: resolved })
      .andWhere('media_type', 'in', ['episod'])
      .orderBy('id', 'asc')
      .catch(() => []);
    return rows || [];
  }

  async processTvRow(row) {
    const parentDir = row && row.path ? String(row.path) : '';
    const folderName = row && row.filename ? String(row.filename) : '';
    if (!parentDir || !folderName) return false;

    if (FileUtil.shouldSkipIndexingFilename(folderName)) {
      await this.markSkipped(row);
      return true;
    }

    const showFolder = path.join(parentDir, folderName);
    try {
      const st = await fs.promises.stat(showFolder);
      if (!st.isDirectory()) return false;
    } catch (_) {
      return false;
    }

    const nfoPath = path.join(showFolder, 'tvshow.nfo');
    if (await hasValidNfo(nfoPath, 'tvshow')) {
      const parsed = await readAndParseNfo(nfoPath);
      const tmdbId = parsed && parsed.tmdbId ? Number(parsed.tmdbId) : 0;
      if (tmdbId) {
        await _updateIndexFromNfoAndArtwork({
          knex: this.knexVideo,
          row,
          baseDir: parentDir,
          searchDir: showFolder,
          nfoPath,
          onlyVideoBase: false,
          seasonNumber: 0,
        });

        const seasons = await this.getSeasonsNeedingWork(showFolder);
        for (const sRow of seasons) {
          await this.processSeasonRow({ tvId: tmdbId, showFolder, showParentDir: parentDir, seasonRow: sRow });
        }

        const episodesInShowFolder = await this.getEpisodesInFolder(showFolder);
        if (episodesInShowFolder && episodesInShowFolder.length > 0) {
          const seasonDetails = await this.tmdb.getSeasonDetails(tmdbId, 1).catch(() => null);
          const episodeDetailsByNumber = new Map();
          const episodes = seasonDetails && Array.isArray(seasonDetails.episodes) ? seasonDetails.episodes : [];
          for (const e of episodes) {
            const en = e && e.episode_number ? Number(e.episode_number) : 0;
            if (en > 0) episodeDetailsByNumber.set(en, e);
          }
          for (const eRow of episodesInShowFolder) {
            const filename = eRow && eRow.filename ? String(eRow.filename) : '';
            const parsedEp = parseEpisodeFromName(filename);
            const episodeNumber = parsedEp && parsedEp.episode ? Number(parsedEp.episode) : 0;
            const preFetched = episodeNumber > 0 ? episodeDetailsByNumber.get(episodeNumber) : null;
            await this.processEpisodeRow({ tvId: tmdbId, seasonNumber: 1, episodeRow: eRow, episodeDetails: preFetched });
          }
        }

        return true;
      }
    }

    const preferTitle = (row.nfo_name ? String(row.nfo_name) : '').trim();
    const fallbackTitle = normalizeNameForNfoGuess(folderName) || folderName;
    const rawTitle = preferTitle || fallbackTitle;

    const attempts = _buildQueryAttemptsFromText(rawTitle);
    if (attempts.length === 0) {
      const q = _cleanSearchText(rawTitle);
      if (q) attempts.push({ query: q, year: 0 });
    }

    let tmdbId = 0;
    for (const a of attempts) {
      const q = a && a.query ? String(a.query) : '';
      if (!q) continue;
      const results = await this.tmdb.searchTv({ query: q });
      const picked = results && results[0] ? results[0] : null;
      const id = picked && picked.id ? Number(picked.id) : 0;
      if (id) {
        tmdbId = id;
        break;
      }
    }
    if (!tmdbId) return false;

    const details = await this.tmdb.getTvDetails(tmdbId);
    if (!details) return false;

    let nfoData = _mapTvToNfo({ client: this.tmdb, tv: details });
    nfoData = await this.translateNfoData(nfoData);
    await writeTextIfChanged(nfoPath, buildTvShowNfo(nfoData));

    if (details.poster_path) await _ensureDownloaded(this.tmdb, showFolder, 'poster.jpg', details.poster_path);
    if (details.backdrop_path) await _ensureDownloaded(this.tmdb, showFolder, 'fanart.jpg', details.backdrop_path);
    const logo = _pickLogoPathFromImages(details.images);
    if (logo) await _ensureDownloadedPng(this.tmdb, showFolder, 'logo.png', logo);

    await _updateIndexFromNfoAndArtwork({
      knex: this.knexVideo,
      row,
      baseDir: parentDir,
      searchDir: showFolder,
      nfoPath,
      onlyVideoBase: false,
      seasonNumber: 0,
    });

    const seasons = await this.getSeasonsNeedingWork(showFolder);
    for (const sRow of seasons) {
      await this.processSeasonRow({ tvId: tmdbId, showFolder, showParentDir: parentDir, seasonRow: sRow });
    }

    const episodesInShowFolder = await this.getEpisodesInFolder(showFolder);
    if (episodesInShowFolder && episodesInShowFolder.length > 0) {
      const seasonDetails = await this.tmdb.getSeasonDetails(tmdbId, 1).catch(() => null);
      const episodeDetailsByNumber = new Map();
      const episodes = seasonDetails && Array.isArray(seasonDetails.episodes) ? seasonDetails.episodes : [];
      for (const e of episodes) {
        const en = e && e.episode_number ? Number(e.episode_number) : 0;
        if (en > 0) episodeDetailsByNumber.set(en, e);
      }
      for (const eRow of episodesInShowFolder) {
        const filename = eRow && eRow.filename ? String(eRow.filename) : '';
        const parsedEp = parseEpisodeFromName(filename);
        const episodeNumber = parsedEp && parsedEp.episode ? Number(parsedEp.episode) : 0;
        const preFetched = episodeNumber > 0 ? episodeDetailsByNumber.get(episodeNumber) : null;
        await this.processEpisodeRow({ tvId: tmdbId, seasonNumber: 1, episodeRow: eRow, episodeDetails: preFetched });
      }
    }

    return true;
  }

  async processSeasonRow({ tvId, showFolder, showParentDir, seasonRow }) {
    const seasonName = seasonRow && seasonRow.filename ? String(seasonRow.filename) : '';
    const seasonFolder = path.join(showFolder, seasonName);
    const seasonNumber = parseSeasonNumberFromName(seasonName);
    if (!seasonNumber) return false;
    try {
      const st = await fs.promises.stat(seasonFolder);
      if (!st.isDirectory()) return false;
    } catch (_) {
      return false;
    }

    const nfoPath = path.join(seasonFolder, 'season.nfo');
    const hasSeasonNfo = await hasValidNfo(nfoPath, 'season');

    let seasonDetails = null;
    if (hasSeasonNfo) {
      await _updateIndexFromNfoAndArtwork({
        knex: this.knexVideo,
        row: seasonRow,
        baseDir: showFolder,
        searchDir: seasonFolder,
        nfoPath,
        onlyVideoBase: false,
        seasonNumber,
      });
      seasonDetails = await this.tmdb.getSeasonDetails(tvId, seasonNumber).catch(() => null);
    } else {
      seasonDetails = await this.tmdb.getSeasonDetails(tvId, seasonNumber);
      if (!seasonDetails) return false;

      let nfoData = _mapSeasonToNfo({ client: this.tmdb, tvId: String(tvId), season: seasonDetails });
      nfoData = await this.translateNfoData(nfoData);
      await writeTextIfChanged(nfoPath, buildSeasonNfo(nfoData));

      if (seasonDetails.poster_path) await _ensureDownloaded(this.tmdb, seasonFolder, 'poster.jpg', seasonDetails.poster_path);

      await _updateIndexFromNfoAndArtwork({
        knex: this.knexVideo,
        row: seasonRow,
        baseDir: showFolder,
        searchDir: seasonFolder,
        nfoPath,
        onlyVideoBase: false,
        seasonNumber,
      });
    }

    const episodeDetailsByNumber = new Map();
    const episodeList = seasonDetails && Array.isArray(seasonDetails.episodes) ? seasonDetails.episodes : [];
    for (const e of episodeList) {
      const en = e && e.episode_number ? Number(e.episode_number) : 0;
      if (en > 0) episodeDetailsByNumber.set(en, e);
    }

    const episodes = await this.getEpisodesUnderFolder(seasonFolder);
    for (const eRow of episodes) {
      const filename = eRow && eRow.filename ? String(eRow.filename) : '';
      const parsedEp = parseEpisodeFromName(filename);
      const episodeNumber = parsedEp && parsedEp.episode ? Number(parsedEp.episode) : 0;
      const seasonFromName = parsedEp && parsedEp.season ? Number(parsedEp.season) : 0;
      const sn = seasonFromName || Number(seasonNumber || 0) || 1;
      const preFetched = sn === seasonNumber && episodeNumber > 0 ? episodeDetailsByNumber.get(episodeNumber) : null;
      await this.processEpisodeRow({ tvId, seasonNumber, episodeRow: eRow, episodeDetails: preFetched });
    }

    return true;
  }

  async processEpisodeRow({ tvId, seasonNumber, episodeRow, episodeDetails }) {
    const dirPath = episodeRow && episodeRow.path ? String(episodeRow.path) : '';
    const filename = episodeRow && episodeRow.filename ? String(episodeRow.filename) : '';
    if (!dirPath || !filename) return false;

    if (FileUtil.shouldSkipIndexingFilename(filename) || _hasSkipNameHint(path.parse(filename).name) || _shouldSkipByDurationSeconds(episodeRow && episodeRow.duration)) {
      await this.markSkipped(episodeRow);
      return true;
    }

    const full = path.join(dirPath, filename);
    try {
      const st = await fs.promises.stat(full);
      if (!st.isFile()) return false;
    } catch (_) {
      return false;
    }

    let ep = parseEpisodeFromName(filename);
    const episodeNumber = ep && ep.episode ? Number(ep.episode) : 0;
    const seasonFromName = ep && ep.season ? Number(ep.season) : 0;
    const sn = seasonFromName || Number(seasonNumber || 0) || 1;
    if (!sn || !episodeNumber) return false;

    const preFetched = episodeDetails && typeof episodeDetails === 'object' ? episodeDetails : null;
    const preSeason = preFetched && preFetched.season_number ? Number(preFetched.season_number) : 0;
    const preEpisode = preFetched && preFetched.episode_number ? Number(preFetched.episode_number) : 0;
    const details = preFetched && preSeason === sn && preEpisode === episodeNumber ? preFetched : await this.tmdb.getEpisodeDetails(tvId, sn, episodeNumber);
    if (!details) return false;

    let nfoData = _mapEpisodeToNfo({ client: this.tmdb, episode: details });
    nfoData = await this.translateNfoData(nfoData);
    const baseName = path.parse(filename).name;
    const nfoPath = path.join(dirPath, `${baseName}.nfo`);
    await writeTextIfChanged(nfoPath, buildEpisodeNfo(nfoData));

    if (details.still_path) {
      await _ensureDownloadedJpeg(this.tmdb, dirPath, `${baseName}.jpg`, details.still_path);
    }

    await _updateIndexFromNfoAndArtwork({
      knex: this.knexVideo,
      row: episodeRow,
      baseDir: dirPath,
      searchDir: dirPath,
      nfoPath,
      videoBaseName: baseName,
      onlyVideoBase: true,
      seasonNumber: 0,
    });

    return true;
  }

  async _processMovieRowByTmdbId(row, tmdbId) {
    const dirPath = row && row.path ? String(row.path) : '';
    const filename = row && row.filename ? String(row.filename) : '';
    if (!dirPath || !filename) return false;
    const mediaType = row && row.media_type ? String(row.media_type).trim() : '';
    const isDiscFolderMovie = mediaType === 'bdmv' || mediaType === 'video_ts';
    const movieFolder = isDiscFolderMovie ? path.join(dirPath, filename) : '';

    if (FileUtil.shouldSkipIndexingFilename(filename) || _hasSkipNameHint(path.parse(filename).name) || _shouldSkipByDurationSeconds(row && row.duration)) {
      await this.markSkipped(row);
      return true;
    }

    try {
      const st = await fs.promises.stat(isDiscFolderMovie ? movieFolder : path.join(dirPath, filename));
      if (isDiscFolderMovie ? !st.isDirectory() : !st.isFile()) return false;
    } catch (_) {
      return false;
    }

    const details = await this.tmdb.getMovieDetails(tmdbId);
    if (!details) return false;

    let nfoData = _mapMovieToNfo({ client: this.tmdb, movie: details });
    nfoData = await this.translateNfoData(nfoData);
    const metadataBaseName = isDiscFolderMovie ? '' : movieMetadataBaseName(filename, dirPath);
    const nfoPath = isDiscFolderMovie ? path.join(movieFolder, 'movie.nfo') : path.join(dirPath, `${metadataBaseName}.nfo`);
    await writeTextIfChanged(nfoPath, buildMovieNfo(nfoData));

    if (details.poster_path) await _ensureDownloadedJpeg(this.tmdb, isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'poster.jpg' : `${metadataBaseName}-poster.jpg`, details.poster_path);
    if (details.backdrop_path) await _ensureDownloadedJpeg(this.tmdb, isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'fanart.jpg' : `${metadataBaseName}-fanart.jpg`, details.backdrop_path);
    const logo = _pickLogoPathFromImages(details.images);
    if (logo) {
      await _ensureDownloadedPng(this.tmdb, isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'logo.png' : `${metadataBaseName}-logo.png`, logo);
      const legacy = path.join(isDiscFolderMovie ? movieFolder : dirPath, isDiscFolderMovie ? 'logo.jpg' : `${metadataBaseName}-logo.jpg`);
      try {
        if (fs.existsSync(legacy) && fs.statSync(legacy).isFile()) fs.unlinkSync(legacy);
      } catch (_) {}
    }

    await _updateIndexFromNfoAndArtwork({
      knex: this.knexVideo,
      row,
      baseDir: dirPath,
      searchDir: isDiscFolderMovie ? movieFolder : dirPath,
      nfoPath,
      videoBaseName: isDiscFolderMovie ? '' : metadataBaseName,
      onlyVideoBase: false,
      seasonNumber: 0,
    });

    return true;
  }

  async _processTvRowByTmdbId(row, tvId) {
    const parentDir = row && row.path ? String(row.path) : '';
    const folderName = row && row.filename ? String(row.filename) : '';
    if (!parentDir || !folderName) return false;

    if (FileUtil.shouldSkipIndexingFilename(folderName)) {
      await this.markSkipped(row);
      return true;
    }

    const showFolder = path.join(parentDir, folderName);
    try {
      const st = await fs.promises.stat(showFolder);
      if (!st.isDirectory()) return false;
    } catch (_) {
      return false;
    }

    const details = await this.tmdb.getTvDetails(tvId);
    if (!details) return false;

    const nfoPath = path.join(showFolder, 'tvshow.nfo');
    let nfoData = _mapTvToNfo({ client: this.tmdb, tv: details });
    nfoData = await this.translateNfoData(nfoData);
    await writeTextIfChanged(nfoPath, buildTvShowNfo(nfoData));

    if (details.poster_path) await _ensureDownloaded(this.tmdb, showFolder, 'poster.jpg', details.poster_path);
    if (details.backdrop_path) await _ensureDownloaded(this.tmdb, showFolder, 'fanart.jpg', details.backdrop_path);
    const logo = _pickLogoPathFromImages(details.images);
    if (logo) await _ensureDownloadedPng(this.tmdb, showFolder, 'logo.png', logo);

    await _updateIndexFromNfoAndArtwork({
      knex: this.knexVideo,
      row,
      baseDir: parentDir,
      searchDir: showFolder,
      nfoPath,
      onlyVideoBase: false,
      seasonNumber: 0,
    });

    const seasons = await this.getSeasonsNeedingWork(showFolder);
    for (const sRow of seasons) {
      await this.processSeasonRow({ tvId, showFolder, showParentDir: parentDir, seasonRow: sRow });
    }

    return true;
  }

  async _resolveTvIdFromShowFolder(showFolder) {
    const resolved = path.resolve(String(showFolder || ''));
    if (!resolved) return 0;
    const nfoPath = path.join(resolved, 'tvshow.nfo');
    if (!(await hasValidNfo(nfoPath, 'tvshow'))) return 0;
    const parsed = await readAndParseNfo(nfoPath);
    const tvId = parsed && parsed.tmdbId ? Number(parsed.tmdbId) : 0;
    return tvId > 0 ? tvId : 0;
  }

  async scrapeByIndexId({ indexId, tmdbId = 0, scrapeId = '' } = {}) {
    const id = Number(indexId || 0) || 0;
    if (!id) return { ok: false };
    let row = await this.knexVideo('video_index')
      .where({ id })
      .first('id', 'path', 'filename', 'media_type', 'is_file', 'nfo_name', 'nfo_get_state', 'duration', 'movie_group_key', 'movie_part_no')
      .catch(() => null);
    if (!row) return { ok: false };

    if (row.media_type === 'movie' && row.movie_group_key) {
      row = await this.knexVideo('video_index')
        .where({ path: row.path, media_type: 'movie', movie_group_key: row.movie_group_key })
        .orderBy('movie_part_no', 'asc').orderBy('id', 'asc').first()
        .catch(() => row);
    }

    const mediaType = row.media_type ? String(row.media_type).trim() : '';
    const overrideRaw = String(scrapeId || tmdbId || '').trim();
    const override = Number(tmdbId || (/^\d+$/.test(overrideRaw) ? overrideRaw : 0)) || 0;

    try {
      if (mediaType === 'movie' || mediaType === 'bdmv' || mediaType === 'video_ts') {
        const done = this.scrapeSource === 'metatube' && overrideRaw
          ? await this._processMovieRowByMetaTubeId(row, overrideRaw)
          : override
              ? await this._processMovieRowByTmdbId(row, override)
              : await this.processMovieRow(row);
        if (!done) await this.markFailed(row);
        return { ok: !!done };
      }
      if (mediaType === 'tv') {
        const done = override ? await this._processTvRowByTmdbId(row, override) : await this.processTvRow(row);
        if (!done) await this.markFailed(row);
        return { ok: !!done };
      }
      if (mediaType === 'season') {
        const showFolder = row.path ? String(row.path) : '';
        const seasonNumber = parseSeasonNumberFromName(row.filename);
        if (!showFolder || !seasonNumber) return { ok: false };
        const tvId = override || (await this._resolveTvIdFromShowFolder(showFolder));
        if (!tvId) return { ok: false };
        const done = await this.processSeasonRow({
          tvId,
          showFolder,
          showParentDir: path.dirname(showFolder),
          seasonRow: row,
        });
        if (!done) await this.markFailed(row);
        return { ok: !!done };
      }
      if (mediaType === 'episod') {
        const dirPath = row.path ? String(row.path) : '';
        if (!dirPath) return { ok: false };
        const seasonNumber = parseSeasonNumberFromName(path.basename(dirPath));
        let tvId = override;
        if (!tvId) {
          let cursor = path.resolve(dirPath);
          let found = '';
          for (let i = 0; i < 6; i += 1) {
            const candidate = path.join(cursor, 'tvshow.nfo');
            if (fs.existsSync(candidate)) {
              found = cursor;
              break;
            }
            const next = path.dirname(cursor);
            if (!next || next === cursor) break;
            cursor = next;
          }
          tvId = found ? await this._resolveTvIdFromShowFolder(found) : 0;
        }
        if (!tvId) return { ok: false };
        const done = await this.processEpisodeRow({ tvId, seasonNumber, episodeRow: row });
        if (!done) await this.markFailed(row);
        return { ok: !!done };
      }
      return { ok: false };
    } catch (err) {
      Logger.error('❌ scrapeByIndexId failed', err && err.message ? err.message : err);
      await this.markFailed(row);
      return { ok: false };
    }
  }

  async runOnce({ limit = 5 } = {}) {
    const roots = await this.getPendingRoots(limit);
    if (!roots || roots.length === 0) return { processed: 0, ok: 0 };
    let ok = 0;
    let processed = 0;
    for (const r of roots) {
      console.log('开始获取nfo信息', r.path, r.filename);
      processed += 1;
      try {
        if (r.media_type === 'movie' || r.media_type === 'bdmv' || r.media_type === 'video_ts') {
          const done = await this.processMovieRow(r);
          if (done) ok += 1;
          if (!done) await this.markFailed(r);
        } else if (r.media_type === 'tv') {
          const done = await this.processTvRow(r);
          if (done) ok += 1;
          if (!done) await this.markFailed(r);
        }
      } catch (err) {
        Logger.error('❌ nfoFetch handle failed', err && err.message ? err.message : err);
        await this.markFailed(r);
      }
    }
    return { processed, ok };
  }
}

module.exports = {
  NfoFetchRunner,
};
