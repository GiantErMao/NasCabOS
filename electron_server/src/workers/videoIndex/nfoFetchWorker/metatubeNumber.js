'use strict';

function extractMetaTubeNumberQueryFromText(text) {
  const base = String(text || '').trim();
  if (!base) return '';
  const patterns = [
    /(^|[^0-9a-z])((?:fc2[-_\s]?(?:ppv[-_\s]?)?\d{5,8}))(?=$|[^0-9a-z])/ig,
    /(^|[^0-9a-z])((?:1pondo[-_\s]?\d{6}[-_]\d{2,4}))(?=$|[^0-9a-z])/ig,
    /(^|[^0-9a-z])((?:\d{6}[-_]\d{2,4}[-_\s]?1pon(?:do)?))(?=$|[^0-9a-z])/ig,
    /(^|[^0-9a-z])([a-z]{2,8}[-_\s]\d{2,6}(?:[-_]\d{1,3})?)(?=$|[^0-9a-z])/ig,
    /(^|[^0-9a-z])([a-z]{1,8}\d{3,8})(?=$|[^0-9a-z])/ig,
  ];
  for (const pattern of patterns) {
    for (const match of base.matchAll(pattern)) {
      const code = normalizeMetaTubeNumberQuery(match && match[2] ? match[2] : '');
      if (isLikelyMetaTubeNumber(code)) return code;
    }
  }
  return '';
}

function normalizeMetaTubeNumberQuery(value) {
  const raw = String(value || '').trim();
  const reverse1Pondo = raw.match(/^(\d{6}[-_]\d{2,4})[-_\s]?1pon(?:do)?$/i);
  if (reverse1Pondo) return `1PONDO-${reverse1Pondo[1]}`;
  return raw.replace(/\s+/g, '-').replace(/-+/g, '-').toUpperCase();
}

function normalizeComparableMetaTubeNumber(value) {
  return normalizeMetaTubeNumberQuery(value).replace(/[^A-Z0-9]/g, '');
}

function isLikelyMetaTubeNumber(code) {
  const s = String(code || '').trim();
  if (!s || /^[xh]26[456]$/i.test(s)) return false;
  const compact = s.match(/^([a-z]{1,8})(\d{3,8})$/i);
  const parts = compact ? [compact[1], compact[2]] : s.split(/[-_]/);
  if (parts.length < 2) return false;
  const prefix = String(parts[0] || '').toLowerCase();
  const lastNumber = Number(parts[parts.length - 1] || 0) || 0;
  if (!lastNumber) return false;
  const denyPrefixes = new Set(['bd', 'bluray', 'dvd', 'hdr', 'remux', 'uhd', 'web', 'webrip']);
  if (denyPrefixes.has(prefix)) return false;
  const resolutionNumbers = new Set([480, 540, 720, 1080, 1440, 2160, 4320]);
  return !resolutionNumbers.has(lastNumber);
}

// Keyword searches for a recognizable number must never offer a different movie.
// Some providers omit numbers from search results, so verify those via details.
async function filterMetaTubeMovieSearchResults(client, results, query, defaultProvider = '') {
  const expected = extractMetaTubeNumberQueryFromText(query);
  if (!expected) return Array.isArray(results) ? results : [];
  const key = normalizeComparableMetaTubeNumber(expected);
  const candidates = (Array.isArray(results) ? results : []).filter(item => {
    const number = String(item && item.number || '').trim();
    return !number || normalizeComparableMetaTubeNumber(number) === key;
  });
  const verified = [];
  for (const item of candidates) {
    const provider = String(item && item.provider || defaultProvider).trim();
    const id = String(item && item.id || '').trim();
    if (!provider || !id) continue;
    const details = await client.getMovieDetails(provider, id).catch(() => null);
    // A provider may expose a valid numbered search record while its detail
    // endpoint fails with "incomplete metadata". Keep only that exact record.
    const resolved = details ? { ...item, ...details, provider, id, number: details.number || item.number } : item;
    if (normalizeComparableMetaTubeNumber(resolved.number) !== key) continue;
    verified.push(resolved);
  }
  return verified;
}

module.exports = {
  extractMetaTubeNumberQueryFromText,
  normalizeComparableMetaTubeNumber,
  filterMetaTubeMovieSearchResults,
};
