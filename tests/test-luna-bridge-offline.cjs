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
  "  const delay = process.argv[2] === 'exec' ? Number(process.env.LUNA_TEST_DELAY_MS || 0) : 0;",
  "  setTimeout(() => process.stdout.write('FAKE_CODEX_OK\\n'), delay);",
  "});",
].join('\n'));
if (process.platform === 'win32') {
  fs.writeFileSync(fakeCli, `@echo off\r\n"${process.execPath}" "${fakeCliScript}" %*\r\n`);
} else {
  fs.writeFileSync(fakeCli, `#!/bin/sh\nexec '${process.execPath}' '${fakeCliScript}' "$@"\n`, { mode: 0o755 });
}

const bridgeEnv = { ...process.env, CODEX_CLI_PATH: fakeCli, LUNA_TEST_CAPTURE: capturePath,
  CODEX_HOME: path.join(runDir, 'codex-home') };
delete bridgeEnv.LUNA_BRIDGE_ACTIVE;

function launchBridge(profile, delayMs = 0) {
  const bridge = spawn(process.execPath, [path.join(repoRoot, 'tools', 'luna-bridge', 'server.cjs'), profile], {
    env: { ...bridgeEnv, LUNA_TEST_DELAY_MS: String(delayMs) },
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

  return {
    request,
    notify(method) {
      bridge.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n');
    },
    close() {
      bridge.stdin.end();
      bridge.kill();
    },
  };
}

async function verifyConcurrency() {
  const fast = launchBridge('fast', 700);
  const think = launchBridge('think', 700);
  const plan = launchBridge('plan', 700);
  try {
    const editing = await Promise.all([
      fast.request('tools/call', { name: 'luna_fast_delegate', arguments: {
        cwd: workDir, mode: 'accept-edits', prompt: 'Writer A' } }),
      think.request('tools/call', { name: 'luna_think_delegate', arguments: {
        cwd: workDir, mode: 'accept-edits', prompt: 'Writer B' } }),
    ]);
    assert.equal(editing.filter(x => !x.isError).length, 1, 'Only one cross-process writer may run');
    assert.match(editing.find(x => x.isError).content[0].text, /already editing/);

    const reads = await Promise.all([
      fast.request('tools/call', { name: 'luna_fast_read', arguments: {
        cwd: workDir, prompt: 'Reader A' } }),
      think.request('tools/call', { name: 'luna_think_read', arguments: {
        cwd: workDir, prompt: 'Reader B' } }),
      plan.request('tools/call', { name: 'luna_plan_delegate', arguments: {
        cwd: workDir, mode: 'plan', prompt: 'Reader C' } }),
    ]);
    assert.equal(reads.filter(x => !x.isError).length, 2, 'At most two cross-process delegates may run');
    assert.match(reads.find(x => x.isError).content[0].text, /Two Luna delegates/);
  } finally {
    fast.close(); think.close(); plan.close();
  }
}

function optionValue(args, option) {
  const at = args.indexOf(option);
  assert.notEqual(at, -1, `Missing ${option}`);
  return args[at + 1];
}

async function verifyProfile(profile, effort) {
  const bridge = launchBridge(profile);
  const checkTool = `luna_${profile}_check`;
  const delegateTool = `luna_${profile}_delegate`;
  try {
    const init = await bridge.request('initialize', { protocolVersion: '2025-06-18', capabilities: {} });
    assert.equal(init.serverInfo.name, `luna-${profile}`);
    bridge.notify('notifications/initialized');
    const listed = await bridge.request('tools/list');
    const expectedTools = profile === 'plan'
      ? [checkTool, delegateTool]
      : [checkTool, delegateTool, `luna_${profile}_read`];
    assert.deepEqual(listed.tools.map(tool => tool.name).sort(), expectedTools.sort());
    assert.equal(listed.tools.find(tool => tool.name === checkTool).annotations.readOnlyHint, true);
    if (profile === 'plan') {
      assert.equal(listed.tools.find(tool => tool.name === delegateTool).annotations.readOnlyHint, true);
    } else {
      const readTool = listed.tools.find(tool => tool.name === `luna_${profile}_read`);
      assert.equal(readTool.annotations.readOnlyHint, true);
      assert.equal(Object.hasOwn(readTool.inputSchema.properties, 'mode'), false);
      assert.equal(listed.tools.find(tool => tool.name === delegateTool).annotations?.readOnlyHint, undefined);
    }
    const delegateSchema = listed.tools.find(tool => tool.name === delegateTool).inputSchema;
    assert.equal(Object.hasOwn(delegateSchema.properties, 'reasoningEffort'), false);
    assert.deepEqual(delegateSchema.properties.mode.enum,
      profile === 'plan' ? ['plan'] : ['plan', 'accept-edits']);

    const check = await bridge.request('tools/call', { name: checkTool, arguments: {} });
    assert.equal(check.isError, false, check.content?.[0]?.text);
    assert.equal(check.structuredContent.binary.found, true);
    assert.equal(check.structuredContent.auth.loggedIn, true);
    fs.writeFileSync(capturePath, '');

    const override = await bridge.request('tools/call', {
      name: delegateTool,
      arguments: { cwd: workDir, mode: 'plan', reasoningEffort: profile === 'fast' ? 'max' : 'medium', prompt: 'Override probe' },
    });
    assert.equal(override.isError, true);
    assert.equal(override.structuredContent.effort, effort);
    assert.equal(fs.readFileSync(capturePath, 'utf8'), '', 'An effort override must not launch Codex');

    if (profile === 'plan') {
      const refused = await bridge.request('tools/call', {
        name: delegateTool,
        arguments: { cwd: workDir, mode: 'accept-edits', prompt: 'Must be refused' },
      });
      assert.equal(refused.isError, true);
      assert.match(refused.content[0].text, /read-only/);
      assert.equal(fs.readFileSync(capturePath, 'utf8'), '', 'Plan profile must never launch an editing child');
    }

    const modes = profile === 'plan'
      ? [['plan', 'read-only']]
      : [['plan', 'read-only'], ['accept-edits', 'danger-full-access']];
    for (const [mode, sandbox] of modes) {
      const result = await bridge.request('tools/call', {
        name: delegateTool,
        arguments: { cwd: workDir, mode, prompt: `Offline ${profile} ${mode} probe` },
      });
      assert.equal(result.isError, false, `${profile}/${mode}: ${result.content?.[0]?.text}`);
      assert.equal(result.structuredContent.mode, mode);
      assert.equal(result.structuredContent.effort, effort);
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
      assert.ok(call.args.includes(`model_reasoning_effort=${effort}`));
      assert.ok(call.args.includes('approval_policy=never'));
      assert.ok(call.args.includes('agents.enabled=false'));
      assert.ok(call.args.includes('--ignore-user-config'));
      assert.ok(call.args.includes('--skip-git-repo-check'));
      assert.ok(call.args.includes('--ephemeral'));
      assert.equal(call.args[call.args.length - 1], '-');
      assert.match(call.prompt, new RegExp(`Offline ${profile} ${mode} probe`));
      assert.match(call.prompt, /Do NOT attempt further delegation/);
      if (mode === 'plan') assert.match(call.prompt, /file edits are prohibited/);
      else assert.match(call.prompt, /filesystem edits within the user's requested scope/);
    }
    if (profile !== 'plan') {
      const read = await bridge.request('tools/call', {
        name: `luna_${profile}_read`,
        arguments: { cwd: workDir, mode: 'accept-edits', prompt: 'Read tool mode-forcing probe' },
      });
      assert.equal(read.isError, false, read.content?.[0]?.text);
      assert.equal(read.structuredContent.mode, 'plan', 'Read tool must force a read-only child even for direct calls');
      const calls = fs.readFileSync(capturePath, 'utf8').trim().split(/\r?\n/).map(JSON.parse);
      assert.equal(optionValue(calls[calls.length - 1].args, '--sandbox'), 'read-only');
    }
  } finally {
    bridge.close();
  }
}

const deadline = setTimeout(() => process.exit(1), 20000);
verifyProfile('fast', 'medium')
  .then(() => verifyProfile('think', 'max'))
  .then(() => verifyProfile('plan', 'high'))
  .then(() => verifyConcurrency())
  .then(() => console.log('PASS: Luna Fast/Medium, Think/Max, Plan/High; read-only Plan, child flags, two-slot limit, and single-writer limit verified without model calls.'))
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => {
    clearTimeout(deadline);
    const resolvedRun = path.resolve(runDir);
    if (resolvedRun.startsWith(path.resolve(runsRoot) + path.sep) &&
        resolvedRun.startsWith(repoRoot + path.sep)) {
      fs.rmSync(resolvedRun, { recursive: true, force: true });
    }
  });
