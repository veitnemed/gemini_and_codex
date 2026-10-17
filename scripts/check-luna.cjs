const path = require('node:path');
const crypto = require('node:crypto');
const { connect } = require('./mcp-client.cjs');

function sanitize(text) {
  if (typeof text !== 'string') return '';
  return text
    .replace(/(bearer\s+)[A-Za-z0-9._~+/-]+=*/gi, '$1[REDACTED]')
    .replace(/\b(sk-[A-Za-z0-9_-]{20,})\b/gi, '[REDACTED]')
    .replace(/\b(sess-[A-Za-z0-9_-]{20,})\b/gi, '[REDACTED]')
    .replace(/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]+\b/gi, '[REDACTED_JWT]')
    .replace(/\b[A-Fa-f0-9]{32,64}\b/g, '[REDACTED_HEX]');
}

function validateDelegationResult(raw, expectedNonce, expectedParams) {
  if (!raw || typeof raw !== 'object') {
    throw new Error('Invalid MCP response object');
  }
  if (raw.isError) {
    const errText = (raw.content || [])
      .filter(item => item && item.type === 'text')
      .map(item => item.text)
      .join(' ')
      .trim();
    throw new Error(`MCP reported error: ${sanitize(errText) || 'unknown error'}`);
  }

  const structured = raw.structuredContent;
  if (!structured || typeof structured !== 'object') {
    throw new Error('Missing structuredContent in delegation result');
  }
  if (structured.timedOut) {
    throw new Error('Luna delegation timed out');
  }
  if (structured.exitCode !== 0) {
    throw new Error(`Luna delegation failed with exit code ${structured.exitCode}`);
  }
  if (structured.model !== expectedParams.model) {
    throw new Error(`Model mismatch: expected ${expectedParams.model}, got ${structured.model}`);
  }
  if (structured.effort !== expectedParams.reasoningEffort) {
    throw new Error(`Reasoning effort mismatch: expected ${expectedParams.reasoningEffort}, got ${structured.effort}`);
  }
  if (structured.mode !== expectedParams.mode) {
    throw new Error(`Mode mismatch: expected ${expectedParams.mode}, got ${structured.mode}`);
  }

  const text = (raw.content || [])
    .filter(item => item && item.type === 'text')
    .map(item => item.text)
    .join('\n')
    .trim();

  if (text !== expectedNonce) {
    throw new Error(`Content mismatch: expected exact nonce challenge reply, received '${sanitize(text)}'`);
  }

  return { structured, text };
}

async function main() {
  const [serverPath, cwdArg, timeoutText] = process.argv.slice(2);
  const timeoutSeconds = Number(timeoutText);

  if (!serverPath || !cwdArg || !Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 1800) {
    console.error('Usage: node scripts/check-luna.cjs SERVER_PATH CWD TIMEOUT_SECONDS');
    process.exit(1);
  }

  if (!path.isAbsolute(cwdArg)) {
    console.error(`CWD must be an absolute path: ${sanitize(cwdArg)}`);
    process.exit(1);
  }

  const nonce = `LUNA_OK_${crypto.randomBytes(8).toString('hex')}`;
  const taskId = `smoke-${nonce}`;
  const delegateParams = {
    prompt: `Reply with exactly ${nonce}. This is a connectivity check. Do not use tools, inspect or modify files, run commands, or delegate.`,
    cwd: cwdArg,
    mode: 'plan',
    reasoningEffort: 'high',
    timeoutSeconds,
    taskId
  };

  const client = connect(serverPath, (timeoutSeconds + 30) * 1000);
  const started = Date.now();

  try {
    await client.request('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'luna-live-check', version: '1.0.0' }
    });
    client.notify('notifications/initialized');

    const listResult = await client.request('tools/list', {});
    const tools = Array.isArray(listResult?.tools) ? listResult.tools : [];
    const toolNames = new Set(tools.map(t => t?.name));
    if (!toolNames.has('luna_check') || !toolNames.has('luna_delegate')) {
      throw new Error(`Required tools missing. Available tools: ${Array.from(toolNames).join(', ')}`);
    }

    const checkResult = await client.request('tools/call', {
      name: 'luna_check',
      arguments: {}
    });
    if (checkResult?.isError) {
      const err = (checkResult.content || []).map(c => c.text).join(' ');
      throw new Error(`luna_check reported failure: ${sanitize(err)}`);
    }

    const checkData = checkResult?.structuredContent;
    if (!checkData?.binary?.found) {
      throw new Error(`Codex binary not found: ${sanitize(checkData?.binary?.error || 'missing binary')}`);
    }
    if (!checkData?.auth?.loggedIn) {
      throw new Error(`Codex CLI not logged in: ${sanitize(checkData?.auth?.error || 'unauthenticated')}`);
    }

    const delegationRaw = await client.request('tools/call', {
      name: 'luna_delegate',
      arguments: delegateParams
    });

    validateDelegationResult(delegationRaw, nonce, {
      model: 'gpt-6-luna',
      reasoningEffort: 'high',
      mode: 'plan'
    });

    const elapsed = ((Date.now() - started) / 1000).toFixed(2);
    console.log(`[LUNA] PASS: challenge verified in ${elapsed}s (exit 0)`);
  } catch (error) {
    const elapsed = ((Date.now() - started) / 1000).toFixed(2);
    console.error(`[LUNA] FAIL: ${sanitize(error.message)} (${elapsed}s, exit 1)`);
    process.exitCode = 1;
  } finally {
    client.close();
  }
}

if (require.main === module) {
  main().catch(error => {
    console.error(`[LUNA] FAIL: ${sanitize(error.message)}`);
    process.exit(1);
  });
}

module.exports = { validateDelegationResult };
