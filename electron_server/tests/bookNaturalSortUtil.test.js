const assert = require('node:assert/strict');
const test = require('node:test');

const {
  compareNaturalRows,
  selectNaturalPageIds,
  sortRowsByPageIds,
} = require('../src/utils/naturalSortUtil');

test('sorts episode numbers naturally in ascending order', () => {
  const rows = [
    { id: 10, filename: '第10话.epub', title: '' },
    { id: 2, filename: '第2话.epub', title: '' },
    { id: 1, filename: '第1话.epub', title: '' },
    { id: 20, filename: '第20话.epub', title: '' },
  ];

  rows.sort((a, b) => compareNaturalRows(a, b, {
    sortOrder: 'asc',
    valueFields: ['title', 'filename'],
  }));

  assert.deepEqual(
    rows.map(row => row.filename),
    ['第1话.epub', '第2话.epub', '第10话.epub', '第20话.epub'],
  );
});

test('uses title when present and preserves natural order across pages', () => {
  const rows = [
    { id: 1, filename: 'z.epub', title: '第1话' },
    { id: 2, filename: 'a.epub', title: '第2话' },
    { id: 10, filename: 'b.epub', title: '第10话' },
    { id: 20, filename: 'c.epub', title: '第20话' },
  ];

  assert.deepEqual(
    selectNaturalPageIds(rows, {
      sortOrder: 'asc',
      offset: 2,
      limit: 2,
      valueFields: ['title', 'filename'],
    }),
    [10, 20],
  );
  assert.deepEqual(
    selectNaturalPageIds(rows, {
      sortOrder: 'desc',
      offset: 0,
      limit: 2,
      valueFields: ['title', 'filename'],
    }),
    [20, 10],
  );
});

test('deduplicates joined rows and uses descending ids as a stable tie breaker', () => {
  const rows = [
    { id: 1, filename: 'Track 2.mp3' },
    { id: 3, filename: 'Track 2.mp3' },
    { id: 3, filename: 'Track 2.mp3' },
    { id: 2, filename: 'Track 10.mp3' },
  ];

  assert.deepEqual(
    selectNaturalPageIds(rows, {
      sortOrder: 'asc',
      offset: 0,
      limit: 10,
      valueFields: ['filename'],
    }),
    [3, 1, 2],
  );
});

test('restores full query rows to the selected natural page order', () => {
  const rows = [
    { id: 10, filename: '第10话.mp4' },
    { id: 1, filename: '第1话.mp4' },
    { id: 2, filename: '第2话.mp4' },
  ];

  assert.deepEqual(
    sortRowsByPageIds(rows, [1, 2, 10]).map(row => row.id),
    [1, 2, 10],
  );
});
