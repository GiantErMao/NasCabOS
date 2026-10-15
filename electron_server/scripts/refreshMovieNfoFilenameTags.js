'use strict';

// Offline metadata maintenance. Never initializes workers or calls providers.
const fs = require('node:fs');
const path = require('node:path');
const { XMLValidator } = require('fast-xml-parser');
const { parseNfoXml } = require('../src/workers/videoIndex/nfoParser');
const { addMetaTubeFilenameTags } = require('../src/workers/videoIndex/nfoFetchWorker/metatubeFilenameTags');

async function main() {
  const [database, backupRoot, mode] = process.argv.slice(2);
  if (!database || !backupRoot || !['--dry-run', '--apply'].includes(mode)) {
    throw new Error('Usage: node refreshMovieNfoFilenameTags.js DATABASE BACKUP_DIRECTORY --dry-run|--apply');
  }
  const apply = mode === '--apply';
  const db = new (require('better-sqlite3'))(database, { readonly: !apply, fileMustExist: true, timeout: 5000 });
  const rows = db.prepare("SELECT id,path,filename,media_type,nfo_tags FROM video_index WHERE media_type IN ('movie','bdmv','video_ts') ORDER BY id").all();
  const summary = { movies: rows.length, missingNfo: 0, invalidNfo: 0, matched: 0, nfoChanges: 0, indexChanges: 0, errors: [] };
  const plans = [];
  for (const row of rows) {
    const disc = row.media_type !== 'movie';
    const base = disc ? row.filename : path.parse(row.filename).name;
    const dir = disc ? path.join(row.path, row.filename) : row.path;
    const candidates = disc ? [path.join(dir, 'movie.nfo'), path.join(dir, `${base}.nfo`)] :
      [path.join(dir, `${base}.nfo`), path.join(dir, 'movie.nfo'), path.join(dir, `${path.basename(dir)}.nfo`)];
    const nfo = [...new Set(candidates)].find(p => fs.existsSync(p));
    if (!nfo) { summary.missingNfo++; continue; }
    try {
      const xml = fs.readFileSync(nfo, 'utf8');
      const parsed = XMLValidator.validate(xml) === true ? parseNfoXml(xml) : null;
      if (!parsed || parsed.type !== 'movie' || !/<\/movie\s*>/i.test(xml)) { summary.invalidNfo++; continue; }
      const expected = addMetaTubeFilenameTags([], row.filename, { isDirectory: disc });
      if (expected.length) summary.matched++;
      const tags = addMetaTubeFilenameTags(parsed.tags, row.filename, { isDirectory: disc });
      const additions = tags.filter(tag => !(parsed.tags || []).includes(tag));
      const newline = xml.includes('\r\n') ? '\r\n' : '\n';
      const updated = additions.length ? xml.replace(/<\/movie\s*>/i, additions.map(tag => `  <tag>${tag}</tag>${newline}`).join('') + '</movie>') : xml;
      const indexTags = tags.join(',');
      if (updated !== xml) summary.nfoChanges++;
      if (indexTags !== (row.nfo_tags || '')) summary.indexChanges++;
      if (updated !== xml || indexTags !== (row.nfo_tags || '')) plans.push({ row, nfo, xml, updated, indexTags });
    } catch (e) { summary.errors.push({ id: row.id, error: e.message }); }
  }
  if (apply) {
    fs.mkdirSync(backupRoot, { recursive: true });
    await db.backup(path.join(backupRoot, 'nascab_video.db'));
    fs.writeFileSync(path.join(backupRoot, 'manifest.json'), JSON.stringify(plans.map(p => ({ id: p.row.id, nfo: p.nfo, oldTags: p.row.nfo_tags, newTags: p.indexTags, backup: p.updated !== p.xml ? `${p.row.id}.nfo` : null })), null, 2), { flag: 'wx' });
    const update = db.prepare('UPDATE video_index SET nfo_tags = ? WHERE id = ?');
    for (const p of plans) {
      // Refuse to overwrite metadata that changed after planning.
      if (fs.readFileSync(p.nfo, 'utf8') !== p.xml) throw new Error(`NFO changed during refresh: ${p.nfo}`);
      if (p.updated !== p.xml) {
        fs.copyFileSync(p.nfo, path.join(backupRoot, `${p.row.id}.nfo`), fs.constants.COPYFILE_EXCL);
        fs.writeFileSync(p.nfo, p.updated, 'utf8');
      }
      update.run(p.indexTags, p.row.id);
      const verified = parseNfoXml(fs.readFileSync(p.nfo, 'utf8'));
      if (!verified || [...new Set(verified.tags)].join(',') !== p.indexTags) throw new Error(`Tag verification failed: ${p.nfo}`);
    }
    fs.writeFileSync(path.join(backupRoot, 'summary.json'), JSON.stringify(summary, null, 2));
  }
  db.close();
  console.log(JSON.stringify({ mode, backup: apply ? backupRoot : null, ...summary }, null, 2));
}
main().catch(e => { console.error(e); process.exitCode = 1; });
