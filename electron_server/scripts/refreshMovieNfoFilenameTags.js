'use strict';

// Offline metadata maintenance. Never initializes workers or calls providers.
const fs = require('node:fs');
const path = require('node:path');
const { XMLValidator } = require('fast-xml-parser');
const { parseNfoXml } = require('../src/workers/videoIndex/nfoParser');
const { addMetaTubeFilenameTags, mergeMovieMetadataGenres } = require('../src/workers/videoIndex/nfoFetchWorker/metatubeFilenameTags');
const { parseMoviePart, movieMetadataBaseName, movieNfoCandidates } = require('../src/workers/videoIndex/movieParts');

async function main() {
  const [database, backupRoot, mode] = process.argv.slice(2);
  if (!database || !backupRoot || !['--dry-run', '--apply'].includes(mode)) {
    throw new Error('Usage: node refreshMovieNfoFilenameTags.js DATABASE BACKUP_DIRECTORY --dry-run|--apply');
  }
  const apply = mode === '--apply';
  const db = new (require('better-sqlite3'))(database, { readonly: !apply, fileMustExist: true, timeout: 5000 });
  const rows = db.prepare("SELECT id,path,filename,media_type,nfo_tags,nfo_genres FROM video_index WHERE media_type IN ('movie','bdmv','video_ts') ORDER BY id").all();
  const summary = { movies: rows.length, missingNfo: 0, invalidNfo: 0, matched: 0, nfoChanges: 0, indexChanges: 0, errors: [] };
  const plans = [];
  for (const row of rows) {
    const disc = row.media_type !== 'movie';
    const part = !disc && row.media_type === 'movie' ? parseMoviePart(row.filename) : null;
    const base = disc ? row.filename : part ? movieMetadataBaseName(row.filename, row.path) : path.parse(row.filename).name;
    const dir = disc ? path.join(row.path, row.filename) : row.path;
    const candidates = disc ? [path.join(dir, 'movie.nfo'), path.join(dir, `${base}.nfo`)] : part ? movieNfoCandidates(dir, row.filename) :
      [path.join(dir, `${base}.nfo`), path.join(dir, 'movie.nfo'), path.join(dir, `${path.basename(dir)}.nfo`)];
    const nfo = [...new Set(candidates)].find(p => fs.existsSync(p));
    if (!nfo) { summary.missingNfo++; continue; }
    try {
      const xml = fs.readFileSync(nfo, 'utf8');
      const parsed = XMLValidator.validate(xml) === true ? parseNfoXml(xml) : null;
      if (!parsed || parsed.type !== 'movie' || !/<\/movie\s*>/i.test(xml)) { summary.invalidNfo++; continue; }
      const expected = addMetaTubeFilenameTags([], part ? base : row.filename, { isDirectory: disc });
      if (expected.length) summary.matched++;
      const tags = addMetaTubeFilenameTags(parsed.tags, part ? base : row.filename, { isDirectory: disc });
      const additions = tags.filter(tag => !(parsed.tags || []).includes(tag));
      const genres = mergeMovieMetadataGenres(parsed.genres, tags);
      const genreAdditions = genres.filter(genre => !(parsed.genres || []).includes(genre));
      const indexGenres = genres.join(',');
      const missingKeys = genres.filter(genre => !db.prepare("SELECT 1 FROM video_index2key WHERE index_id=? AND key_type='genres' AND key=?").get(row.id, genre));
      const newline = xml.includes('\r\n') ? '\r\n' : '\n';
      const nodes = additions.map(tag => `  <tag>${tag}</tag>${newline}`).concat(genreAdditions.map(genre => `  <genre>${genre}</genre>${newline}`)).join('');
      const updated = nodes ? xml.replace(/<\/movie\s*>/i, nodes + '</movie>') : xml;
      const indexTags = tags.join(',');
      if (updated !== xml) summary.nfoChanges++;
      const indexChanged = indexTags !== (row.nfo_tags || '') || indexGenres !== (row.nfo_genres || '') || missingKeys.length > 0;
      if (indexChanged) summary.indexChanges++;
      if (updated !== xml || indexChanged) plans.push({ row, nfo, xml, updated, indexTags, indexGenres, missingKeys });
    } catch (e) { summary.errors.push({ id: row.id, error: e.message }); }
  }
  if (apply) {
    fs.mkdirSync(backupRoot, { recursive: true });
    await db.backup(path.join(backupRoot, 'nascab_video.db'));
    const backupNameByNfo = new Map();
    for (const p of plans) {
      if (p.updated !== p.xml && !backupNameByNfo.has(p.nfo)) backupNameByNfo.set(p.nfo, `${p.row.id}.nfo`);
    }
    fs.writeFileSync(path.join(backupRoot, 'manifest.json'), JSON.stringify(plans.map(p => ({ id: p.row.id, nfo: p.nfo, oldTags: p.row.nfo_tags, newTags: p.indexTags, oldGenres: p.row.nfo_genres, newGenres: p.indexGenres, backup: backupNameByNfo.get(p.nfo) || null })), null, 2), { flag: 'wx' });
    const update = db.prepare('UPDATE video_index SET nfo_tags = ?, nfo_genres = ? WHERE id = ?');
    const insertKey = db.prepare("INSERT INTO video_index2key (index_id,key,key_type) SELECT ?,?,'genres' WHERE NOT EXISTS (SELECT 1 FROM video_index2key WHERE index_id=? AND key=? AND key_type='genres')");
    const syncIndex = db.transaction(p => {
      update.run(p.indexTags, p.indexGenres, p.row.id);
      for (const genre of p.missingKeys) insertKey.run(p.row.id, genre, p.row.id, genre);
    });
    const writtenNfos = new Set();
    for (const p of plans) {
      // Refuse to overwrite metadata that changed after planning.
      if (!writtenNfos.has(p.nfo) && fs.readFileSync(p.nfo, 'utf8') !== p.xml) throw new Error(`NFO changed during refresh: ${p.nfo}`);
      if (!writtenNfos.has(p.nfo) && p.updated !== p.xml) {
        fs.copyFileSync(p.nfo, path.join(backupRoot, backupNameByNfo.get(p.nfo)), fs.constants.COPYFILE_EXCL);
        fs.writeFileSync(p.nfo, p.updated, 'utf8');
      }
      writtenNfos.add(p.nfo);
      syncIndex(p);
      const verified = parseNfoXml(fs.readFileSync(p.nfo, 'utf8'));
      if (!verified || [...new Set(verified.tags)].join(',') !== p.indexTags || [...new Set(verified.genres)].join(',') !== p.indexGenres) throw new Error(`Tag verification failed: ${p.nfo}`);
    }
    fs.writeFileSync(path.join(backupRoot, 'summary.json'), JSON.stringify(summary, null, 2));
  }
  db.close();
  console.log(JSON.stringify({ mode, backup: apply ? backupRoot : null, ...summary }, null, 2));
}
main().catch(e => { console.error(e); process.exitCode = 1; });
