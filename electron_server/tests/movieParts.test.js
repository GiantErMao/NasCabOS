'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  parseMoviePart,
  whereMovieRepresentative,
} = require('../src/workers/videoIndex/movieParts');

test('terminal CD suffix groups JUVR-254 parts in numeric order', () => {
  const parts = ['juvr-254.CD3.mp4', 'juvr-254.CD1.mp4', 'juvr-254.CD2.mp4']
    .map(parseMoviePart)
    .sort((a, b) => a.number - b.number);
  assert.deepEqual(parts.map(part => part.number), [1, 2, 3]);
  assert.deepEqual(parts.map(part => part.key), ['juvr-254', 'juvr-254', 'juvr-254']);
});

test('does not group unrelated names or misleading embedded CD text', () => {
  assert.equal(parseMoviePart('juvr-254.mp4'), null);
  assert.equal(parseMoviePart('juvr-254.CD1.sample.mp4'), null);
  assert.equal(parseMoviePart('juvr-254.CD0.mp4'), null);
  assert.equal(parseMoviePart('CD1.mp4'), null);
  assert.notEqual(parseMoviePart('juvr-255.CD1.mp4').key, parseMoviePart('juvr-254.CD1.mp4').key);
});

test('recognizes lowercase CD suffixes on NFO filenames', () => {
  assert.deepEqual(parseMoviePart('JUVR-254.cd1.nfo'), {
    key: 'juvr-254',
    titleStem: 'JUVR-254',
    number: 1,
  });
});

// Captures what knex would receive. knex invokes these callbacks with the child
// builder bound as `this`, so the stub has to call them the same way.
function captureSubquery(alias) {
  const conditions = [];
  const child = {
    select() {
      return child;
    },
    from(table) {
      conditions.push(`from ${table}`);
      return child;
    },
    whereRaw(sql) {
      conditions.push(sql);
      return child;
    },
  };
  const parent = {
    whereNotExists(callback) {
      callback.call(child, child);
      return parent;
    },
  };
  whereMovieRepresentative(parent, alias);
  return conditions;
}

test('representative filter references the caller alias for every column', () => {
  for (const alias of ['v', 'video_index']) {
    const conditions = captureSubquery(alias);
    assert.ok(conditions.includes('from video_index as sibling'), `sibling table missing for ${alias}`);
    for (const condition of conditions.slice(1)) {
      assert.ok(condition.includes(alias), `condition does not use alias ${alias}: ${condition}`);
    }
    // Every referenced outer column must be qualified; an unqualified column
    // would silently resolve to `sibling` and keep every part visible.
    for (const column of ['media_type', 'path', 'movie_group_key', 'movie_part_no', 'id']) {
      assert.ok(
        conditions.some(condition => condition.includes(`${alias}.${column}`)),
        `outer column ${alias}.${column} never compared`,
      );
    }
  }
});

test('representative filter leaves single-part movies untouched', () => {
  for (const alias of ['v']) {
    const conditions = captureSubquery(alias);
    assert.ok(
      conditions.some(condition => condition.includes(`${alias}.movie_group_key <> ''`)),
      'rows without a group key would be filtered out',
    );
  }
});
