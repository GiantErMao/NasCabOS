'use strict';

const http = require('http');
const https = require('https');
const { URL } = require('url');

function _readAll(res) {
  return new Promise(resolve => {
    const chunks = [];
    res.on('data', d => chunks.push(d));
    res.on('end', () => resolve(Buffer.concat(chunks)));
    res.on('error', () => resolve(Buffer.concat(chunks)));
  });
}

function _sleep(ms) {
  const n = Math.max(0, Number(ms || 0) || 0);
  if (!n) return Promise.resolve();
  return new Promise(resolve => setTimeout(resolve, n));
}

function normalizeTranslateTargetLanguage(value) {
  const raw = String(value || '').trim();
  if (!raw) return 'zh-CN';
  const lower = raw.toLowerCase().replace('_', '-');
  if (lower === 'zh' || lower === 'zh-cn' || lower === 'zh-hans') return 'zh-CN';
  if (lower === 'zh-tw' || lower === 'zh-hant') return 'zh-TW';
  if (/^[a-z]{2}(-[A-Za-z]{2,4})?$/.test(raw)) return raw;
  return 'zh-CN';
}

function normalizeTranslateApiUrl(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  try {
    const withScheme = raw.includes('://') ? raw : `http://${raw}`;
    const u = new URL(withScheme);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    u.search = '';
    u.hash = '';
    return u.toString().replace(/\/$/, '');
  } catch (_) {
    return '';
  }
}

function _extractGoogleTranslateText(json) {
  if (!Array.isArray(json) || !Array.isArray(json[0])) return '';
  const parts = [];
  for (const item of json[0]) {
    if (Array.isArray(item) && item[0]) parts.push(String(item[0]));
  }
  return parts.join('').trim();
}

function _toLibreTranslateTargetLanguage(value) {
  const lang = normalizeTranslateTargetLanguage(value);
  if (lang === 'zh-CN' || lang === 'zh-TW') return 'zh';
  return lang.split('-')[0] || lang;
}

class MetadataTranslateClient {
  constructor({ targetLanguage = 'zh-CN', apiUrl = '', apiKey = '' } = {}) {
    this.targetLanguage = normalizeTranslateTargetLanguage(targetLanguage);
    this.apiUrl = String(apiUrl || '').trim();
    this.apiKey = String(apiKey || '').trim();
    this.minRequestIntervalMs = 120;
    this._lastRequestAtMs = 0;
    this._rateLimitQueue = Promise.resolve();
    this._cache = new Map();
  }

  async withRateLimit(fn) {
    const task = typeof fn === 'function' ? fn : null;
    if (!task) throw new Error('rate limit task missing');

    const run = async () => {
      const last = Number(this._lastRequestAtMs || 0) || 0;
      const now = Date.now();
      const waitMs = Math.max(0, last + (Number(this.minRequestIntervalMs) || 0) - now);
      if (waitMs) await _sleep(waitMs);
      this._lastRequestAtMs = Date.now();
      return await task();
    };

    const p = this._rateLimitQueue.then(run);
    this._rateLimitQueue = p.catch(() => {});
    return await p;
  }

  buildGoogleUrl(text) {
    const u = new URL('https://translate.googleapis.com/translate_a/single');
    u.searchParams.set('client', 'gtx');
    u.searchParams.set('sl', 'auto');
    u.searchParams.set('tl', this.targetLanguage);
    u.searchParams.set('dt', 't');
    u.searchParams.set('q', String(text || ''));
    return u;
  }

  buildLibreTranslateUrl() {
    const raw = normalizeTranslateApiUrl(this.apiUrl);
    if (!raw) return null;
    const u = new URL(raw);
    if (!/\/translate\/?$/i.test(u.pathname)) {
      u.pathname = `${u.pathname.replace(/\/+$/, '')}/translate`;
    }
    u.search = '';
    u.hash = '';
    return u;
  }

