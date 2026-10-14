function optionPairs(args) {
  if (!Array.isArray(args)) return [];
  const output = [];
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (typeof key !== 'string') continue;
    if (key.startsWith('-') && typeof args[i + 1] === 'string' && !args[i + 1].startsWith('-')) output.push(`${key} ${args[++i]}`);
    else output.push(key);
  }
  return output;
}
function hardwareFrameFormat(profile) {
  const args = profile?.decodeArgs || [];
  const index = args.indexOf('-hwaccel_output_format');
  return index >= 0 ? args[index + 1] : '';
}
function resolveOutputGeometry(video, height) {
  let width = Number(video?.width);
  let sourceHeight = Number(video?.height);
  if (!Number.isFinite(width) || !Number.isFinite(sourceHeight) || width <= 0 || sourceHeight <= 0) return null;
  const rotation = Number(video.rotation ?? video.side_data_list?.find(item => Number.isFinite(Number(item.rotation)))?.rotation ?? video.tags?.rotate ?? 0);
  const quarterTurn = Number.isFinite(rotation) && Math.abs(rotation % 180) === 90;
  if (quarterTurn) [width, sourceHeight] = [sourceHeight, width];
  const even = value => Math.max(2, Math.round(value / 2) * 2);
  const targetHeight = height || sourceHeight;
  const targetWidth = height ? (width * targetHeight) / sourceHeight : width;
  const ratio = String(video.sample_aspect_ratio || '1:1')
    .split(/[:/]/)
    .map(Number);
  const sar = ratio.length === 2 && ratio.every(value => Number.isFinite(value) && value > 0) ? `${ratio[0]}/${ratio[1]}` : '1/1';
  return { width: even(targetWidth), height: even(targetHeight), sar: quarterTurn ? sar.split('/').reverse().join('/') : sar, ...(rotation ? { rotation } : {}) };
}
function hardwareScale(profile, geometry) {
  if (!geometry || !Number.isInteger(geometry.width) || !Number.isInteger(geometry.height) || geometry.width <= 0 || geometry.height <= 0) return null;
  const filter = { vaapi: 'scale_vaapi', cuda: 'scale_cuda', qsv: 'scale_qsv' }[hardwareFrameFormat(profile)];
  return filter ? `${filter}=w=${geometry.width}:h=${geometry.height}:format=nv12` : null;
}
function canUseFullHardware(profile, geometry) {
  return !geometry?.rotation && !!profile?.decodeArgs?.length && !!hardwareScale(profile, geometry);
}
function canUseHardwareDecodeWithSoftwareFrames(profile) {
  const args = profile?.decodeArgs || [];
  const index = args.indexOf('-hwaccel');
  // These backends return software frames unless a hardware output format is
  // explicitly requested. Other GPU frame formats need a download filter.
  return !hardwareFrameFormat(profile) && index >= 0 && ['videotoolbox', 'd3d11va'].includes(args[index + 1]);
}
function selectTranscodeModes(profile, geometry, enabled) {
  if (!enabled) return ['cpu'];
  const decodeMode = canUseFullHardware(profile, geometry) ? 'hw_full' : canUseHardwareDecodeWithSoftwareFrames(profile) ? 'hw_decode' : null;
  return [...(decodeMode ? [decodeMode] : []), 'hw_encode', 'cpu'];
}
function buildHardwarePipeline({ profile, mode, geometry, softwareScale }) {
  const softwareFilters = geometry ? [`scale=${geometry.width}:${geometry.height}`, `setsar=${geometry.sar}`] : softwareScale ? [softwareScale] : [];
  if (mode === 'cpu') return { inputOptions: [], outputOptions: [], filters: softwareFilters };
  const inputOptions = [...optionPairs(profile?.initDeviceArgs), ...optionPairs(profile?.inputArgs)];
  let filters = [];
  let fixedHardwareFrames = false;
  if (mode === 'hw_full') {
    const scale = hardwareScale(profile, geometry);
    if (!scale) throw new Error('fixed_hardware_geometry_unavailable');
    inputOptions.push(...optionPairs(profile?.decodeArgs));
    if (hardwareFrameFormat(profile) === 'cuda') inputOptions.push('-extra_hw_frames 8');
    filters = [scale, `setsar=${geometry.sar}`];
    fixedHardwareFrames = true;
  } else {
    if (mode === 'hw_decode') {
      if (!canUseHardwareDecodeWithSoftwareFrames(profile)) throw new Error('software_frame_hardware_decode_unavailable');
      inputOptions.push(...optionPairs(profile.decodeArgs));
    }
    filters = softwareFilters;
    // Software frames are normalized before uploading; NVENC/VideoToolbox
    // can consume software frames and retain FFmpeg's autoscale safeguard.
    if (profile?.hwUploadFilter) {
      // Unknown dimensions cannot guarantee safe GPU frames: defer to CPU mode.
      if (!geometry) throw new Error('fixed_upload_geometry_unavailable');
      filters.push(profile.hwUploadFilter);
      fixedHardwareFrames = true;
    }
  }
  return { inputOptions, outputOptions: fixedHardwareFrames ? ['-noautoscale'] : [], filters };
}
async function runTranscodeAttempts({ modes, attempt, stopped, onFallback }) {
  const failures = [];
  for (const mode of modes) {
    try {
      return await attempt(mode);
    } catch (error) {
      if (stopped() || error.noFallback) throw error;
      failures.push({ mode, error });
      const next = modes[failures.length];
      if (next && onFallback) onFallback({ mode, next, error });
    }
  }
  throw new Error(failures.map(({ mode, error }) => `${mode} failed: ${error.message || String(error)}`).join('\n'));
}
module.exports = {
  resolveOutputGeometry,
  hardwareFrameFormat,
  hardwareScale,
  canUseFullHardware,
  canUseHardwareDecodeWithSoftwareFrames,
  selectTranscodeModes,
  buildHardwarePipeline,
  runTranscodeAttempts,
};
