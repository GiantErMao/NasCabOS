const assert = require('node:assert/strict');
const test = require('node:test');

const {
  buildOrderedLikePattern,
  normalizeLetterFilter,
} = require('../src/api/modules/book/list/bookSearchUtil');

let knexFactory;
let BookListService;
try {
  knexFactory = require('knex');
} catch (error) {
  if (!error || error.code !== 'MODULE_NOT_FOUND') throw error;
  // The pure search tests still run in source-only worktrees without npm install.
}
if (knexFactory) {
  BookListService = require('../src/api/modules/book/list/bookListService');
}

test('builds ordered fuzzy patterns and escapes LIKE metacharacters', () => {
  assert.equal(buildOrderedLikePattern('a c'), '%a%c%');
  assert.equal(buildOrderedLikePattern('  中文   书  '), '%中文%书%');
  assert.equal(buildOrderedLikePattern('100%_real\\name'), '%100\\%\\_real\\\\name%');
  assert.equal(buildOrderedLikePattern('   '), '');
});

test('normalizes only supported initial-letter filters', () => {
  assert.equal(normalizeLetterFilter('a'), 'A');
  assert.equal(normalizeLetterFilter('#'), '#');
  assert.equal(normalizeLetterFilter('AB'), '');
  assert.equal(normalizeLetterFilter('中'), '');
});

test(
  'searches ordered fragments, single letters, and children without flattening series',
  { skip: !knexFactory || !BookListService },
  async t => {
    const knex = knexFactory({
      client: 'better-sqlite3',
      connection: { filename: ':memory:' },
      useNullAsDefault: true,
    });
    t.after(() => knex.destroy());

    await knex.schema.createTable('book_index', table => {
      table.integer('id').primary();
      table.string('type');
      table.string('path');
      table.string('filename');
      table.string('file_hash');
      table.string('title');
      table.string('artist');
      table.string('year');
      table.string('ext');
      table.integer('size');
      table.integer('cover_state');
      table.integer('view_time');
      table.integer('create_time');
      table.string('show_type');
      table.integer('total_page');
      table.integer('book_count');
      table.integer('is_file');
      table.string('title_fl');
      table.string('filename_fl');
    });

    const root = '/library';
    await knex('book_index').insert([
      {
        id: 1,
        type: 'book',
        path: root,
        filename: 'abcde.epub',
        title: 'ABCDE',
        show_type: 'book',
        is_file: 1,
        title_fl: 'A',
        filename_fl: 'A',
        create_time: 1,
      },
      {
        id: 2,
        type: 'book',
        path: root,
        filename: 'Series',
        title: 'Unrelated series',
        show_type: 'series',
        is_file: 0,
        title_fl: 'U',
        filename_fl: 'S',
        create_time: 2,
      },
      {
        id: 3,
        type: 'book',
        path: `${root}/Series`,
        filename: 'child.epub',
        title: 'A hidden C title',
        show_type: 'subbook',
        is_file: 1,
        title_fl: 'A',
        filename_fl: 'C',
        create_time: 3,
      },
      {
        id: 4,
        type: 'book',
        path: root,
        filename: 'other.epub',
        title: 'Beta',
        show_type: 'book',
        is_file: 1,
        title_fl: 'B',
        filename_fl: 'O',
        create_time: 4,
      },
    ]);

    const service = new BookListService(knex);
    service.getValidPaths = async () => [root];

    const fuzzy = await service.listPaged(
      { page: 1, page_size: 20, type: 'book', search: 'a c' },
      null
    );
    assert.equal(fuzzy.pagination.total, 2);
    assert.deepEqual(
      fuzzy.items.map(item => item.id).sort((a, b) => a - b),
      [1, 2]
    );
    assert.equal(fuzzy.items.some(item => item.id === 3), false);

    const singleLetterSearch = await service.listPaged(
      { page: 1, page_size: 20, type: 'book', search: 'a' },
      null
    );
    assert.equal(singleLetterSearch.items.some(item => item.id === 4), true);

    const initialFilter = await service.listPaged(
      { page: 1, page_size: 20, type: 'book', letter_filter: 'A' },
      null
    );
    assert.deepEqual(
      initialFilter.items.map(item => item.id).sort((a, b) => a - b),
      [1, 2]
    );
  }
);
