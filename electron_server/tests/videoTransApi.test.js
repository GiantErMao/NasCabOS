const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const { validationResult } = require('express-validator');
function load(name, overrides) {
  const file = path.resolve(__dirname, '../src/api/modules/mediaTool', name);
  const req = createRequire(file);
  const module = { exports: {} };
  vm.runInNewContext(
    fs.readFileSync(file, 'utf8'),
    {
      module,
      Date,
      require(id) {
        return Object.hasOwn(overrides, id) ? overrides[id] : req(id);
      },
    },
    { filename: file }
  );
  return module.exports;
}
const validation = load('videoTransValidation.js', { '../../../utils/i18nUtil': { getLocalizedMessage: (_, value) => value } });
const { VideoTransService } = load('videoTransService.js', {
  '../../../db/table/tableMediaToolVideoTrans': { NON_VIDEO_SKIP: 'skip', NON_VIDEO_COPY: 'copy', STATUS_RUNNING: 'running', STATUS_STOPPED: 'stopped' },
});
async function validate(body) {
  const req = { body };
  for (const rule of validation.validateUpsert()) await rule.run(req);
  return { req, errors: validationResult(req) };
}
test('API permits missing target only with true replacement, sanitizes quoted paths and rejects bad trim combinations', async () => {
  const base = { source_path: '"/media/a b.mp4"', non_video_policy: 'skip' };
  const replace = await validate({ ...base, trans_config: { replace_source: true, trim_start_seconds: 1, trim_end_seconds: 3 } });
  assert.equal(replace.errors.isEmpty(), true);
  assert.equal(replace.req.body.source_path, '/media/a b.mp4');
  assert.equal((await validate({ ...base, trans_config: {} })).errors.isEmpty(), false);
  assert.equal((await validate({ ...base, target_path: '/output', trans_config: { out_format: 'gif', trim_start_seconds: 1 } })).errors.isEmpty(), false);
  assert.equal((await validate({ ...base, target_path: '/output', trans_config: '{}' })).errors.isEmpty(), true);
});
test('service persists compatible defaults, forces source format in replacement, and preserves ordinary path conflict checks', async () => {
  let inserted;
  const service = new VideoTransService(() => ({
    insert: async value => {
      inserted = value;
      return [42];
    },
  }));
  const base = { sourcePath: '/media/source.mp4', nonVideoPolicy: 'skip' };
  await service.upsert({ ...base, transConfig: { replace_source: true, out_format: 'mp4' } });
  assert.equal(inserted.target_path, '');
  const parsed = JSON.parse(inserted.trans_config);
  assert.equal(parsed.out_format, 'source');
  assert.equal(parsed.replace_source, true);
  await service.upsert({ ...base, targetPath: '/output', transConfig: '{}' });
  assert.equal(JSON.parse(inserted.trans_config).out_format, 'mp4');
  assert.equal(JSON.parse(inserted.trans_config).trim_start_seconds, 0);
  await assert.rejects(service.upsert({ ...base, targetPath: '/media', transConfig: {} }), /SOURCE_TARGET_PATH_CONFLICT/);
  await assert.rejects(service.upsert({ ...base, transConfig: {} }), /INVALID_PARAMS/);
});
