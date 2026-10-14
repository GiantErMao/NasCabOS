const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveOutputGeometry, buildHardwarePipeline, canUseFullHardware, selectTranscodeModes, runTranscodeAttempts } = require('../src/api/modules/mediaTool/videoTransHardware');
const profile = {
  decodeArgs: ['-hwaccel', 'vaapi', '-hwaccel_device', '/dev/dri/renderD128', '-hwaccel_output_format', 'vaapi'],
  inputArgs: ['-vaapi_device', '/dev/dri/renderD128'],
  hwUploadFilter: 'format=nv12,hwupload',
};
test('fixed initial geometry is required before disabling autoscale on hardware frames', () => {
  const geometry = resolveOutputGeometry({ width: 1920, height: 1080, sample_aspect_ratio: '1:1' });
  const plan = buildHardwarePipeline({ profile, mode: 'hw_full', geometry });
  assert.deepEqual(plan.filters, ['scale_vaapi=w=1920:h=1080:format=nv12', 'setsar=1/1']);
  assert.deepEqual(plan.outputOptions, ['-noautoscale']);
  assert.equal(canUseFullHardware(profile, null), false);
  assert.throws(() => buildHardwarePipeline({ profile, mode: 'hw_full', geometry: null }), /geometry_unavailable/);
  assert.throws(() => buildHardwarePipeline({ profile, mode: 'hw_encode', geometry: null }), /geometry_unavailable/);
});
test('resizing fixes both axes from initial dimensions instead of recomputing width per frame', () => {
  const geometry = resolveOutputGeometry({ width: 1920, height: 1080 }, 720);
  assert.deepEqual(geometry, { width: 1280, height: 720, sar: '1/1' });
  const full = buildHardwarePipeline({ profile, mode: 'hw_full', geometry });
  assert.deepEqual(full.filters, ['scale_vaapi=w=1280:h=720:format=nv12', 'setsar=1/1']);
  const hybrid = buildHardwarePipeline({ profile, mode: 'hw_encode', geometry });
  assert.ok(!hybrid.inputOptions.some(option => option.startsWith('-hwaccel')));
  assert.deepEqual(hybrid.filters, ['scale=1280:720', 'setsar=1/1', 'format=nv12,hwupload']);
});
test('software-frame encoders and CPU conversion retain autoscale protection', () => {
  for (const mode of ['hw_encode', 'cpu']) {
    const plan = buildHardwarePipeline({ profile: { encoder: 'h264_nvenc' }, mode, geometry: { width: 640, height: 360, sar: '1/1' } });
    assert.deepEqual(plan.outputOptions, []);
    assert.deepEqual(plan.filters, ['scale=640:360', 'setsar=1/1']);
  }
  assert.equal(resolveOutputGeometry({ width: 0, height: 1080 }), null);
  assert.deepEqual(resolveOutputGeometry({ width: 641, height: 359, sample_aspect_ratio: 'N/A' }), { width: 642, height: 360, sar: '1/1' });
});
test('failed full hardware first retries CPU decoding with hardware encoding', async () => {
  const calls = [];
  const fallbacks = [];
  const result = await runTranscodeAttempts({
    modes: ['hw_full', 'hw_encode', 'cpu'],
    stopped: () => false,
    onFallback: info => fallbacks.push(`${info.mode}->${info.next}`),
    attempt: async mode => {
      calls.push(mode);
      if (mode === 'hw_full') throw new Error('filter reinit');
      return { ok: true };
    },
  });
  assert.equal(result.ok, true);
  assert.deepEqual(calls, ['hw_full', 'hw_encode']);
  assert.deepEqual(fallbacks, ['hw_full->hw_encode']);
});
test('all hardware paths fail before software; aggregated error retains each cause', async () => {
  const calls = [];
  await assert.rejects(
    runTranscodeAttempts({
      modes: ['hw_full', 'hw_encode', 'cpu'],
      stopped: () => false,
      attempt: async mode => {
        calls.push(mode);
        throw new Error(`${mode}-reason`);
      },
    }),
    error => {
      assert.match(error.message, /hw_full-reason/);
      assert.match(error.message, /hw_encode-reason/);
      assert.match(error.message, /cpu-reason/);
      return true;
    }
  );
  assert.deepEqual(calls, ['hw_full', 'hw_encode', 'cpu']);
});
test('stopping or output validation/commit failures never trigger another attempt', async () => {
  for (const noFallback of [false, true]) {
    const calls = [];
    await assert.rejects(
      runTranscodeAttempts({
        modes: ['hw_full', 'hw_encode', 'cpu'],
        stopped: () => !noFallback,
        attempt: async mode => {
          calls.push(mode);
          throw Object.assign(new Error('stop or validation'), { noFallback });
        },
      })
    );
    assert.deepEqual(calls, ['hw_full']);
  }
});

