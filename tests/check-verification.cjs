const assert = require('node:assert/strict');
const { validateEnvelope } = require('../scripts/check-antigravity.cjs');
const expected = 'AGY_OK_test_nonce';
function result(envelope, extra = {}) {
  return { content: [{ type: 'text', text: JSON.stringify(envelope) }],
    structuredContent: { exitCode: 0, timedOut: false }, ...extra };
}
const successful = { status: 'SUCCESS', response: expected };
assert.equal(validateEnvelope(result(successful), expected).response, expected);
const stderrResult = result(successful);
stderrResult.content[0].text += '\n\nstderr:\nA diagnostic notice';
assert.equal(validateEnvelope(stderrResult, expected).response, expected);
assert.throws(() => validateEnvelope(result({ status: 'SUCCESS', response: '' }), expected), /empty/);
assert.throws(() => validateEnvelope(result({ ...successful, denied_actions: [{ action: 'command' }] }), expected), /denied/);
assert.throws(() => validateEnvelope(result({ ...successful, response: 'AGY_OK_wrong_nonce' }), expected), /challenge/);
assert.throws(() => validateEnvelope(result({ ...successful, status: 'ERROR' }), expected), /status/);
assert.throws(() => validateEnvelope(result(successful, { isError: true }), expected), /MCP/);
assert.throws(() => validateEnvelope(result(successful, { structuredContent: { exitCode: 0, timedOut: true } }), expected), /exit/);
assert.throws(() => validateEnvelope(result(successful, { structuredContent: { exitCode: 3, timedOut: false } }), expected), /exit/);
assert.throws(() => validateEnvelope({ content: [{ type: 'text', text: 'broken JSON' }], structuredContent: { exitCode: 0 } }, expected));
console.log('PASS: successful challenge accepted; empty SUCCESS, denied actions, wrong nonce, errors and timeouts rejected.');
