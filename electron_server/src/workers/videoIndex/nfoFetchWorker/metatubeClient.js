'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const DEFAULT_METATUBE_BASE_URL = '';

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

function normalizeMetaTubeBaseUrl(baseUrl) {
  const raw = String(baseUrl || '').trim();
  if (!raw) return '';
  const withScheme = raw.includes('://') ? raw : `http://${raw}`;
  try {
    const u = new URL(withScheme);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    u.pathname = u.pathname.replace(/\/+$/, '');
    u.search = '';
    u.hash = '';
    return u.toString().replace(/\/+$/, '');
  } catch (_) {
    return '';
  }
}

function parseMetaTubeScrapeId(value) {
  const raw = String(value || '').trim();
  if (!raw) return { provider: '', id: '' };
  const idx = raw.indexOf(':');
  if (idx > 0) {
    return {
      provider: raw.slice(0, idx).trim(),
      id: raw.slice(idx + 1).trim(),
    };
  }
  return { provider: '', id: raw };
}

function buildMetaTubeScrapeId(provider, id) {
  const p = String(provider || '').trim();
  const i = String(id || '').trim();
  if (!p || !i) return '';
  return `${p}:${i}`;
}

class MetaTubeClient {
  constructor({ baseUrl, token }) {
    this.baseUrl = normalizeMetaTubeBaseUrl(baseUrl);
    this.token = String(token || '').trim();
    this.minRequestIntervalMs = 0;
    this._lastRequestAtMs = 0;
    this._rateLimitQueue = Promise.resolve();
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

  buildApiUrl(pathname, query = null) {
    if (!this.baseUrl) throw new Error('MetaTube base URL missing');
    const u = new URL(this.baseUrl);
    const basePath = u.pathname && u.pathname !== '/' ? u.pathname.replace(/\/+$/, '') : '';
    const p = String(pathname || '');
    u.pathname = `${basePath}${p.startsWith('/') ? p : `/${p}`}`;
    u.search = '';
    if (query && typeof query === 'object') {
      for (const [k, v] of Object.entries(query)) {
        if (v === undefined || v === null) continue;
        const s = String(v).trim();
        if (!s) continue;
        u.searchParams.set(k, s);
      }
    }
    return u;
  }

  async requestJson(pathname, query = null) {
    return await this.withRateLimit(async () => {
      const url = this.buildApiUrl(pathname, query);
      const transport = url.protocol === 'https:' ? https : http;
      const headers = { Accept: 'application/json' };
      if (this.token) headers.Authorization = `Bearer ${this.token}`;
      const body = await new Promise((resolve, reject) => {
        const req = transport.request(url, { method: 'GET', headers }, async res => {
          const buf = await _readAll(res);
          const text = buf.toString('utf8');
          if (res.statusCode && res.statusCode >= 400) {
            const err = new Error(`MetaTube ${res.statusCode} ${url.pathname}`);
            err.statusCode = res.statusCode;
            err.body = text;
            return reject(err);
          }
          try {
            const json = JSON.parse(text || '{}');
            return resolve(json && Object.prototype.hasOwnProperty.call(json, 'data') ? json.data : json);
          } catch (e) {
            const err = new Error(`MetaTube invalid JSON ${url.pathname}`);
            err.body = text;
            return reject(err);
          }
        });
        req.on('error', reject);
        req.end();
      });
      return body;
    });
  }

  buildImageUrl(filePath) {
    const fp = String(filePath || '').trim();
    if (!fp) return '';
    if (fp.startsWith('http://') || fp.startsWith('https://')) return fp;
    const base = this.baseUrl.replace(/\/+$/, '');
    return `${base}${fp.startsWith('/') ? fp : `/${fp}`}`;
  }

  async downloadToFile(imageUrl, targetPath, { onSuccess } = {}) {
    const urlStr = String(imageUrl || '').trim();
    const out = String(targetPath || '').trim();
    if (!urlStr || !out) return false;

    let url;
    try {
      url = new URL(urlStr);
    } catch (_) {
      return false;
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;

    await fs.promises.mkdir(require('path').dirname(out), { recursive: true });
    const tmp = `${out}.${Date.now()}.tmp`;
    const transport = url.protocol === 'https:' ? https : http;

    return await this.withRateLimit(async () => {
      return await new Promise(resolve => {
        const file = fs.createWriteStream(tmp);
        const req = transport.get(url, { headers: { Accept: '*/*' } }, res => {
          if (res.statusCode && res.statusCode >= 400) {
            file.close(() => {
              try { fs.unlinkSync(tmp); } catch (_) {}
              resolve(false);
            });
            return;
          }
          res.pipe(file);
          file.on('finish', () => {
            file.close(() => {
              try {
                fs.renameSync(tmp, out);
                if (typeof onSuccess === 'function') {
                  try { onSuccess(out); } catch (_) {}
                }
                resolve(true);
              } catch (_) {
                try { fs.unlinkSync(tmp); } catch (_) {}
                resolve(false);
              }
            });
          });
        });
        req.on('error', () => {
          try { file.close(() => {}); } catch (_) {}
          try { fs.unlinkSync(tmp); } catch (_) {}
          resolve(false);
        });
      });
    });
  }

  async getProviders() {
    const data = await this.requestJson('/v1/providers', null);
    return data && typeof data === 'object' ? data : {};
  }

  async searchMovie({ query, provider = '', fallback = true }) {
    const q = String(query || '').trim();
    if (!q) return [];
    const data = await this.requestJson('/v1/movies/search', {
      q,
      provider: String(provider || '').trim() || undefined,
      fallback: fallback ? 'true' : 'false',
    });
    return Array.isArray(data) ? data : [];
  }

  async getMovieDetails(provider, id) {
    const p = String(provider || '').trim();
    const movieId = String(id || '').trim();
    if (!p || !movieId) return null;
    const data = await this.requestJson(`/v1/movies/${encodeURIComponent(p)}/${encodeURIComponent(movieId)}`, null);
    return data && typeof data === 'object' ? data : null;
  }
}

module.exports = {
  MetaTubeClient,
  DEFAULT_METATUBE_BASE_URL,
  normalizeMetaTubeBaseUrl,
  parseMetaTubeScrapeId,
  buildMetaTubeScrapeId,
};
