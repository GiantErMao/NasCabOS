const naturalStringCollator = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: 'base',
});

function getFirstNonBlankValue(row, fields) {
  for (const field of Array.isArray(fields) ? fields : []) {
    const value = row && row[field] !== undefined && row[field] !== null
      ? String(row[field])
      : '';
    if (value.trim()) return value;
  }
  return '';
}

function compareNaturalRows(a, b, options = {}) {
  const {
    sortOrder = 'asc',
    valueFields = [],
    getValue,
    idField = 'id',
    tieIdOrder = 'desc',
  } = options;
  const direction = sortOrder === 'desc' ? -1 : 1;
  const resolveValue = typeof getValue === 'function'
    ? getValue
    : row => getFirstNonBlankValue(row, valueFields);
  const aValue = String(resolveValue(a) ?? '');
  const bValue = String(resolveValue(b) ?? '');
  const natural = naturalStringCollator.compare(aValue, bValue);
  if (natural !== 0) return direction * natural;

  const normalized = aValue.toLowerCase().localeCompare(bValue.toLowerCase());
  if (normalized !== 0) return direction * normalized;

  const aId = Number(a && a[idField]) || 0;
  const bId = Number(b && b[idField]) || 0;
  return tieIdOrder === 'asc' ? aId - bId : bId - aId;
}

function selectNaturalPageIds(rows, options = {}) {
  const {
    offset = 0,
    limit = 30,
    idField = 'id',
  } = options;
  const seen = new Set();
  const uniqueRows = [];
  for (const row of Array.isArray(rows) ? rows : []) {
    const id = Number(row && row[idField]) || 0;
    if (id <= 0 || seen.has(id)) continue;
    seen.add(id);
    uniqueRows.push(row);
  }

  uniqueRows.sort((a, b) => compareNaturalRows(a, b, options));
  const start = Math.max(0, Number(offset) || 0);
  const pageSize = Math.max(0, Number(limit) || 0);
  return uniqueRows.slice(start, start + pageSize).map(row => Number(row[idField]));
}

function _retainBestRows(heap, row, capacity, options) {
  if (capacity <= 0) return;
  const compare = (a, b) => compareNaturalRows(a, b, options);
  if (heap.length < capacity) {
    heap.push(row);
    let index = heap.length - 1;
    while (index > 0) {
      const parent = Math.floor((index - 1) / 2);
      if (compare(heap[parent], heap[index]) >= 0) break;
      [heap[parent], heap[index]] = [heap[index], heap[parent]];
      index = parent;
    }
    return;
  }

  if (compare(row, heap[0]) >= 0) return;
  heap[0] = row;
  let index = 0;
  while (true) {
    const left = index * 2 + 1;
    const right = left + 1;
    let worst = index;
    if (left < heap.length && compare(heap[left], heap[worst]) > 0) worst = left;
    if (right < heap.length && compare(heap[right], heap[worst]) > 0) worst = right;
    if (worst === index) break;
    [heap[index], heap[worst]] = [heap[worst], heap[index]];
    index = worst;
  }
}

/**
 * Selects one natural-sort page while retaining only offset + limit rows.
 * `rows` may be any synchronous or asynchronous iterable (including a Knex stream).
 */
async function selectNaturalPageIdsFromRows(rows, options = {}) {
  const offset = Math.max(0, Number(options.offset) || 0);
  const limit = Math.max(0, Number(options.limit) || 0);
  const capacity = offset + limit;
  const idField = options.idField || 'id';
  const heap = [];
  if (capacity === 0) return [];

  for await (const row of rows) {
    const id = row && row[idField];
    if (id === undefined || id === null || String(id) === '') continue;
    _retainBestRows(heap, row, capacity, options);
  }

  heap.sort((a, b) => compareNaturalRows(a, b, options));
  return heap.slice(offset, offset + limit).map(row => row[idField]);
}

function selectNaturalPageIdsFromIterable(rows, options = {}) {
  const offset = Math.max(0, Number(options.offset) || 0);
  const limit = Math.max(0, Number(options.limit) || 0);
  const capacity = offset + limit;
  const idField = options.idField || 'id';
  const heap = [];
  if (capacity === 0) return [];

  for (const row of rows) {
    const id = row && row[idField];
    if (id === undefined || id === null || String(id) === '') continue;
    _retainBestRows(heap, row, capacity, options);
  }

  heap.sort((a, b) => compareNaturalRows(a, b, options));
  return heap.slice(offset, offset + limit).map(row => row[idField]);
}

async function selectNaturalPageIdsFromQuery(query, options = {}) {
  return await selectNaturalPageIdsFromRows(query.stream(), options);
}

function sortRowsByPageIds(rows, pageIds, idField = 'id') {
  const rank = new Map((Array.isArray(pageIds) ? pageIds : []).map((id, index) => [Number(id), index]));
  return (Array.isArray(rows) ? rows : []).sort((a, b) => {
    const aRank = rank.get(Number(a && a[idField])) ?? Number.MAX_SAFE_INTEGER;
    const bRank = rank.get(Number(b && b[idField])) ?? Number.MAX_SAFE_INTEGER;
    return aRank - bRank;
  });
}

module.exports = {
  compareNaturalRows,
  getFirstNonBlankValue,
  selectNaturalPageIds,
  selectNaturalPageIdsFromRows,
  selectNaturalPageIdsFromIterable,
  selectNaturalPageIdsFromQuery,
  sortRowsByPageIds,
};
