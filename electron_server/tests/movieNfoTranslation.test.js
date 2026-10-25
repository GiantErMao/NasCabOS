'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { isChineseText, translateMovieNfoXml } = require('../src/api/modules/video/detail/movieNfoTranslation');
const { MetadataTranslateClient } = require('../src/workers/videoIndex/nfoFetchWorker/metadataTranslateClient');

test('translates non-Chinese movie fields and retains the original title', async () => {
  const xml = '<movie><title>SSIS-586 日本語の映画</title><originaltitle>SSIS-586</originaltitle><plot>日本語の説明</plot><genre>女優</genre><genre>中文字幕</genre><tag>FANZA</tag></movie>';
  const parsed = { title: 'SSIS-586 日本語の映画', originalTitle: 'SSIS-586', plot: '日本語の説明', genres: ['女優', '中文字幕'] };
  const calls = [];
  const translator = { translateTextStrict: async text => {
    calls.push(text);
    return { '日本語の映画': '中文电影', '日本語の説明': '中文简介', '女優': '女优' }[text];
  } };
  const result = await translateMovieNfoXml(xml, parsed, translator, { number: 'SSIS-586' });
  assert.deepEqual(calls, ['日本語の映画', '日本語の説明', '女優']);
  assert.deepEqual(result.changedFields, ['title', 'plot', 'genres']);
  assert.match(result.xml, /<title>SSIS-586 中文电影<\/title><originaltitle>SSIS-586 日本語の映画<\/originaltitle>/);
  assert.match(result.xml, /<plot>中文简介<\/plot><genre>女优<\/genre><genre>中文字幕<\/genre><tag>FANZA<\/tag>/);
});

test('already Chinese fields are skipped without contacting translation service', async () => {
  const xml = '<movie><title>SSIS-586 中文电影</title><plot>这是一段中文简介。</plot><genre>剧</genre></movie>';
  const parsed = { title: 'SSIS-586 中文电影', plot: '这是一段中文简介。', genres: ['剧'] };
  const result = await translateMovieNfoXml(xml, parsed, { translateTextStrict: () => { throw new Error('unexpected request'); } }, { number: 'SSIS-586' });
  assert.equal(result.skipped, true);
  assert.equal(result.xml, xml);
  assert.equal(isChineseText('日本語の映画'), false);
  assert.equal(isChineseText('SSIS-586 中文电影'), true);
});

test('translates only remaining foreign-language fields and escapes XML', async () => {
  const xml = '<movie><title>SSIS-586 中文电影</title><plot>English plot</plot><genre>Drama</genre></movie>';
  const parsed = { title: 'SSIS-586 中文电影', plot: 'English plot', genres: ['Drama'] };
  const translator = { translateTextStrict: async text => ({ 'English plot': '剧情 & 介绍', Drama: '剧情' })[text] };
  const result = await translateMovieNfoXml(xml, parsed, translator, { number: 'SSIS-586' });
  assert.deepEqual(result.changedFields, ['plot', 'genres']);
  assert.match(result.xml, /<plot>剧情 &amp; 介绍<\/plot><genre>剧情<\/genre>/);
});

test('translation failure rejects instead of returning a partial NFO', async () => {
  const parsed = { title: '日本語の映画', plot: '', genres: [] };
  await assert.rejects(() => translateMovieNfoXml('<movie><title>日本語の映画</title></movie>', parsed, {
    translateTextStrict: async () => { throw new Error('HTTP 429'); },
  }), /HTTP 429/);
});

test('unchanged foreign text is not misreported as already Chinese', async () => {
  const parsed = { title: '日本語の映画', plot: '', genres: [] };
  await assert.rejects(() => translateMovieNfoXml('<movie><title>日本語の映画</title></movie>', parsed, {
    translateTextStrict: async text => text,
  }), /unchanged non-Chinese/);
});

test('strict translator retries HTTP 429 and returns translated text', async () => {
  const originalFetch = global.fetch;
  const client = new MetadataTranslateClient();
  client.minRequestIntervalMs = 0;
  let requests = 0;
  global.fetch = async () => {
    requests += 1;
    return requests === 1
      ? { ok: false, status: 429 }
      : { ok: true, json: async () => [[['测试', 'テスト']]] };
  };
  try {
    assert.equal(await client.translateTextStrict('テスト'), '测试');
    assert.equal(requests, 2);
  } finally {
    global.fetch = originalFetch;
  }
});
