const { spawn } = require('node:child_process');

function connect(serverPath, timeoutMs) {
  const child = spawn(process.execPath, [serverPath], {
    stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  const pending = new Map();
  let buffer = '', stderr = '', nextId = 0, ended = false, error;
  const timer = setTimeout(() => stop(new Error('MCP timed out')), timeoutMs);
  function stop(reason) {
    if (ended) return;
    ended = true;
    error = reason;
    clearTimeout(timer);
    for (const waiter of pending.values()) waiter.reject(reason || new Error('MCP closed'));
    pending.clear();
    child.stdin.end();
    child.kill();
  }
  child.on('error', stop);
  child.stdin.on('error', stop);
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-32768); });
  child.stdout.on('data', chunk => {
    buffer += chunk;
    if (buffer.length > 8 * 1024 * 1024) return stop(new Error('MCP output too large'));
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
      } catch (parseError) { stop(parseError); }
    }
  });
  child.on('exit', code => { if (!ended) stop(new Error(`MCP exited (${code}): ${stderr}`)); });
  function request(method, params = {}) {
    if (ended) return Promise.reject(error || new Error('MCP closed'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  return {
    request,
    notify(method) { child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n'); },
    close() { stop(); },
    get stderr() { return stderr; },
  };
}
module.exports = { connect };
