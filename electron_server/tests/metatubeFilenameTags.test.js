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

test('uses a movie folder suffix when the video basename has none', () => {
  assert.deepEqual(addMetaTubeFilenameTags([], 'SHKD-748.mp4', { directoryName: 'SHKD-748-C' }), ['中文字幕']);
  assert.deepEqual(addMetaTubeFilenameTags([], 'IPX-916-UC-Y.mp4', { directoryName: 'IPX-916-UC' }), ['破解版本', '中文字幕']);
});

test('.ltx after a filename tag does not hide subtitle or uncensored labels', () => {
  assert.deepEqual(addMetaTubeFilenameTags([], 'SSIS-586-U.ltx.mp4'), ['破解版本']);
  assert.deepEqual(addMetaTubeFilenameTags([], 'SSIS-586-C.ltx.mp4'), ['中文字幕']);
  assert.deepEqual(addMetaTubeFilenameTags([], 'SSIS-586-UC.LTX.mkv'), ['破解版本', '中文字幕']);
  assert.deepEqual(addMetaTubeFilenameTags([], 'SSIS-586-U.ltx.mp4', { directoryName: 'SSIS-586-C' }), ['破解版本']);
  assert.deepEqual(addMetaTubeFilenameTags([], 'SSIS-586.mp4', { directoryName: 'SSIS-586-UC.ltx' }), ['破解版本', '中文字幕']);
  assert.deepEqual(addMetaTubeFilenameTags([], 'SSIS-586-U-extra.ltx.mp4'), []);
});

test('shared MetaTube writer emits both NFO tags and updates the index', async () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js'), 'utf8');
  const writes = [];
  const updates = [];
  const downloads = [];
  const context = {
    path, addMetaTubeFilenameTags, mergeMovieMetadataGenres, buildMovieNfo,
    parseMoviePart: () => null,
    movieMetadataBaseName: filename => path.parse(filename).name,
    _mapMetaTubeMovieToNfo: () => ({ title: 'Title', tags: ['provider'] }),
    _ensureDownloadedJpeg: async (_client, targetDir, fileName) => downloads.push({ targetDir, fileName }),
    writeTextIfChanged: async (target, xml) => writes.push({ target, xml }),
    _updateIndexFromNfoAndArtwork: async args => updates.push(args),
  };
  vm.createContext(context);
  vm.runInContext('this.runner = {' + source.slice(source.indexOf('  async _writeMetaTubeMovieRow('), source.indexOf('  async _processMovieRowByMetaTube(')) + '}', context);
  context.runner.translateNfoData = async data => data;
  for (const media_type of ['movie', 'bdmv', 'video_ts']) {
    await context.runner._writeMetaTubeMovieRow({ path: '/videos', filename: media_type === 'movie' ? 'ABC-123-UC.mkv' : 'ABC.123-UC', media_type }, { number: 'ABC-123', title: 'Title', cover_url: '/cover.jpg', thumb_url: '/fanart.jpg' });
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
  assert.deepEqual(downloads.map(item => item.fileName), [
    'ABC-123-UC-poster.jpg',
    'ABC-123-UC-fanart.jpg',
    'poster.jpg',
    'fanart.jpg',
    'poster.jpg',
    'fanart.jpg',
  ]);
});


test('merges filterable labels without provider tags or duplicate genres', () => {
  assert.deepEqual(mergeMovieMetadataGenres(['Drama', '中文字幕'], ['provider', 'ABC-123', '中文字幕', '破解版本']), ['Drama', '中文字幕', '破解版本']);
});
