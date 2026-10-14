const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');

const child = spawn(process.execPath, [process.argv[2]], {
  stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
});
let buffer = '';
let stderr = '';
let nextId = 0;
const pending = new Map();
let failed = false;
const deadline = setTimeout(() => fail(new Error(`MCP timed out: ${stderr}`)), 20000);

function fail(error) {
  if (failed) return;
  failed = true;
  clearTimeout(deadline);
  for (const waiter of pending.values()) waiter.reject(error);
  pending.clear();
  console.error(error.message);
  process.exitCode = 1;
  child.kill();
}
function request(method, params = {}) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}
child.on('error', fail);
child.stdin.on('error', fail);
child.stderr.on('data', chunk => { stderr += chunk; });
child.stdout.on('data', chunk => {
  buffer += chunk;
  let end;
  while ((end = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, end).trim();
    buffer = buffer.slice(end + 1);
    if (!line) continue;
    try {
      const reply = JSON.parse(line);
      const waiter = pending.get(reply.id);
      if (!waiter) continue;
      pending.delete(reply.id);
      if (reply.error) waiter.reject(new Error(JSON.stringify(reply.error)));
      else waiter.resolve(reply.result);
    } catch (error) { fail(error); }
  }
});
child.on('exit', code => {
  if (pending.size) fail(new Error(`MCP exited (${code}): ${stderr}`));
});

(async () => {
  try {
    const init = await request('initialize', {
      protocolVersion: '2025-06-18', capabilities: {},
      clientInfo: { name: 'gemini-and-codex-installer-test', version: '1.0.0' },
    });
    assert.equal(init.serverInfo.name, 'agy-mcp-server');
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    const listed = await request('tools/list');
    assert.deepEqual(listed.tools.map(tool => tool.name).sort(), ['agy_check', 'agy_delegate']);
    const checked = await request('tools/call', { name: 'agy_check', arguments: {} });
    assert.notEqual(checked.isError, true);
    assert.match(checked.content[0].text, /Antigravity CLI is available at:/);
    console.log('MCP initialize, tools/list and agy_check passed. No agent launched.');
    clearTimeout(deadline);
    child.stdin.end();
    child.kill();
  } catch (error) { fail(error); }
})();
