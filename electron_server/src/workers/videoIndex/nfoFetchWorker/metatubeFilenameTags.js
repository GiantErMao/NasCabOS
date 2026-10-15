'use strict';

const path = require('node:path');

// Match the original video basename, before search normalization or translation.
function addMetaTubeFilenameTags(tags, filename, { isDirectory = false } = {}) {
  const name = path.basename(String(filename || '').trim());
  const base = isDirectory ? name : path.parse(name).name;
  const out = new Set(Array.isArray(tags) ? tags : []);
  if (/-uc$/i.test(base)) {
    out.add('破解版本');
    out.add('中文字幕');
  } else if (/-u$/i.test(base)) {
    out.add('破解版本');
  } else if (
    /-c$/i.test(base) ||
    /(?:^|[^a-z0-9])[a-z]{1,8}[-_\s]?\d{2,8}(?:[-_]\d{1,3})?ch$/i.test(base)
  ) {
    out.add('中文字幕');
  }
  return [...out];
}

// Only filename-derived labels join the existing genre/filter taxonomy.
// Provider names, catalogue numbers and other NFO tags remain tags.
function mergeMovieMetadataGenres(genres, tags) {
  return [...new Set([
    ...(Array.isArray(genres) ? genres : []),
    ...(Array.isArray(tags) ? tags : []).filter(tag => tag === '中文字幕' || tag === '破解版本'),
  ])];
}

module.exports = { addMetaTubeFilenameTags, mergeMovieMetadataGenres };