test('rotation metadata swaps the fixed canvas and uses software decode before GPU upload', () => {
  const geometry = resolveOutputGeometry({ width: 1920, height: 1080, sample_aspect_ratio: '1:1', side_data_list: [{ rotation: 90 }] });
  assert.equal(geometry.width, 1080);
  assert.equal(geometry.height, 1920);
  assert.equal(canUseFullHardware(profile, geometry), false);
  assert.equal(canUseFullHardware(profile, 720), false);
});

test('VideoToolbox and D3D11VA retain hardware decode with fixed software frames and autoscale', () => {
  const geometry = resolveOutputGeometry({ width: 1920, height: 1080 }, 720);
  for (const backend of ['videotoolbox', 'd3d11va']) {
    const decoder = { decodeArgs: ['-hwaccel', backend] };
    assert.deepEqual(selectTranscodeModes(decoder, geometry, true), ['hw_decode', 'hw_encode', 'cpu']);
    const plan = buildHardwarePipeline({ profile: decoder, mode: 'hw_decode', geometry });
    assert.deepEqual(plan.inputOptions, [`-hwaccel ${backend}`]);
    assert.deepEqual(plan.filters, ['scale=1280:720', 'setsar=1/1']);
    assert.deepEqual(plan.outputOptions, []);
    const fallback = buildHardwarePipeline({ profile: decoder, mode: 'hw_encode', geometry });
    assert.deepEqual(fallback.inputOptions, []);
    assert.deepEqual(selectTranscodeModes(decoder, { ...geometry, rotation: 90 }, true), ['hw_decode', 'hw_encode', 'cpu']);
    assert.deepEqual(selectTranscodeModes(decoder, null, true), ['hw_decode', 'hw_encode', 'cpu']);
    assert.deepEqual(selectTranscodeModes(decoder, geometry, false), ['cpu']);
  }
});

test('GPU-resident or unknown decode profiles never enter software filtering without download', () => {
  const geometry = resolveOutputGeometry({ width: 1920, height: 1080 });
  assert.deepEqual(selectTranscodeModes(profile, geometry, true), ['hw_full', 'hw_encode', 'cpu']);
  assert.deepEqual(selectTranscodeModes(profile, { ...geometry, rotation: 90 }, true), ['hw_encode', 'cpu']);
  for (const decoder of [{ decodeArgs: ['-hwaccel', 'd3d11va', '-hwaccel_output_format', 'd3d11'] }, { decodeArgs: ['-hwaccel', 'cuda'] }, {}]) {
    assert.deepEqual(selectTranscodeModes(decoder, geometry, true), ['hw_encode', 'cpu']);
    assert.throws(() => buildHardwarePipeline({ profile: decoder, mode: 'hw_decode', geometry }), /software_frame_hardware_decode_unavailable/);
  }
});

test('hardware decode failure retries software decode before abandoning hardware encoding', async () => {
  const geometry = resolveOutputGeometry({ width: 640, height: 360 });
  for (const encodeFails of [false, true]) {
    const calls = [];
    const fallbacks = [];
    const result = await runTranscodeAttempts({
      modes: selectTranscodeModes({ decodeArgs: ['-hwaccel', 'videotoolbox'] }, geometry, true),
      stopped: () => false,
      onFallback: ({ mode, next }) => fallbacks.push(`${mode}->${next}`),
      attempt: async mode => {
        calls.push(mode);
        if (mode === 'hw_decode' || (mode === 'hw_encode' && encodeFails)) throw new Error('device unavailable');
        return mode;
      },
    });
    assert.equal(result, encodeFails ? 'cpu' : 'hw_encode');
    assert.deepEqual(calls, encodeFails ? ['hw_decode', 'hw_encode', 'cpu'] : ['hw_decode', 'hw_encode']);
    assert.deepEqual(fallbacks, encodeFails ? ['hw_decode->hw_encode', 'hw_encode->cpu'] : ['hw_decode->hw_encode']);
  }
});
