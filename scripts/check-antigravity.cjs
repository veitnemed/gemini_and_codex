const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { connect } = require('./mcp-client.cjs');

function validateEnvelope(raw, expected) {
  if (raw.isError) throw new Error('MCP reported a failed delegation');
  if (raw.structuredContent?.timedOut || raw.structuredContent?.exitCode !== 0) {
    throw new Error('Antigravity did not exit successfully');
  }
  const text = (raw.content || []).filter(item => item.type === 'text').map(item => item.text).join('\n');
  // The pinned bridge appends stderr after its captured JSON stdout.
  const envelope = JSON.parse(text.split('\n\nstderr:\n')[0]);
  if (envelope.status !== 'SUCCESS') throw new Error(`Antigravity status: ${envelope.status}`);
  if (envelope.denied_actions?.length) throw new Error('Antigravity reported denied tool actions');
  if (typeof envelope.response !== 'string' || envelope.response.trim() !== expected) {
    throw new Error('Response is empty or does not match the unique challenge');
  }
  return envelope;
}

async function main() {
  const [serverPath, model, timeoutText, logDirectory] = process.argv.slice(2);
  const timeoutSeconds = Number(timeoutText);
  if (!serverPath || !model || !logDirectory || !Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 120) {
    throw new Error('Usage: check-antigravity.cjs SERVER MODEL TIMEOUT_SECONDS LOG_DIRECTORY');
  }
  fs.mkdirSync(logDirectory, { recursive: true });
  const nonce = crypto.randomBytes(8).toString('hex');
  const expected = `AGY_OK_${nonce}`;
  const logPath = path.join(logDirectory, `${new Date().toISOString().replace(/[:.]/g, '-')}-${nonce}.json`);
  const record = {
    startedAt: new Date().toISOString(), requestedModel: model, expectedResponse: expected,
    timeoutSeconds, serverPath, outcome: 'running',
  };
  const save = () => fs.writeFileSync(logPath, JSON.stringify(record, null, 2) + '\n', 'utf8');
  save();
  const client = connect(serverPath, (timeoutSeconds + 20) * 1000);
  let progress;
  const started = Date.now();
  console.log(`[AG] Model requested: ${model}; one plan-mode task; timeout ${timeoutSeconds}s`);
  console.log(`[AG] Unique challenge: ${expected}`);
  console.log(`[AG] Evidence log: ${logPath}`);
  try {
    record.initialization = await client.request('initialize', {
      protocolVersion: '2025-06-18', capabilities: {},
      clientInfo: { name: 'gemini-and-codex-live-check', version: '1.0.0' },
    });
    client.notify('notifications/initialized');
    record.cliCheck = await client.request('tools/call', { name: 'agy_check', arguments: {} });
    if (record.cliCheck.isError) throw new Error('agy CLI was not found');
    console.log(`[AG] ${record.cliCheck.content[0].text}`);
    record.request = {
      name: 'agy_delegate',
      arguments: {
        prompt: `Reply with exactly ${expected}. This is a connectivity check. Do not use tools, inspect or modify files, run commands, or delegate.`,
        cwd: path.dirname(path.dirname(__filename)), model, mode: 'plan',
        outputFormat: 'json', timeoutSeconds,
      },
    };
    save();
    progress = setInterval(() => console.log(`[AG] Waiting for CLI response... ${Math.round((Date.now() - started) / 1000)}s`), 5000);
    record.rawMcpResult = await client.request('tools/call', record.request);
    save();
    record.antigravity = validateEnvelope(record.rawMcpResult, expected);
    record.outcome = 'passed';
    console.log(`[AG] Actual reply: ${record.antigravity.response.trim()}`);
    console.log(`[AG] Conversation: ${record.antigravity.conversation_id || 'not supplied'}`);
    console.log(`[AG] Duration: ${record.antigravity.duration_seconds ?? 'not supplied'}s`);
    console.log(`[AG] CLI-reported usage: ${JSON.stringify(record.antigravity.usage || null)}`);
    console.log('[AG] PASS: received the unique challenge through MCP -> agy -> model.');
  } catch (error) {
    record.outcome = 'failed';
    record.error = error.message;
    console.error(`[AG] FAIL: ${error.message}`);
    process.exitCode = 1;
  } finally {
    clearInterval(progress);
    record.finishedAt = new Date().toISOString();
    record.elapsedSeconds = (Date.now() - started) / 1000;
    record.mcpStderr = client.stderr;
    client.close();
    save();
  }
}
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { validateEnvelope };
