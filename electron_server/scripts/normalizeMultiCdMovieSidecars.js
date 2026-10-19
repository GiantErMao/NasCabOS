'use strict';

// Consolidate legacy per-CD NFO/artwork into group-level sidecars. Apply mode
// backs up every per-CD sidecar before deleting it.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { parseMoviePart, movieMetadataBaseName, moviePartBaseNamesInDirectory } = require('../src/workers/videoIndex/movieParts');

const IMAGE_EXTENSIONS = ['.jpg', '.jpeg', '.png', '.webp'];

function existingFiles(paths) {
  return [...new Set(paths)].filter(file => {
    try { return fs.statSync(file).isFile(); } catch (_) { return false; }
  });
}

function candidatesForGroup(dir, baseNames) {
  const poster = [];
  const fanart = [];
  const logo = [];
  const nfo = [];
  for (const base of baseNames) {
    nfo.push(path.join(dir, `${base}.nfo`));
    for (const ext of IMAGE_EXTENSIONS) {
      poster.push(path.join(dir, `${base}-poster${ext}`));
      poster.push(path.join(dir, `${base}-post${ext}`));
      poster.push(path.join(dir, `${base}-thumb${ext}`));
      fanart.push(path.join(dir, `${base}-fanart${ext}`));
      logo.push(path.join(dir, `${base}-logo${ext}`));
      logo.push(path.join(dir, `${base}-clearlogo${ext}`));
    }
  }
  return { nfo, poster, fanart, logo };
}

async function main() {
  const [database, requestedMode, backupRoot] = process.argv.slice(2);
  const mode = requestedMode || '--dry-run';
  if (!database || !['--dry-run', '--apply'].includes(mode) || (mode === '--apply' && !backupRoot)) {
    throw new Error('Usage: node normalizeMultiCdMovieSidecars.js DATABASE [--dry-run|--apply [BACKUP_DIR]]');
  }
  const apply = mode === '--apply';
  const db = new (require('better-sqlite3'))(database, { readonly: !apply, fileMustExist: true, timeout: 5000 });
  const rows = db.prepare("SELECT path,filename FROM video_index WHERE media_type='movie' AND is_file=1 AND movie_group_key<>'' ORDER BY path,movie_part_no,id").all();
  const groups = new Map();
  for (const row of rows) {
    const part = parseMoviePart(row.filename);
    if (!part) continue;
    const key = `${row.path}\0${part.key}`;
    if (!groups.has(key)) groups.set(key, { dir: row.path, filename: row.filename });
  }

  const actions = [];
  const verification = Object.fromEntries(['nfo', 'poster', 'fanart', 'logo'].map(kind => [kind, {
    groups: 0,
    canonicalPresent: 0,
    canonicalMissing: 0,
    legacyRemaining: 0,
  }]));
  for (const group of groups.values()) {
    const partBases = moviePartBaseNamesInDirectory(group.dir, group.filename);
    const canonicalBase = movieMetadataBaseName(group.filename, group.dir);
    const sources = candidatesForGroup(group.dir, partBases);
    const targets = {};
    for (const kind of Object.keys(sources)) {
      const canonicalSuffixes = {
        nfo: [''],
        poster: ['-poster', '-post', '-thumb'],
        fanart: ['-fanart'],
        logo: ['-logo', '-clearlogo'],
      }[kind];
      const extensions = kind === 'nfo' ? ['.nfo'] : IMAGE_EXTENSIONS;
      const existingCanonical = canonicalSuffixes.flatMap(suffix => extensions.map(ext =>
        path.join(group.dir, `${canonicalBase}${suffix}${ext}`),
      )).find(file => fs.existsSync(file));
      const source = existingFiles(sources[kind])[0];
      const ext = kind === 'nfo' ? '.nfo' : path.extname(source || '.jpg');
      const suffix = kind === 'nfo' ? '' : `-${kind}`;
      targets[kind] = existingCanonical || path.join(group.dir, `${canonicalBase}${suffix}${ext}`);
    }

    for (const kind of Object.keys(targets)) {
      const target = targets[kind];
      const candidates = existingFiles(sources[kind]).filter(file => file !== target);
      verification[kind].groups += 1;
      verification[kind][fs.existsSync(target) ? 'canonicalPresent' : 'canonicalMissing'] += 1;
      verification[kind].legacyRemaining += candidates.length;
      if (candidates.length === 0) continue;
      actions.push({
        status: fs.existsSync(target) ? 'canonical_exists' : 'copy',
        kind,
        source: fs.existsSync(target) ? null : candidates[0],
        target,
        legacySources: candidates,
      });
    }
  }

  const conflicts = actions.flatMap(action => {
    const hashes = [...new Set((action.legacySources || []).map(file =>
      crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'),
    ))];
    return hashes.length > 1 ? [{ kind: action.kind, target: action.target, distinctContents: hashes.length }] : [];
  });

  if (apply) {
    const legacyFiles = [...new Set(actions.flatMap(action => action.legacySources || []))];
    // Back up the complete deletion set first; any backup collision aborts safely.
    for (const file of legacyFiles) {
      const backup = path.join(backupRoot, path.resolve(file).replace(/^[/\\]+/, ''));
      fs.mkdirSync(path.dirname(backup), { recursive: true });
      fs.copyFileSync(file, backup, fs.constants.COPYFILE_EXCL);
    }
    for (const action of actions) {
      if (action.status === 'copy') {
        fs.mkdirSync(path.dirname(action.target), { recursive: true });
        fs.copyFileSync(action.source, action.target, fs.constants.COPYFILE_EXCL);
        const sourceBytes = fs.readFileSync(action.source);
        const targetBytes = fs.readFileSync(action.target);
        if (!sourceBytes.equals(targetBytes)) throw new Error(`Canonical verification failed: ${action.target}`);
        action.status = 'copied_and_verified';
      }
    }
    for (const file of legacyFiles) fs.unlinkSync(file);
    for (const action of actions) action.removedLegacyFiles = (action.legacySources || []).length;
  }

  db.close();
  const summary = Object.fromEntries(['nfo', 'poster', 'fanart', 'logo'].map(kind => {
    const rows = actions.filter(action => action.kind === kind);
    return [kind, {
      groups: rows.length,
      copy: rows.filter(action => action.status === 'copy' || action.status === 'copied_and_verified').length,
      canonicalAlreadyPresent: rows.filter(action => action.status === 'canonical_exists').length,
      legacyFiles: rows.reduce((count, action) => count + (action.legacySources || []).length, 0),
    }];
  }));
  console.log(JSON.stringify({ mode, groups: groups.size, summary, verification, conflicts, actions }, null, 2));
}

main().catch(error => { console.error(error); process.exitCode = 1; });
