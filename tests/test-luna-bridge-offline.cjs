'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { spawn } = require('node:child_process');

const repoRoot = path.resolve(__dirname, '..');
const runsRoot = path.join(repoRoot, '.test-runs');
fs.mkdirSync(runsRoot, { recursive: true });
const runDir = fs.mkdtempSync(path.join(runsRoot, 'luna-bridge-offline-'));
const workDir = path.join(runDir, 'plain directory without git');
fs.mkdirSync(workDir);

const fakeCliScript = path.join(runDir, 'fake-codex.cjs');
const fakeCli = path.join(runDir, process.platform === 'win32' ? 'codex.cmd' : 'codex');
const capturePath = path.join(runDir, 'calls.jsonl');
fs.writeFileSync(fakeCliScript, [
  "const fs = require('node:fs');",
  "let prompt = '';",
  "process.stdin.setEncoding('utf8');",
  "process.stdin.on('data', chunk => { prompt += chunk; });",
  "process.stdin.on('end', () => {",
  "  fs.appendFileSync(process.env.LUNA_TEST_CAPTURE, JSON.stringify({",
  "    args: process.argv.slice(2), cwd: process.cwd(), prompt,",
  "    bridgeActive: process.env.LUNA_BRIDGE_ACTIVE",
  "  }) + '\\n');",
  "  process.stdout.write('FAKE_CODEX_OK\\n');",
  "});",
].join('\n'));
if (process.platform === 'win32') {
  fs.writeFileSync(fakeCli, `@echo off\r\n"${process.execPath}" "${fakeCliScript}" %*\r\n`);
} else {
  fs.writeFileSync(fakeCli, `#!/bin/sh\nexec '${process.execPath}' '${fakeCliScript}' "$@"\n`, { mode: 0o755 });
}

const bridgeEnv = { ...process.env, CODEX_CLI_PATH: fakeCli, LUNA_TEST_CAPTURE: capturePath };
delete bridgeEnv.LUNA_BRIDGE_ACTIVE;
const bridge = spawn(process.execPath, [path.join(repoRoot, 'tools', 'luna-bridge', 'server.cjs')], {
  env: bridgeEnv,
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});
let stderr = '';
bridge.stderr.on('data', chunk => { stderr += chunk; });
let nextId = 0;
const pending = new Map();
const lines = readline.createInterface({ input: bridge.stdout });
lines.on('line', line => {
  let reply;
  try { reply = JSON.parse(line); } catch (error) {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
    return;
  }
  const waiter = pending.get(reply.id);
  if (!waiter) return;
  pending.delete(reply.id);
  if (reply.error) waiter.reject(new Error(JSON.stringify(reply.error)));
  else waiter.resolve(reply.result);
});
bridge.on('error', error => {
  for (const waiter of pending.values()) waiter.reject(error);
  pending.clear();
});
bridge.on('exit', code => {
  for (const waiter of pending.values()) waiter.reject(new Error(`Bridge exited ${code}: ${stderr}`));
  pending.clear();
});

function request(method, params = {}) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    bridge.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

function optionValue(args, option) {
  const at = args.indexOf(option);
  assert.notEqual(at, -1, `Missing ${option}`);
  return args[at + 1];
}

async function main() {
  const init = await request('initialize', { protocolVersion: '2025-06-18', capabilities: {} });
  assert.equal(init.serverInfo.name, 'luna-bridge');
  bridge.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const listed = await request('tools/list');
  assert.deepEqual(listed.tools.map(tool => tool.name).sort(), ['luna_check', 'luna_delegate']);

  const check = await request('tools/call', { name: 'luna_check', arguments: {} });
  assert.equal(check.isError, false, check.content?.[0]?.text);
  assert.equal(check.structuredContent.binary.found, true);
  assert.equal(check.structuredContent.auth.loggedIn, true);
  fs.writeFileSync(capturePath, '');

  for (const [mode, sandbox] of [['plan', 'read-only'], ['accept-edits', 'danger-full-access']]) {
    const result = await request('tools/call', {
      name: 'luna_delegate',
      arguments: { cwd: workDir, mode, reasoningEffort: 'max', prompt: `Offline ${mode} probe` },
    });
    assert.equal(result.isError, false, `${mode}: ${result.content?.[0]?.text}`);
    assert.equal(result.structuredContent.mode, mode);
    assert.equal(result.structuredContent.effort, 'max');
    assert.equal(result.structuredContent.exitCode, 0);
    assert.match(result.content[0].text, /FAKE_CODEX_OK/);

    const calls = fs.readFileSync(capturePath, 'utf8').trim().split(/\r?\n/).map(JSON.parse);
    const call = calls[calls.length - 1];
    assert.equal(calls.length, mode === 'plan' ? 1 : 2);
    assert.equal(call.cwd, workDir);
    assert.equal(call.bridgeActive, '1');
    assert.equal(call.args[0], 'exec');
    assert.equal(optionValue(call.args, '-m'), 'gpt-6-luna');
    assert.equal(optionValue(call.args, '--sandbox'), sandbox);
    assert.ok(call.args.includes('model_reasoning_effort=max'));
    assert.ok(call.args.includes('approval_policy=never'));
    assert.ok(call.args.includes('agents.enabled=false'));
    assert.ok(call.args.includes('--ignore-user-config'));
    assert.ok(call.args.includes('--skip-git-repo-check'));
    assert.ok(call.args.includes('--ephemeral'));
    assert.equal(call.args[call.args.length - 1], '-');
    assert.match(call.prompt, new RegExp(`Offline ${mode} probe`));
    assert.match(call.prompt, /Do NOT attempt further delegation/);
    if (mode === 'plan') assert.match(call.prompt, /file edits are prohibited/);
    else assert.match(call.prompt, /filesystem edits within the user's requested scope/);
  }
  console.log('PASS: Luna plan is read-only; accept-edits has full access; non-Git cwd and child flags verified without model calls.');
}

const deadline = setTimeout(() => bridge.kill(), 20000);
main().catch(error => {
  console.error(error);
  if (stderr) console.error(stderr);
  process.exitCode = 1;
}).finally(() => {
  clearTimeout(deadline);
  bridge.stdin.end();
  bridge.kill();
  const resolvedRun = path.resolve(runDir);
  if (resolvedRun.startsWith(path.resolve(runsRoot) + path.sep) &&
      resolvedRun.startsWith(repoRoot + path.sep)) {
    fs.rmSync(resolvedRun, { recursive: true, force: true });
  }
});
