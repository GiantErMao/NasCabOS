const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { execFileSync } = require('node:child_process');
const core = require('../src/api/modules/mediaTool/videoTransCore');
const workerFile = path.resolve(__dirname, '../src/workers/mediaTool/videoTrans/videoTransWorker.js');
const workerRequire = createRequire(workerFile);
const moduleObject = { exports: {} };
// Exercise production FFmpeg execution without initializing the application's real DB.
const sandbox = {
  module: moduleObject,
  process,
  console: { log() {} },
  setInterval,
  clearInterval,
  setTimeout,
  clearTimeout,
  require(id) {
    if (id.endsWith('/ffmpegPath')) return { path: process.env.TEST_FFMPEG || 'ffmpeg' };
    if (id.endsWith('/ffprobePath')) return { path: process.env.TEST_FFPROBE || 'ffprobe' };
    if (id.endsWith('/logger')) return { info() {}, error() {} };
    if (id.endsWith('/config')) return { getRootPath: () => os.tmpdir() };
    if (id.endsWith('/tableMediaToolVideoTrans')) return { STATUS_STOPPED: 'stopped', STATUS_ERROR: 'error', NON_VIDEO_COPY: 'copy', NON_VIDEO_SKIP: 'skip' };
    if (id.endsWith('/pathUtil')) return workerRequire(id);
    if (id.endsWith('/knexUtil')) return { init: async () => {} };
    if (id.endsWith('/tableConfig')) return { getConfigByKey: async key => (key === 'transcode_hwaccel_selected' ? JSON.stringify({ profiles: { h264: { encoder: 'h264_missing_encoder' } } }) : '') };
    if (id.endsWith('/transcodeHwAccelUtil')) return { normalizeAvailableHwAccelList: () => [], pickEffectiveHwAccelConfig: ({ autoSelected }) => autoSelected };
    if (/dbUtil|imageCompressCore/.test(id)) return {};
    return workerRequire(id);
  },
};
vm.runInNewContext(require('node:fs').readFileSync(workerFile, 'utf8'), sandbox, { filename: workerFile });
const { transcodeOne, validateOutput } = moduleObject.exports;
const probe = file => JSON.parse(execFileSync(process.env.TEST_FFPROBE || 'ffprobe', ['-v', 'error', '-show_format', '-show_streams', '-of', 'json', file], { encoding: 'utf8' }));

test('production FFmpeg trims fractional ranges, EOF, source containers, skips and validated replacement', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'video-trim-integration-'));
  t.after(() => fs.rm(dir, { force: true, recursive: true }));
  const source = path.join(dir, '视频 source.mp4');
  execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', [
    '-v',
    'error',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=160x90:rate=25:duration=4',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:duration=4',
    '-c:v',
    'libx264',
    '-c:a',
    'aac',
    '-shortest',
    source,
  ]);
  const config = extra => core.normalizeVideoConfig({ out_format: 'source', vcodec: 'h264', acodec: 'aac', resolution: 'source', enable_hw_accel: false, ...extra });
  const run = (outputPath, cfg, sourceGuard) => transcodeOne({ inputPath: source, outputPath, cfg, sourceGuard, stopSignal: () => false, onCommand() {}, onProgress() {} });
  const original = await fs.readFile(source);
  for (const [name, start, end, expected] of [
    ['clip', 0.5, 2.5, 2],
    ['eof', 1, 0, 3],
    ['full', 0, 0, 4],
  ]) {
    const output = path.join(dir, `${name}.mp4`);
    assert.equal((await run(output, config({ trim_start_seconds: start, trim_end_seconds: end }))).ok, true);
    const metadata = probe(output);
    assert.ok(Math.abs(Number(metadata.format.duration) - expected) < 0.25);
    assert.ok(metadata.streams.some(s => s.codec_type === 'audio'));
    const frame = (file, time) => execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-v', 'error', '-ss', String(time), '-i', file, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']);
    const expectedFrame = frame(source, start);
    const actualFrame = frame(output, 0);
    const difference = actualFrame.reduce((sum, value, i) => sum + Math.abs(value - expectedFrame[i]), 0) / actualFrame.length;
    assert.ok(difference < 8, `trim starts at expected frame: ${difference}`);
  }
  assert.deepEqual(await fs.readFile(source), original);
  const invalid = path.join(dir, 'invalid.mp4');
  assert.equal((await run(invalid, config({ trim_end_seconds: 8 }))).skipped, 'trim_time_exceeds_duration');
  await assert.rejects(fs.stat(invalid), { code: 'ENOENT' });
  const guard = await core.acquireSource(source, 'integration-run', path.join(dir, 'state'));
  try {
    assert.equal((await run(source, config({ replace_source: true, trim_start_seconds: 1, trim_end_seconds: 3 }), guard)).ok, true);
  } finally {
    await guard.release();
  }
  assert.ok(Math.abs(Number(probe(source).format.duration) - 2) < 0.25);
  assert.ok(!(await fs.readdir(dir)).some(name => name.endsWith('.backup') || name.endsWith('.cab.tmp')));
});

test('validation rejects empty/damaged and wrong-duration outputs', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'video-invalid-'));
  t.after(() => fs.rm(dir, { force: true, recursive: true }));
  const tmp = path.join(dir, 'broken.mp4');
  await fs.writeFile(tmp, 'broken data');
  await assert.rejects(validateOutput({ tmp, metadata: {}, spec: { muxer: 'mp4', probeFormat: 'mov' }, cfg: {}, expectedDuration: 1, stopSignal: () => false }));
});

