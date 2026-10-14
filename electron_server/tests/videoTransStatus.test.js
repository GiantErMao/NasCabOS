const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const file = path.resolve(__dirname, '../src/api/modules/mediaTool/videoTransService.js');
const moduleObject = { exports: {} };
vm.runInNewContext(fs.readFileSync(file, 'utf8'), {
  module: moduleObject,
  require(id) {
    if (id === '../../../db/table/tableMediaToolVideoTrans') {
      return { STATUS_STOPPED: 'stopped' };
    }
    return {};
  },
}, { filename: file });

const { displayVideoTransStatus } = moduleObject.exports;

test('completed runs show completed while manual stops remain stopped', () => {
  assert.equal(displayVideoTransStatus({ status: 'stopped', total_files: 1, done_files: 1, last_end_time: 123 }), 'completed');
  assert.equal(displayVideoTransStatus({ status: 'stopped', total_files: 1, done_files: 0, last_end_time: 123 }), 'stopped');
  assert.equal(displayVideoTransStatus({ status: 'stopped', total_files: 1, done_files: 1, last_end_time: null }), 'stopped');
  assert.equal(displayVideoTransStatus({ status: 'running', total_files: 1, done_files: 1, last_end_time: null }), 'running');
});
