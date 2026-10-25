'use strict';

const KANA = /[\u3040-\u30ff\u31f0-\u31ff]/u;
const NON_SIMPLIFIED_HAN = /[優単専発総圧売対黒裏學體無続検藝來親]/u;
const HAN = /[\p{Script=Han}]/gu;
const LATIN = /[a-z]/gi;

function isChineseText(value) {
  const text = String(value || '').trim();
  if (!text || KANA.test(text) || NON_SIMPLIFIED_HAN.test(text) || /[\uac00-\ud7af]/u.test(text)) return false;
  const han = (text.match(HAN) || []).length;
  const withoutCodes = text.replace(/\b[A-Z]{2,10}[-_ ]?\d{2,8}\b/gi, '');
  const latin = (withoutCodes.match(LATIN) || []).length;
  return han >= 1 && han * 2 >= latin;
}

function escapeXml(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

function replaceFirstTag(xml, tag, value) {
  const pattern = new RegExp(`(<${tag}\\b[^>]*>)[\\s\\S]*?(<\\/${tag}>)`, 'i');
  return xml.replace(pattern, (_, open, close) => `${open}${escapeXml(value)}${close}`);
}

async function translateMovieNfoXml(xml, parsed, translator, { number = '' } = {}) {
  let result = String(xml || '');
  const changedFields = [];
  let attempted = 0;
  const translate = async raw => {
    const text = String(raw || '').trim();
    if (!text || isChineseText(text) || /^[A-Z0-9][A-Z0-9 _.-]*$/.test(text)) return text;
    attempted += 1;
    return String(await translator.translateTextStrict(text) || '').trim() || text;
  };

  const title = String(parsed.title || '').trim();
  const originalTitle = String(parsed.originalTitle || '').trim();
  const prefix = String(number || '').trim() || (/^(?=.*\d)[A-Z0-9]+(?:[-_. ][A-Z0-9]+)*$/i.test(originalTitle) ? originalTitle : '');
  const hasPrefix = prefix && title.toLowerCase().startsWith(`${prefix.toLowerCase()} `);
  const titleBody = hasPrefix ? title.slice(prefix.length).trim() : title;
  if (titleBody && !isChineseText(titleBody)) {
    const translated = await translate(titleBody);
    if (translated !== titleBody) {
      result = replaceFirstTag(result, /<title\b/i.test(result) ? 'title' : 'name', hasPrefix ? `${prefix} ${translated}` : translated);
      changedFields.push('title');
      if (!originalTitle || (prefix && originalTitle.toLowerCase() === prefix.toLowerCase())) {
        if (/<originaltitle\b/i.test(result)) {
          result = replaceFirstTag(result, 'originaltitle', title);
        } else {
          result = result.replace(/(<title\b[^>]*>[\s\S]*?<\/title>)/i, match => `${match}<originaltitle>${escapeXml(title)}</originaltitle>`);
        }
      }
    }
  }

  const plot = String(parsed.plot || '').trim();
  if (plot && !isChineseText(plot)) {
    const translated = await translate(plot);
    if (translated !== plot) {
      const tag = /<plot\b/i.test(result) ? 'plot' : /<outline\b/i.test(result) ? 'outline' : 'biography';
      result = replaceFirstTag(result, tag, translated);
      changedFields.push('plot');
    }
  }

  const genres = Array.isArray(parsed.genres) ? parsed.genres : [];
  const genreTags = [...result.matchAll(/<genre\b[^>]*>[\s\S]*?<\/genre>/gi)];
  if (genres.length === genreTags.length) {
    const translatedGenres = [];
    for (const genre of genres) translatedGenres.push(await translate(genre));
    if (translatedGenres.some((value, index) => value !== genres[index])) {
      let index = 0;
      result = result.replace(/<genre\b[^>]*>[\s\S]*?<\/genre>/gi, tag =>
        tag.replace(/^(<genre\b[^>]*>)[\s\S]*?(<\/genre>)$/i, (_, open, close) => `${open}${escapeXml(translatedGenres[index++])}${close}`));
      changedFields.push('genres');
    }
  }

  if (attempted > 0 && changedFields.length === 0) throw new Error('Translation returned unchanged non-Chinese text');
  return { xml: result, changedFields, skipped: changedFields.length === 0 };
}

module.exports = { isChineseText, translateMovieNfoXml };
