'use strict';

// Offline artwork migration. It never initializes workers or calls metadata providers.
const fs = require('node:fs');
const path = require('node:path');

const IMAGE_RE = /-post\.(jpe?g|png|webp)$/i;
const NFO_REF_RE = /-post\.(jpe?g|png|webp)/gi;

function walk(root, visit) {
  const pending = [root];
  while (pending.length) {
    const dir = pending.pop();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) pending.push(full);
      else if (entry.isFile()) visit(full);
    }
  }
}

function main() {
  const args = process.argv.slice(2);
  const mode = args.shift();
  if (!['--dry-run', '--apply'].includes(mode) || args.length === 0) {
    throw new Error('Usage: node migrateMoviePosterNaming.js --dry-run|--apply ROOT [ROOT ...]');
  }
  const apply = mode === '--apply';
  const summary = {
    roots: args,
    legacyPosters: 0,
    renamed: 0,
    duplicateRemoved: 0,
    conflictingPosterKept: 0,
    nfoScanned: 0,
    nfoUpdated: 0,
    errors: [],
  };
  const nfos = [];

  for (const root of args) {
    walk(root, file => {
      if (/\.nfo$/i.test(file)) nfos.push(file);
      if (!IMAGE_RE.test(file)) return;
      summary.legacyPosters++;
      const target = file.replace(IMAGE_RE, '-poster.$1');
      try {
        if (!fs.existsSync(target)) {
          if (apply) fs.renameSync(file, target);
          summary.renamed++;
          return;
        }
        const oldStat = fs.statSync(file);
        const newStat = fs.statSync(target);
        const same = oldStat.size === newStat.size && fs.readFileSync(file).equals(fs.readFileSync(target));
        if (apply) fs.unlinkSync(file);
        if (same) summary.duplicateRemoved++;
        else summary.conflictingPosterKept++;
      } catch (error) {
        summary.errors.push({ file, error: error.message });
      }
    });
  }

  for (const file of nfos) {
    summary.nfoScanned++;
    try {
      const before = fs.readFileSync(file, 'utf8');
      const after = before.replace(NFO_REF_RE, '-poster.$1');
      if (after === before) continue;
      if (apply) fs.writeFileSync(file, after, 'utf8');
      summary.nfoUpdated++;
    } catch (error) {
      summary.errors.push({ file, error: error.message });
    }
  }

  console.log(JSON.stringify({ mode, ...summary }, null, 2));
  if (summary.errors.length) process.exitCode = 1;
}

main();
