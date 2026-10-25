'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { parseNfoXml } = require('../src/workers/videoIndex/nfoParser');
const { buildNfoFieldsFromParsed } = require('../src/workers/videoIndex/videoIndexIndexUtil');

test('recognizes NasCabOS and Jellyfin MetaTube IDs', () => {
  for (const id of [
    '<uniqueid type="tmdb">JavBus:K0871</uniqueid>',
    '<uniqueid type="metatube">TOKYO-HOT:k0871</uniqueid>',
  ]) {
    assert.equal(parseNfoXml(`<movie><title>Title</title>${id}</movie>`).metadataSource, 'metatube');
  }
});

test('does not treat a regular TMDB movie or number tag as MetaTube', () => {
  for (const id of ['<uniqueid type="tmdb">12345</uniqueid>', '<tag>K0871</tag>', '']) {
    assert.equal(parseNfoXml(`<movie><title>Title</title>${id}</movie>`).metadataSource, '');
  }
});

test('keeps a letter-digit-hyphen movie number intact', () => {
  const parsed = parseNfoXml('<movie><title>T28-143</title><sorttitle>T28-143</sorttitle><tag>T28-143</tag></movie>');
  assert.equal(buildNfoFieldsFromParsed(parsed).nfo_number, 'T28-143');
});

test('keeps a letter-number suffix in the movie number', () => {
  const parsed = parseNfoXml('<movie><title>MKD-S41 KIRARI 41</title><sorttitle>MKD-S41</sorttitle><tag>MKD-S41</tag></movie>');
  assert.equal(buildNfoFieldsFromParsed(parsed).nfo_number, 'MKD-S41');
});

test('indexes suffix labels from video filename or movie directory', () => {
  const parsed = parseNfoXml('<movie><title>SHKD-748</title><tag>SHKD-748</tag></movie>');
  const fields = buildNfoFieldsFromParsed(parsed, { filename: 'SHKD-748.mp4', directoryName: 'SHKD-748-C' });
  assert.equal(fields.nfo_tags, 'SHKD-748,中文字幕');
  assert.equal(fields.nfo_genres, '中文字幕');
});
