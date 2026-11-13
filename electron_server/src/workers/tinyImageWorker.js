'use strict';

const fs = require('fs');
const path = require('path');

const Logger = require('../utils/logger');
const config = require('../config/config');
const dbUtil = require('../db/dbUtil');
const knexUtil = require('../db/knexUtil');
const fileService = require('../api/modules/file/core/fileService');
const { withHardTimeout, pathAccessible } = require('../utils/asyncTimeoutUtil');

const TINY_PATH_CHECK_MS = 8000;
const TINY_IMAGE_GEN_MS = 90 * 1000;
const TINY_VIDEO_GEN_MS = 3 * 60 * 1000;
// Keep thumbnail extraction bounded so one slow video does not block a whole
// folder, while avoiding an unbounded FFmpeg burst on NAS hardware.
const TINY_WORKER_CONCURRENCY = 2;
const TINY_JOB_SCAN_LIMIT = 100;
const TINY_STALE_PROCESSING_MS = 4 * 60 * 1000;

function tinyGenTimeoutMs(filePath) {
  const ext = path.extname(String(filePath || '')).toLowerCase();
  const videoTypes = Array.isArray(config.videoTypeList) ? config.videoTypeList : [];
  return videoTypes.includes(ext) ? TINY_VIDEO_GEN_MS : TINY_IMAGE_GEN_MS;
}

async function generateTinyWithTimeout(fullPath) {
  const ms = tinyGenTimeoutMs(fullPath);
  return withHardTimeout(
    fileService.getTinyImgByPath(fullPath, undefined, { deferLargeVideo: false, deferSlowIo: false }),
    ms,
    'file.TINY_TIMEOUT'
  );
}

class TinyImageWorker {
  constructor() {
    this.isRunning = false;
    this.init();
  }

  async init() {
    try {
      await knexUtil.init(dbUtil.DB_PATHS.PHOTO_DB);
      await knexUtil.init(dbUtil.DB_PATHS.VIDEO_DB);

      this.photoKnex = knexUtil.getInstance(dbUtil.DB_PATHS.PHOTO_DB);
      this.videoKnex = knexUtil.getInstance(dbUtil.DB_PATHS.VIDEO_DB);
      this.isRunning = true;
      this.activePaths = new Set();
      this.activeJobs = new Set();

      // 来源目录缓存，5 秒刷新一次，避免频繁查库
      this._sourceDirsCache = { dirs: new Set(), fetchedAt: 0 };
      await this._refreshSourceDirs();

      await this.startLoop();
    } catch (err) {
      Logger.error('❌ TinyImage Worker init failed:', err);
      process.exit(1);
    }
  }

  async _refreshSourceDirs() {
    try {
      const photoRows = await this.photoKnex('photo_source')
        .select('path')
        .catch(() => []);
      const videoRows = await this.videoKnex('video_source')
        .select('path')
        .catch(() => []);

      const dirs = new Set();
      for (const row of photoRows || []) {
        const p = row && row.path ? path.resolve(String(row.path)) : '';
        if (p) dirs.add(p);
      }
      for (const row of videoRows || []) {
        const p = row && row.path ? path.resolve(String(row.path)) : '';
        if (p) dirs.add(p);
      }

      this._sourceDirsCache = { dirs, fetchedAt: Date.now() };
    } catch (err) {
      Logger.warn('⚠️ refresh source dirs failed:', err);
    }
  }

  async _ensureSourceDirsFresh() {
    if (Date.now() - this._sourceDirsCache.fetchedAt > 3000) {
      await this._refreshSourceDirs();
    }
  }

  /**
   * 检查文件所在父目录是否属于任一配置的来源目录
   */
  _isUnderSourceDir(fullPath) {
    if (!fullPath) return false;
    const targetDir = path.resolve(path.dirname(fullPath));
    for (const srcDir of this._sourceDirsCache.dirs) {
      if (targetDir === srcDir) return true;
      if (targetDir.startsWith(srcDir + path.sep)) return true;
    }
    return false;
  }

