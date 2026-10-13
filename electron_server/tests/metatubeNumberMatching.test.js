'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const numberRules = require('../src/workers/videoIndex/nfoFetchWorker/metatubeNumber');
const { parseMetaTubeScrapeId } = require('../src/workers/videoIndex/nfoFetchWorker/metatubeClient');

// Load the pure matching logic without initializing the server or its databases.
const source = fs.readFileSync(path.join(__dirname, '../src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js'), 'utf8');
function createRunner(detailsById = {}) {
  const context = {
    Logger: { warn() {} },
    _extractMetaTubeNumberQueryFromText: numberRules.extractMetaTubeNumberQueryFromText,
    _extractMetaTubeNumberQueryFromFilename: filename => numberRules.extractMetaTubeNumberQueryFromText(path.parse(filename).name),
    _normalizeComparableMetaTubeNumber: numberRules.normalizeComparableMetaTubeNumber,
    path,
    parseMetaTubeScrapeId,
  };
  vm.createContext(context);
  vm.runInContext(
    source.slice(source.indexOf('function _pickDateText('), source.indexOf('function _mapMetaTubeMovieToNfo(')) +
      source.slice(source.indexOf('function _mergeMetaTubeMovie('), source.indexOf('function _pickLogoPathFromImages(')) +
      'this.runner = {' + source.slice(source.indexOf('  async _processMovieRowByMetaTubeId('), source.indexOf('  async processMovieRow(')).replace('  async _pickMetaTubeMovieWithDetails(', '  ,async _pickMetaTubeMovieWithDetails(') + '};',
    context
  );
  context.runner.metatube = { getMovieDetails: async (_, id) => detailsById[id] || null };
  return context;
}

test('recognizes compact numbers and existing filename formats', () => {
  const context = createRunner();
  for (const [input, expected] of [
    ['k0871', 'K0871'], ['Tokyo-Hot -k0871', 'K0871'], ['[n1234] title', 'N1234'],
    ['ABP-123', 'ABP-123'], ['FC2-PPV-1234567', 'FC2-PPV-1234567'],
    ['123456_123-1pon', '1PONDO-123456_123'],
    ['1080p x264', ''], ['h265 HDR1080', ''], ['S01E01', ''], ['prefixk0871suffix', ''],
  ]) assert.equal(context._extractMetaTubeNumberQueryFromText(input), expected, input);
});

test('ignores placeholder release dates from incomplete MetaTube metadata', () => {
  const context = createRunner();
  assert.equal(context._pickDateText('0001-01-01'), '');
  assert.equal(context._pickDateText('2020-03-14'), '2020-03-14');
});

test('rejects unrelated search results for K0871', async () => {
  const { runner } = createRunner();
  assert.equal(await runner._pickMetaTubeMovieWithDetails([
    { provider: 'MGS', id: 'wrong', number: '002HODV-21188', title: 'Unrelated' },
  ], 'K0871'), null);
});

test('accepts an exact number regardless of case and separator', async () => {
  const { runner } = createRunner({ correct: { number: 'k0871', title: 'Correct' } });
  const result = await runner._pickMetaTubeMovieWithDetails([
    { provider: 'JavBus', id: 'correct', number: 'K-0871' },
  ], 'K0871');
  assert.equal(result.title, 'Correct');
});

test('checks missing search numbers against details before selecting', async () => {
  const { runner } = createRunner({ wrong: { number: 'OTHER-123' }, correct: { number: 'K0871', title: 'Correct' } });
  const result = await runner._pickMetaTubeMovieWithDetails([
    { provider: 'MGS', id: 'wrong' }, { provider: 'JavBus', id: 'correct' },
  ], 'K0871');
  assert.equal(result.title, 'Correct');
});

test('rejects a detail number that contradicts an exact search result', async () => {
  const { runner } = createRunner({ wrong: { number: 'OTHER-123', summary: 'Rich metadata', genres: ['Genre'] } });
  assert.equal(await runner._pickMetaTubeMovieWithDetails([
    { provider: 'JavBus', id: 'wrong', number: 'K0871' },
  ], 'K0871'), null);
});

test('rejects candidates whose number remains unknown', async () => {
  const { runner } = createRunner();
  assert.equal(await runner._pickMetaTubeMovieWithDetails([{ provider: 'JavBus', id: 'unknown' }], 'K0871'), null);
});

test('uses an exact numbered search record when its detail endpoint fails', async () => {
  const { runner } = createRunner();
  const result = await runner._pickMetaTubeMovieWithDetails([
    { provider: 'TOKYO-HOT', id: '21188', number: 'k0871', title: 'Correct movie' },
  ], 'K0871');
  assert.equal(result.number, 'k0871');
  assert.equal(result.title, 'Correct movie');
});

test('manual number search keeps only results confirmed by movie details', async () => {
  const details = {
    wrong: { number: '002HODV-21188' },
    correct: { number: 'K-0871', title: 'Correct title' },
    falsePositive: { number: 'OTHER-123' },
  };
  const client = { getMovieDetails: async (_, id) => details[id] || null };
  const results = await numberRules.filterMetaTubeMovieSearchResults(client, [
    { provider: 'MGS', id: 'wrong', number: '002HODV-21188' },
    { provider: 'JavBus', id: 'correct' },
    { provider: 'Other', id: 'falsePositive', number: 'K0871' },
  ], 'k0871');
  assert.deepEqual(results.map(item => item.id), ['correct']);
  assert.equal(results[0].title, 'Correct title');
});

test('manual title search retains normal provider results without detail requests', async () => {
  const client = { getMovieDetails: async () => { throw new Error('unexpected detail request'); } };
  const results = [{ provider: 'JavBus', id: 'one', title: 'Title' }];
  assert.equal(await numberRules.filterMetaTubeMovieSearchResults(client, results, 'Title'), results);
});

test('manual number search retains an exact record when detail endpoint fails', async () => {
  const client = { getMovieDetails: async () => { throw new Error('incomplete metadata'); } };
  const results = await numberRules.filterMetaTubeMovieSearchResults(client, [
    { provider: 'TOKYO-HOT', id: '21188', number: 'k0871', title: 'Correct movie' },
    { provider: 'MGS', id: 'wrong', number: '002HODV-21188' },
    { provider: 'Other', id: 'unknown' },
  ], 'K0871');
  assert.deepEqual(results.map(item => item.id), ['21188']);
});

test('manual scrape retries the filename number and never the unrelated numeric ID', async () => {
  const { runner } = createRunner();
  const searched = [];
  let written = null;
  runner.metatube = {
    getMovieDetails: async () => { throw new Error('incomplete metadata'); },
    searchMovie: async args => {
      searched.push(args);
      return [
        { provider: 'MGS', id: '21188', number: '002HODV-21188' },
        { provider: 'TOKYO-HOT', id: '21188', number: 'k0871', title: 'Correct movie' },
      ];
    },
  };
  runner._writeMetaTubeMovieRow = async (_, movie) => { written = movie; return !!movie; };
  const done = await runner._processMovieRowByMetaTubeId({ filename: 'k0871.mp4', path: '/movies/Tokyo-Hot -k0871' }, 'TOKYO-HOT:21188');
  assert.equal(done, true);
  assert.equal(searched[0].query, 'K0871');
  assert.equal(searched[0].provider, 'TOKYO-HOT');
  assert.equal(written.number, 'k0871');
});
