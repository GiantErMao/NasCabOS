'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { addMetaTubeFilenameTags, mergeMovieMetadataGenres } = require('../src/workers/videoIndex/nfoFetchWorker/metatubeFilenameTags');
const { buildMovieNfo } = require('../src/workers/videoIndex/nfoFetchWorker/jellyfinNfo');

for (const [suffix, expected] of [
  ['-C', ['中文字幕']], ['-c', ['中文字幕']], ['ch', ['中文字幕']], ['CH', ['中文字幕']],
  ['-U', ['破解版本']], ['-u', ['破解版本']],
  ['-UC', ['破解版本', '中文字幕']], ['-uc', ['破解版本', '中文字幕']],
  ['', []], ['-C-extra', []], ['-U-extra', []], ['-UC-extra', []], ['C', []], ['U', []],
]) {
  test(`filename suffix ${suffix || '(none)'}`, () => {
    assert.deepEqual(addMetaTubeFilenameTags(['provider'], `ABC-123${suffix}.mkv`), ['provider', ...expected]);
  });
}

test('preserves tags and avoids duplicates, including dotted disc folders', () => {
  assert.deepEqual(addMetaTubeFilenameTags(['中文字幕', 'provider'], 'ABC-123-UC.mp4'), ['中文字幕', 'provider', '破解版本']);
  assert.deepEqual(addMetaTubeFilenameTags([], 'ABC.123-UC', { isDirectory: true }), ['破解版本', '中文字幕']);
});

test('shared MetaTube writer emits both NFO tags and updates the index', async () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js'), 'utf8');
  const writes = [];
  const updates = [];
  const context = {
    path, addMetaTubeFilenameTags, mergeMovieMetadataGenres, buildMovieNfo,
    _mapMetaTubeMovieToNfo: () => ({ title: 'Title', tags: ['provider'] }),
    writeTextIfChanged: async (target, xml) => writes.push({ target, xml }),
    _updateIndexFromNfoAndArtwork: async args => updates.push(args),
  };
  vm.createContext(context);
  vm.runInContext('this.runner = {' + source.slice(source.indexOf('  async _writeMetaTubeMovieRow('), source.indexOf('  async _processMovieRowByMetaTube(')) + '}', context);
  context.runner.translateNfoData = async data => data;
  for (const media_type of ['movie', 'bdmv', 'video_ts']) {
    await context.runner._writeMetaTubeMovieRow({ path: '/videos', filename: media_type === 'movie' ? 'ABC-123-UC.mkv' : 'ABC.123-UC', media_type }, { number: 'ABC-123', title: 'Title' });
  }
  assert.equal(writes.length, 3);
  for (const { xml } of writes) {
    assert.match(xml, /<tag>中文字幕<\/tag>/);
    assert.match(xml, /<tag>破解版本<\/tag>/);
    assert.match(xml, /<tag>provider<\/tag>/);
    assert.match(xml, /<genre>中文字幕<\/genre>/);
    assert.match(xml, /<genre>破解版本<\/genre>/);
  }
  assert.equal(updates.length, 3);
});


test('merges filterable labels without provider tags or duplicate genres', () => {
  assert.deepEqual(mergeMovieMetadataGenres(['Drama', '中文字幕'], ['provider', 'ABC-123', '中文字幕', '破解版本']), ['Drama', '中文字幕', '破解版本']);
});