  async startLoop() {
    console.log('TinyImage Worker startLoop');
    let processedCount = 0;
    let updatedCount = 0;
    let failedCount = 0;

    while (this.isRunning) {
      try {
        while (this.activeJobs.size < TINY_WORKER_CONCURRENCY) {
          // Priority: explicit requests, then photo index, then video index.
          const job = await this.getNextJob();
          if (!job) break;
          const key = this.getJobPath(job);
          if (!key || this.activePaths.has(key)) continue;

          // Claim synchronously before starting asynchronous work so parallel
          // slots cannot pick the same path from different queues.
          this.activePaths.add(key);
          let task;
          task = this.processJob(job)
            .then(ok => {
              processedCount++;
              if (ok) updatedCount++; else failedCount++;
            })
            .catch(err => {
              failedCount++;
              Logger.error('❌ TinyImage Worker job failed:', err);
            })
            .finally(() => {
              this.activePaths.delete(key);
              this.activeJobs.delete(task);
            });
          this.activeJobs.add(task);
        }

        if (this.activeJobs.size === 0) break;
        // Wake as soon as one slot is free, without polling while jobs run.
        await Promise.race(this.activeJobs);
      } catch (err) {
        Logger.error('❌ TinyImage Worker loop error:', err);
        await new Promise(r => setTimeout(r, 1000));
      }
    }

    if (this.activeJobs.size > 0) await Promise.allSettled(this.activeJobs);
    Logger.info(`✅ TinyImage Worker stopped: processed=${processedCount}, updated=${updatedCount}, failed=${failedCount}`);
    process.exit(0);
  }

  getJobPath(job) {
    if (!job) return '';
    if (job.kind === 'wait') return path.resolve(String(job.row.source_path || ''));
    return path.resolve(String(job.row.path || ''), String(job.row.filename || ''));
  }

  async getNextJob() {
    const waitRow = await this.getOneWait();
    if (waitRow) return { kind: 'wait', row: waitRow };
    const photoRow = await this.getOnePhoto();
    if (photoRow) return { kind: 'photo', row: photoRow };
    const videoRow = await this.getOneVideo();
    if (videoRow) return { kind: 'video', row: videoRow };
    return null;
  }

  async processJob(job) {
    if (job.kind === 'wait') return this.processOneWait(job.row);
    if (job.kind === 'photo') return this.processOnePhoto(job.row);
    return this.processOneVideo(job.row);
  }

  async getOnePhoto() {
    const rows = await this.photoKnex('photo_index')
      .select('id', 'path', 'filename', 'type')
      .where({ is_file: 1, in_trash: 0 })
      .andWhere(qb => {
        qb.where('gen_tiny', 0).orWhereNull('gen_tiny');
      })
      .whereIn('type', [1, 2])
      .orderBy('id', 'asc')
      .limit(TINY_JOB_SCAN_LIMIT)
      .catch(() => []);
    return rows.find(row => !this.activePaths.has(path.resolve(String(row.path || ''), String(row.filename || '')))) || null;
  }

  async getOneVideo() {
    const rows = await this.videoKnex('video_index')
      .select('id', 'path', 'filename', 'ext')
      .where({ is_file: 1 })
      .whereIn('ext', Array.isArray(config.videoTypeList) ? config.videoTypeList : [])
      .andWhere(qb => {
        qb.where('gen_tiny', 0).orWhereNull('gen_tiny');
      })
      .orderBy('id', 'asc')
      .limit(TINY_JOB_SCAN_LIMIT)
      .catch(() => []);
    return rows.find(row => !this.activePaths.has(path.resolve(String(row.path || ''), String(row.filename || '')))) || null;
  }

  async getOneWait() {
    const staleBefore = Date.now() - TINY_STALE_PROCESSING_MS;
    const rows = await this.photoKnex('wait_gen_tiny')
      .select('id', 'source_path')
      .where(builder => {
        builder.where('status', 'pending').orWhere(inner => {
          inner.where('status', 'processing').andWhere('updated_at', '<', staleBefore);
        });
      })
      .orderBy('id', 'desc')
      .limit(TINY_JOB_SCAN_LIMIT)
      .catch(() => []);
    return rows.find(row => !this.activePaths.has(path.resolve(String(row.source_path || '')))) || null;
  }

