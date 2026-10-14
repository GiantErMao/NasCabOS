const path = require('node:path');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');

function normalizeSourcePath(raw) {
  let value = String(raw ?? '').trim();
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1).trim();
  return value;
}
function normalizeVideoConfig(raw) {
  const value = typeof raw === 'string' ? JSON.parse(raw) : raw;
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_video_config');
  const cfg = { ...value };
  if (cfg.replace_source !== undefined && typeof cfg.replace_source !== 'boolean') throw new Error('invalid_replace_source');
  cfg.replace_source = cfg.replace_source === true;
  for (const key of ['trim_start_seconds', 'trim_end_seconds']) {
    const v = cfg[key] ?? 0;
    if (typeof v !== 'number' || !Number.isFinite(v) || v < 0) throw new Error('invalid_trim_time');
    cfg[key] = v;
  }
  if (cfg.trim_end_seconds !== 0 && cfg.trim_end_seconds <= cfg.trim_start_seconds) throw new Error('trim_end_must_exceed_start');
  cfg.out_format = cfg.replace_source ? 'source' : cfg.out_format || 'mp4';
  if (!['source', 'mp4', 'mov', 'avi', 'gif', 'webp'].includes(cfg.out_format)) throw new Error('unsupported_output_format');
  if (isTrimming(cfg) && ['gif', 'webp'].includes(cfg.out_format)) throw new Error('trim_animated_not_supported');
  return cfg;
}
function isTrimming(cfg) {
  return cfg.trim_start_seconds > 0 || cfg.trim_end_seconds > 0;
}
function trimRange(cfg, duration) {
  if (!isTrimming(cfg)) return { start: 0, duration };
  if (!Number.isFinite(duration) || duration <= 0) return { skip: 'trim_duration_unavailable' };
  const start = cfg.trim_start_seconds;
  const end = cfg.trim_end_seconds || duration;
  if (start > duration || end > duration) return { skip: 'trim_time_exceeds_duration' };
  if (end <= start) return { skip: 'trim_empty_range' };
  return { start, duration: end - start };
}
const containers = {
  '.mp4': ['mp4', 'mov'],
  '.m4v': ['mp4', 'mov'],
  '.mov': ['mov', 'mov'],
  '.avi': ['avi', 'avi'],
  '.mkv': ['matroska', 'matroska'],
  '.webm': ['webm', 'webm'],
  '.ts': ['mpegts', 'mpegts'],
  '.mts': ['mpegts', 'mpegts'],
  '.m2ts': ['mpegts', 'mpegts'],
  '.flv': ['flv', 'flv'],
  '.3gp': ['3gp', 'mov'],
  '.gif': ['gif', 'gif'],
  '.webp': ['webp', 'webp_pipe'],
};
function outputSpec(inputPath, cfg, metadata) {
  const ext = cfg.out_format === 'source' ? path.extname(inputPath) : `.${cfg.out_format}`;
  const entry = containers[ext.toLowerCase()];
  if (!entry) throw new Error(`unsupported_source_container: ${ext}`);
  if (
    cfg.out_format === 'source' &&
    metadata &&
    !String(metadata.format?.format_name || '')
      .split(',')
      .includes(entry[1])
  )
    throw new Error('source_container_extension_mismatch');
  const muxer = entry[0];
  if ((isTrimming(cfg) || cfg.replace_source) && ['gif', 'webp'].includes(muxer)) throw new Error('trim_animated_not_supported');
  if (['webm', '3gp'].includes(muxer) || (muxer === 'flv' && cfg.vcodec === 'h265')) throw new Error(`source_codec_incompatible: ${muxer}; choose another output format/codec`);
  return { ext, muxer, probeFormat: entry[1] };
}
function fingerprint(stat) {
  return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}`;
}
function internalFile(name) {
  return name.endsWith('.cab.tmp') || name.includes('.nascab-video-');
}

// One cross-process lock and durable transaction record per canonical source path.
async function acquireSource(inputPath, taskId, stateDir) {
  const source = await fs.realpath(inputPath).catch(async e => {
    if (e.code !== 'ENOENT') throw e;
    return path.join(await fs.realpath(path.dirname(inputPath)), path.basename(inputPath));
  });
  if (
    (
      await fs.lstat(inputPath).catch(e => {
        if (e.code === 'ENOENT') return null;
        throw e;
      })
    )?.isSymbolicLink()
  )
    throw new Error('replacement_symlink_not_supported');
  await fs.mkdir(stateDir, { recursive: true });
  const key = crypto
    .createHash('sha256')
    .update(process.platform === 'win32' ? source.toLowerCase() : source)
    .digest('hex');
  const lockPath = path.join(stateDir, `${key}.lock`);
  const journalPath = path.join(stateDir, `${key}.json`);
  const token = crypto.randomUUID();
  async function ownsLock() {
    const owner = JSON.parse(await fs.readFile(lockPath, 'utf8'));
    if (owner.token !== token) throw new Error('source_lock_lost');
  }
  const recoveryGate = `${lockPath}.recovery`;
  async function lock(recovering = false) {
    if (
      !recovering &&
      (await fs
        .stat(recoveryGate)
        .then(() => true)
        .catch(e => {
          if (e.code === 'ENOENT') return false;
          throw e;
        }))
    )
      throw new Error('source_lock_recovery_busy');
    const handle = await fs.open(lockPath, 'wx');
    try {
      await handle.writeFile(JSON.stringify({ pid: process.pid, token }));
      await handle.sync();
    } finally {
      await handle.close();
    }
    if (
      !recovering &&
      (await fs
        .stat(recoveryGate)
        .then(() => true)
        .catch(e => {
          if (e.code === 'ENOENT') return false;
          throw e;
        }))
    ) {
      await ownsLock();
      await fs.unlink(lockPath);
      throw new Error('source_lock_recovery_busy');
    }
  }
  try {
    await lock();
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
    // Serialize stale-owner recovery. Live lock holders are never reclaimed.
    const gate = await fs.open(recoveryGate, 'wx').catch(() => {
      throw new Error('source_lock_recovery_busy');
    });
    try {
      let owner;
      try {
        owner = JSON.parse(await fs.readFile(lockPath, 'utf8'));
      } catch (_) {
        throw new Error('replacement_lock_unreadable');
      }
      if (!Number.isInteger(owner.pid) || owner.pid <= 0) throw new Error('replacement_lock_unreadable');
      try {
        process.kill(owner.pid, 0);
        throw new Error('source_locked_by_another_task');
      } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
      await fs.unlink(lockPath);
      await lock(true);
    } finally {
      await gate.close();
      await fs.unlink(recoveryGate);
    }
  }
  let released = false;
  const release = async () => {
    if (!released) {
      released = true;
      await ownsLock();
      await fs.unlink(lockPath);
    }
  };
  try {
    let journal = await fs
      .readFile(journalPath, 'utf8')
      .then(JSON.parse)
      .catch(e => {
        if (e.code === 'ENOENT') return null;
        throw e;
      });
    if (journal && journal.phase === 'prepared') {
      const backupExists = await fs
        .stat(journal.backup)
        .then(() => true)
        .catch(e => {
          if (e.code === 'ENOENT') return false;
          throw e;
        });
      if (backupExists) {
        const current = await fs.stat(source).catch(e => {
          if (e.code === 'ENOENT') return null;
          throw e;
        });
        if (current && fingerprint(current) !== journal.outputFingerprint) throw new Error('replacement_recovery_conflict_backup_retained');
        if (!current) await fs.rename(journal.backup, source);
        else {
          journal.phase = 'committed';
          journal.fingerprint = fingerprint(current);
          await writeJournal(journalPath, journal);
          await fs.unlink(journal.backup);
        }
      }
      if (journal.phase !== 'committed') {
        if (journal.tmp && path.dirname(journal.tmp) === path.dirname(source) && journal.tmp.endsWith('.cab.tmp')) {
          const temporary = await fs.stat(journal.tmp).catch(e => {
            if (e.code === 'ENOENT') return null;
            throw e;
          });
          if (temporary && fingerprint(temporary) === journal.outputFingerprint) await fs.unlink(journal.tmp);
        }
        await fs.unlink(journalPath);
        journal = null;
      }
    }
    if (journal?.phase === 'committed')
      await fs.unlink(journal.backup).catch(e => {
        if (e.code !== 'ENOENT') throw e;
      });
    const stat = await fs.stat(source);
    const original = fingerprint(stat);
    const alreadyCommitted = journal?.phase === 'committed' && journal.taskId === taskId && journal.fingerprint === original;
    return {
      source,
      stat,
      alreadyCommitted,
      release,
      async commit(tmp, stopped) {
        await ownsLock();
        if (stopped()) throw new Error('replacement_stopped');
        if (fingerprint(await fs.stat(source)) !== original) throw new Error('source_changed_before_replacement');
        await fs.chmod(tmp, stat.mode);
        const handle = await fs.open(tmp, 'r');
        try {
          await handle.sync();
        } finally {
          await handle.close();
        }
        const backup = `${source}.nascab-video-${crypto.createHash('sha256').update(String(taskId)).digest('hex').slice(0, 16)}-${process.pid}.backup`;
        const record = { phase: 'prepared', source, backup, tmp, taskId, outputFingerprint: fingerprint(await fs.stat(tmp)) };
        await writeJournal(journalPath, record);
        if (stopped()) {
          await fs.unlink(journalPath);
          throw new Error('replacement_stopped');
        }
        await ownsLock();
        if (fingerprint(await fs.stat(source)) !== original) throw new Error('source_changed_before_replacement');
        await fs.rename(source, backup);
        try {
          await syncDirectory(path.dirname(source));
          await fs.rename(tmp, source);
        } catch (e) {
          await fs.rename(backup, source);
          await fs.unlink(journalPath);
          throw e;
        }
        await syncDirectory(path.dirname(source));
        record.phase = 'committed';
        record.fingerprint = fingerprint(await fs.stat(source));
        await writeJournal(journalPath, record);
        await fs.unlink(backup);
      },
    };
  } catch (e) {
    await release();
    throw e;
  }
}
async function syncDirectory(dir) {
  // Windows does not expose directory fsync through Node. Rename remains same-volume.
  if (process.platform === 'win32') return;
  const handle = await fs.open(dir, 'r');
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}
async function writeJournal(file, value) {
  const tmp = `${file}.${process.pid}.cab.tmp`;
  const handle = await fs.open(tmp, 'w');
  try {
    await handle.writeFile(JSON.stringify(value));
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fs.rename(tmp, file);
  await syncDirectory(path.dirname(file));
}
async function recoverSourceTransactions(root, stateDir) {
  const canonicalRoot = await fs.realpath(root).catch(async e => {
    if (e.code !== 'ENOENT') throw e;
    return path.join(await fs.realpath(path.dirname(root)), path.basename(root));
  });
  const entries = await fs.readdir(stateDir).catch(e => {
    if (e.code === 'ENOENT') return [];
    throw e;
  });
  for (const name of entries.filter(v => v.endsWith('.json'))) {
    const record = JSON.parse(await fs.readFile(path.join(stateDir, name), 'utf8'));
    const relative = path.relative(canonicalRoot, record.source);
    if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) continue;
    if (record.phase !== 'prepared') continue;
    const guard = await acquireSource(record.source, record.taskId, stateDir);
    await guard.release();
  }
}
module.exports = { normalizeSourcePath, normalizeVideoConfig, isTrimming, trimRange, outputSpec, fingerprint, internalFile, acquireSource, recoverSourceTransactions };