test('source container mappings and existing GIF/WebP conversion remain usable', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'video-containers-'));
  t.after(() => fs.rm(dir, { force: true, recursive: true }));
  const original = path.join(dir, 'original.mp4');
  execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=25:duration=2', '-c:v', 'libx264', original]);
  const cfg = core.normalizeVideoConfig({ out_format: 'source', vcodec: 'h264', enable_hw_accel: false, trim_start_seconds: 0.5, trim_end_seconds: 1.5 });
  for (const extension of ['mov', 'avi', 'mkv', 'ts']) {
    const input = path.join(dir, `source.${extension}`);
    const output = path.join(dir, `output.${extension}`);
    execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-v', 'error', '-i', original, '-c', 'copy', input]);
    assert.equal((await transcodeOne({ inputPath: input, outputPath: output, cfg, stopSignal: () => false })).ok, true);
    assert.equal(probe(output).format.format_name.includes(core.outputSpec(input, cfg).probeFormat), true);
  }
  const encoders = execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-hide_banner', '-encoders'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  for (const format of ['gif', 'webp']) {
    await t.test(`${format} conversion`, { skip: format === 'webp' && !encoders.includes('libwebp') ? 'Installed FFmpeg lacks libwebp encoder' : false }, async () => {
      const output = path.join(dir, `animation.${format}`);
      assert.equal(
        (
          await transcodeOne({
            inputPath: original,
            outputPath: output,
            cfg: core.normalizeVideoConfig({ out_format: format, resolution: '240p', fps: 10, enable_hw_accel: false }),
            stopSignal: () => false,
          })
        ).ok,
        true
      );
    });
  }
  const fallback = path.join(dir, 'fallback.mp4');
  assert.equal((await transcodeOne({ inputPath: original, outputPath: fallback, cfg: { ...cfg, enable_hw_accel: true }, stopSignal: () => false })).ok, true);
  assert.ok(Math.abs(Number(probe(fallback).format.duration) - 1) < 0.25);
  await assert.rejects(validateOutput({ tmp: original, metadata: probe(original), expectedDuration: 8, spec: core.outputSpec(original, cfg), cfg, stopSignal: () => false }), /duration_mismatch/);
});

test('directory tasks process mixed formats independently and retain out-of-range reasons', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'video-directory-'));
  t.after(() => fs.rm(dir, { force: true, recursive: true }));
  const sourceDir = path.join(dir, 'sources');
  const target = path.join(dir, 'outputs');
  await fs.mkdir(sourceDir);
  await fs.mkdir(target);
  const mp4 = path.join(sourceDir, 'long.mp4');
  execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=25:duration=2', '-c:v', 'libx264', mp4]);
  execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-v', 'error', '-i', mp4, '-c', 'copy', path.join(sourceDir, 'long.mkv')]);
  execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-v', 'error', '-i', mp4, '-t', '0.3', '-c', 'copy', path.join(sourceDir, 'short.mp4')]);
  await fs.writeFile(path.join(sourceDir, 'note.txt'), 'leave unchanged');
  await fs.writeFile(path.join(sourceDir, 'ignored.mp4.123.cab.tmp'), 'ignore');
  const worker = Object.create(moduleObject.exports.VideoTransWorker.prototype);
  Object.assign(worker, { stopRequested: false, _runningCommands: new Set(), _skipMessages: [], taskId: 900 });
  let state = {};
  worker._updateTask = async patch => {
    state = { ...state, ...patch };
  };
  await worker._run({
    sourceType: 'dir',
    sourceResolved: sourceDir,
    targetResolved: target,
    targetRootResolved: target,
    cfg: core.normalizeVideoConfig({ out_format: 'source', enable_hw_accel: false, trim_start_seconds: 0.5, trim_end_seconds: 1.5 }),
    nonVideoPolicy: 'skip',
  });
  assert.equal(state.total_files, 4);
  assert.equal(state.done_files, 4);
  assert.equal(state.processed_count, 2);
  assert.equal(state.skipped_count, 2);
  assert.match(state.last_error, /short.mp4: trim_time_exceeds_duration/);
  assert.ok((await fs.readdir(target)).includes('long.mkv'));
  assert.ok((await fs.readdir(target)).includes('long.mp4'));
  await assert.rejects(fs.stat(path.join(target, 'short.mp4')), { code: 'ENOENT' });
});

test('stopping FFmpeg during replacement leaves source bytes untouched', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'video-stop-'));
  t.after(() => fs.rm(dir, { force: true, recursive: true }));
  const source = path.join(dir, 'source.mp4');
  execFileSync(process.env.TEST_FFMPEG || 'ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=25:duration=2', '-c:v', 'libx264', source]);
  const original = await fs.readFile(source);
  const guard = await core.acquireSource(source, 'stop-test', path.join(dir, 'state'));
  let stopped = false;
  try {
    await assert.rejects(
      transcodeOne({
        inputPath: source,
        outputPath: source,
        sourceGuard: guard,
        cfg: core.normalizeVideoConfig({ replace_source: true, trim_start_seconds: 0.5, enable_hw_accel: false }),
        stopSignal: () => stopped,
        onCommand(cmd) {
          stopped = true;
          cmd.kill('SIGKILL');
        },
      })
    );
  } finally {
    await guard.release();
  }
  assert.deepEqual(await fs.readFile(source), original);
  assert.ok(!(await fs.readdir(dir)).some(name => name.endsWith('.backup') || name.endsWith('.cab.tmp')));
});