  async processOnePhoto(row) {
    const id = row && row.id ? Number(row.id) : 0;
    if (!id) return false;

    const fullPath = path.join(String(row.path || ''), String(row.filename || ''));

    // 来源目录不存在则跳过
    await this._ensureSourceDirsFresh();
    if (!this._isUnderSourceDir(fullPath)) {
      await this.photoKnex('photo_index').where({ id }).update({ gen_tiny: 1 });
      return false;
    }

    if (!fullPath || !(await pathAccessible(fullPath, TINY_PATH_CHECK_MS))) {
      await this.photoKnex('photo_index').where({ id }).update({ gen_tiny: 1 });
      return false;
    }

    try {
      const tinyPath = await generateTinyWithTimeout(fullPath);
      if (!tinyPath) return false;
      await this.photoKnex('photo_index').where({ id }).update({ gen_tiny: 1 });
      return true;
    } catch (err) {
      const msg = err && err.message ? String(err.message) : '';
      if (msg === 'file.TINY_TIMEOUT') {
        Logger.warn(`⏱ thumbnail gen timed out: ${fullPath}`);
      } else {
        Logger.error(`❌ thumbnail gen failed: ${fullPath}`, err);
      }
      await this.photoKnex('photo_index').where({ id }).update({ gen_tiny: 1 });
      return false;
    }
  }

  async processOneVideo(row) {
    const id = row && row.id ? Number(row.id) : 0;
    if (!id) return false;

    const fullPath = path.join(String(row.path || ''), String(row.filename || ''));

    // 来源目录不存在则跳过
    await this._ensureSourceDirsFresh();
    if (!this._isUnderSourceDir(fullPath)) {
      await this.videoKnex('video_index').where({ id }).update({ gen_tiny: 1 });
      return false;
    }

    if (!fullPath || !(await pathAccessible(fullPath, TINY_PATH_CHECK_MS))) {
      await this.videoKnex('video_index').where({ id }).update({ gen_tiny: 1 });
      return false;
    }

    try {
      const tinyPath = await generateTinyWithTimeout(fullPath);
      if (!tinyPath) return false;
      await this.videoKnex('video_index').where({ id }).update({ gen_tiny: 1 });
      return true;
    } catch (err) {
      const msg = err && err.message ? String(err.message) : '';
      if (msg === 'file.TINY_TIMEOUT') {
        Logger.warn(`⏱ video thumbnail gen timed out: ${fullPath}`);
      } else {
        Logger.error(`❌ video thumb gen failed: ${fullPath}`, err);
      }
      await this.videoKnex('video_index').where({ id }).update({ gen_tiny: 1 });
      return false;
    }
  }

  async processOneWait(row) {
    const id = row && row.id ? Number(row.id) : 0;
    if (!id) return false;

    const sourcePath = row && row.source_path ? String(row.source_path || '') : '';
    const fullPath = sourcePath ? path.resolve(sourcePath) : '';
    await this.photoKnex('wait_gen_tiny').where({ id }).update({
      status: 'processing',
      last_error: null,
      updated_at: Date.now(),
    });

    const markFailed = async message => this.photoKnex('wait_gen_tiny').where({ id }).update({
      status: 'failed',
      last_error: String(message || 'Thumbnail generation failed').slice(0, 1000),
      updated_at: Date.now(),
    });

    // Explicit /api/file/tiny requests are permission-checked by the route
    // before enqueueing. They may target ordinary file-browser folders that
    // are not configured as photo/video library sources.
    if (!fullPath || !(await pathAccessible(fullPath, TINY_PATH_CHECK_MS))) {
      await markFailed('Source file is unavailable');
      return false;
    }

    try {
      const tinyPath = await generateTinyWithTimeout(fullPath);
      await this.photoKnex('wait_gen_tiny').where({ id }).del();
      return !!tinyPath;
    } catch (err) {
      const msg = err && err.message ? String(err.message) : '';
      if (msg === 'file.TINY_TIMEOUT') {
        Logger.warn(`⏱ pending thumbnail gen timed out: ${fullPath}`);
      } else {
        Logger.error(`❌ pending thumbnail gen failed: ${fullPath}`, err);
      }
      await markFailed(msg || 'Thumbnail generation failed');
      return false;
    }
  }

  stop() {
    this.isRunning = false;
  }
}

const worker = new TinyImageWorker();

process.on('message', message => {
  if (!message || !message.type) return;
  if (message.type === 'stop') worker.stop();
});

process.on('uncaughtException', err => {
  Logger.error('❌ tinyImage worker uncaughtException', err);
  process.exit(0);
});

process.on('unhandledRejection', reason => {
  Logger.error('❌ tinyImage worker unhandledRejection', reason);
  process.exit(0);
});
