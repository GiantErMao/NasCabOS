const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const core = require('../src/api/modules/mediaTool/videoTransCore');
const cfg = (extra = {}) => core.normalizeVideoConfig({ out_format: 'source', ...extra });

test('validates time, format, replacement and legacy defaults', () => {
  assert.equal(core.normalizeVideoConfig({}).out_format, 'mp4');
  assert.equal(cfg({ replace_source: true, out_format: 'gif' }).out_format, 'source');
  for (const value of [-1, NaN, Infinity, '10']) assert.throws(() => cfg({ trim_start_seconds: value }));
  assert.throws(() => cfg({ trim_start_seconds: 10, trim_end_seconds: 10 }));
  assert.throws(() => cfg({ trim_end_seconds: 2, out_format: 'gif' }));
  assert.throws(() => cfg({ replace_source: 'false' }));
  assert.equal(core.normalizeSourcePath(' " /中文/a b.mp4 " '), '/中文/a b.mp4');
});
test('trim intervals respect EOF, exact duration and per-file bounds', () => {
  assert.deepEqual(core.trimRange(cfg(), 40), { start: 0, duration: 40 });
  assert.deepEqual(core.trimRange(cfg({ trim_start_seconds: 10, trim_end_seconds: 30 }), 40), { start: 10, duration: 20 });
  assert.deepEqual(core.trimRange(cfg({ trim_start_seconds: 10.5 }), 40), { start: 10.5, duration: 29.5 });
  assert.deepEqual(core.trimRange(cfg({ trim_end_seconds: 40 }), 40), { start: 0, duration: 40 });
  assert.equal(core.trimRange(cfg({ trim_start_seconds: 41 }), 40).skip, 'trim_time_exceeds_duration');
  assert.equal(core.trimRange(cfg({ trim_start_seconds: 40 }), 40).skip, 'trim_empty_range');
  assert.equal(core.trimRange(cfg({ trim_start_seconds: 1 }), null).skip, 'trim_duration_unavailable');
});
test('source muxers preserve extension and reject mismatches/incompatible encoders', () => {
  assert.equal(core.outputSpec('a.MKV', cfg()).muxer, 'matroska');
  assert.equal(core.outputSpec('a.ts', cfg()).muxer, 'mpegts');
  assert.throws(() => core.outputSpec('a.rm', cfg()));
  assert.throws(() => core.outputSpec('a.webm', cfg()));
  assert.throws(() => core.outputSpec('a.mp4', cfg(), { format: { format_name: 'matroska,webm' } }));
  assert.equal(core.internalFile('a.mp4.nascab-video-1.backup'), true);
});
async function fixture(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'nascab-video-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const source = path.join(dir, '中文 video.mp4');
  await fs.writeFile(source, 'original');
  return { dir, source, state: path.join(dir, 'state'), tmp: path.join(dir, 'out.cab.tmp') };
}
test('replacement locks, preserves original on stop/change, commits and deduplicates interrupted run', async t => {
  const f = await fixture(t);
  const guard = await core.acquireSource(f.source, 'run1', f.state);
  await assert.rejects(core.acquireSource(f.source, 'run2', f.state), /locked/);
  await fs.writeFile(f.tmp, 'validated output');
  await assert.rejects(
    guard.commit(f.tmp, () => true),
    /stopped/
  );
  assert.equal(await fs.readFile(f.source, 'utf8'), 'original');
  await guard.commit(f.tmp, () => false);
  await guard.release();
  assert.equal(await fs.readFile(f.source, 'utf8'), 'validated output');
  const resumed = await core.acquireSource(f.source, 'run1', f.state);
  assert.equal(resumed.alreadyCommitted, true);
  await resumed.release();
  const fresh = await core.acquireSource(f.source, 'run2', f.state);
  assert.equal(fresh.alreadyCommitted, false);
  await fs.writeFile(f.source, 'external edit');
  await fs.writeFile(f.tmp, 'second output');
  await assert.rejects(
    fresh.commit(f.tmp, () => false),
    /source_changed/
  );
  await fresh.release();
  assert.equal(await fs.readFile(f.source, 'utf8'), 'external edit');
});
test('failed publish restores original from backup', async t => {
  const f = await fixture(t);
  const guard = await core.acquireSource(f.source, 'run', f.state);
  await fs.writeFile(f.tmp, 'output');
  const rename = fs.rename;
  fs.rename = async (from, to) => {
    if (from === f.tmp) throw new Error('simulated publish failure');
    return rename(from, to);
  };
  try {
    await assert.rejects(
      guard.commit(f.tmp, () => false),
      /publish failure/
    );
  } finally {
    fs.rename = rename;
    await guard.release();
  }
  assert.equal(await fs.readFile(f.source, 'utf8'), 'original');
});
test('crash recovery restores missing source or finishes verified commit', async t => {
  const f = await fixture(t);
  await fs.mkdir(f.state);
  f.source = await fs.realpath(f.source);
  const key = crypto.createHash('sha256').update(f.source).digest('hex');
  const backup = `${f.source}.nascab-video-crash.backup`;
  await fs.rename(f.source, backup);
  const record = { source: f.source, backup, phase: 'prepared', taskId: 'run', outputFingerprint: 'unused' };
  await fs.writeFile(path.join(f.state, `${key}.json`), JSON.stringify(record));
  const restored = await core.acquireSource(f.source, 'run', f.state);
  assert.equal(await fs.readFile(f.source, 'utf8'), 'original');
  await restored.release();
  await fs.rename(f.source, backup);
  await fs.writeFile(f.source, 'new output');
  record.outputFingerprint = core.fingerprint(await fs.stat(f.source));
  await fs.writeFile(path.join(f.state, `${key}.json`), JSON.stringify(record));
  const committed = await core.acquireSource(f.source, 'run', f.state);
  assert.equal(committed.alreadyCommitted, true);
  await committed.release();
  await assert.rejects(fs.stat(backup), { code: 'ENOENT' });
});

test('recovers a stale process lock and refuses symbolic-link replacement', async t => {
  const f = await fixture(t);
  const canonical = await fs.realpath(f.source);
  await fs.mkdir(f.state);
  const key = crypto.createHash('sha256').update(canonical).digest('hex');
  const child = require('node:child_process').spawn(process.execPath, ['-e', '']);
  await new Promise(resolve => child.on('exit', resolve));
  await fs.writeFile(path.join(f.state, `${key}.lock`), JSON.stringify({ pid: child.pid, token: 'old-process' }));
  const guard = await core.acquireSource(f.source, 'recovered-run', f.state);
  await guard.release();
  const link = path.join(f.dir, 'alias.mp4');
  await fs.symlink(f.source, link);
  await assert.rejects(core.acquireSource(link, 'symlink-run', f.state), /symlink/);
});

test('startup recovers missing files within a directory before enumerating inputs', async t => {
  const f = await fixture(t);
  const canonical = await fs.realpath(f.source);
  await fs.mkdir(f.state);
  const key = crypto.createHash('sha256').update(canonical).digest('hex');
  const backup = `${canonical}.nascab-video-startup.backup`;
  await fs.rename(canonical, backup);
  await fs.writeFile(path.join(f.state, `${key}.json`), JSON.stringify({ source: canonical, backup, phase: 'prepared', taskId: 'run', outputFingerprint: 'not-published' }));
  await core.recoverSourceTransactions(f.dir, f.state);
  assert.equal(await fs.readFile(f.source, 'utf8'), 'original');
});
