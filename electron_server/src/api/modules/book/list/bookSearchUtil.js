function escapeLikeValue(input) {
  return String(input || '')
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_');
}

function buildOrderedLikePattern(input) {
  const parts = String(input || '')
    .trim()
    .split(/\s+/u)
    .map(part => part.trim())
    .filter(Boolean)
    .map(escapeLikeValue);
  return parts.length > 0 ? `%${parts.join('%')}%` : '';
}

function normalizeLetterFilter(input) {
  const value = String(input || '')
    .trim()
    .toUpperCase();
  if (value === '#' || /^[A-Z]$/.test(value)) return value;
  return '';
}

function applyTextLikeFilter(query, { alias, pattern }) {
  if (!pattern) return;
  query.where(builder => {
    builder
      .whereRaw(`${alias}.title LIKE ? ESCAPE '\\'`, [pattern])
      .orWhereRaw(`${alias}.filename LIKE ? ESCAPE '\\'`, [pattern]);
  });
}

function applyLetterFilter(query, { alias, letter }) {
  if (!letter) return;
  query.where(builder => {
    builder.where(`${alias}.title_fl`, letter).orWhere(`${alias}.filename_fl`, letter);
  });
}

module.exports = {
  applyLetterFilter,
  applyTextLikeFilter,
  buildOrderedLikePattern,
  escapeLikeValue,
  normalizeLetterFilter,
};