  async translateByLibreTranslate(raw) {
    const url = this.buildLibreTranslateUrl();
    if (!url) return '';
    const body = JSON.stringify({
      q: raw,
      source: 'auto',
      target: _toLibreTranslateTargetLanguage(this.targetLanguage),
      format: 'text',
      api_key: this.apiKey || undefined,
    });
    const transport = url.protocol === 'https:' ? https : http;
    return await new Promise(resolve => {
      const req = transport.request(
        url,
        {
          method: 'POST',
          headers: {
            Accept: 'application/json',
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(body),
            'User-Agent': 'NasCabOS/1.0',
          },
          timeout: 15000,
        },
        async res => {
          const buf = await _readAll(res);
          const text = buf.toString('utf8');
          if (res.statusCode && res.statusCode >= 400) return resolve('');
          try {
            const json = JSON.parse(text || '{}');
            const translated = json && (json.translatedText || json.translated_text);
            return resolve(translated ? String(translated).trim() : '');
          } catch (_) {
            return resolve('');
          }
        }
      );
      req.on('timeout', () => {
        try { req.destroy(); } catch (_) {}
        resolve('');
      });
      req.on('error', () => resolve(''));
      req.write(body);
      req.end();
    });
  }

  async translateByGoogle(raw) {
    const url = this.buildGoogleUrl(raw);
    const transport = url.protocol === 'https:' ? https : http;
    return await new Promise(resolve => {
      const req = transport.request(
        url,
        {
          method: 'GET',
          headers: {
            Accept: 'application/json',
            'User-Agent': 'NasCabOS/1.0',
          },
          timeout: 15000,
        },
        async res => {
          const buf = await _readAll(res);
          const body = buf.toString('utf8');
          if (res.statusCode && res.statusCode >= 400) return resolve('');
          try {
            const textOut = _extractGoogleTranslateText(JSON.parse(body || '[]'));
            return resolve(textOut || '');
          } catch (_) {
            return resolve('');
          }
        }
      );
      req.on('timeout', () => {
        try { req.destroy(); } catch (_) {}
        resolve('');
      });
      req.on('error', () => resolve(''));
      req.end();
    });
  }

  async translateText(text) {
    const raw = String(text || '').trim();
    if (!raw) return '';
    const key = `${this.targetLanguage}\n${raw}`;
    if (this._cache.has(key)) return this._cache.get(key);

    const translated = await this.withRateLimit(async () => {
      const custom = await this.translateByLibreTranslate(raw);
      if (custom) return custom;
      return (await this.translateByGoogle(raw)) || raw;
    });

    const out = String(translated || '').trim() || raw;
    this._cache.set(key, out);
    return out;
  }

  // Manual NFO translation must fail visibly rather than saving the source text
  // as if a rate-limited or unavailable translation had succeeded.
  async translateTextStrict(text) {
    const raw = String(text || '').trim();
    if (!raw) return '';
    const key = `${this.targetLanguage}\n${raw}`;
    if (this._cache.has(key)) return this._cache.get(key);
    const translated = await this.withRateLimit(async () => {
      const custom = await this.translateByLibreTranslate(raw);
      if (custom) return custom;
      if (typeof fetch !== 'function') throw new Error('Translation service unavailable');
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
          const response = await fetch(this.buildGoogleUrl(raw), {
            headers: { Accept: 'application/json' },
            signal: controller.signal,
          });
          if (response.ok) {
            const result = _extractGoogleTranslateText(await response.json());
            if (!result) throw new Error('Translation service returned no text');
            return result;
          }
          if (response.status !== 429 && response.status < 500) {
            throw new Error(`Translation service returned HTTP ${response.status}`);
          }
          if (attempt === 1) throw new Error(`Translation service returned HTTP ${response.status}`);
        } finally {
          clearTimeout(timer);
        }
        await _sleep(1000 * (attempt + 1));
      }
      throw new Error('Translation service unavailable');
    });
    this._cache.set(key, translated);
    return translated;
  }

  async translateList(list) {
    const arr = Array.isArray(list) ? list : [];
    const out = [];
    for (const item of arr) {
      const raw = String(item || '').trim();
      if (!raw) continue;
      const translated = await this.translateText(raw).catch(() => raw);
      out.push(String(translated || raw).trim());
    }
    return out;
  }
}

module.exports = {
  MetadataTranslateClient,
  normalizeTranslateTargetLanguage,
  normalizeTranslateApiUrl,
};
