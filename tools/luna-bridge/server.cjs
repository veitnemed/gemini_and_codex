#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

function sanitizeSecrets(text) {
  if (typeof text !== 'string') return '';
  return text
    .replace(/(bearer\s+)[A-Za-z0-9._~+/-]+=*/gi, '$1[REDACTED]')
    .replace(/\b(sk-[A-Za-z0-9_-]{20,})\b/gi, '[REDACTED]')
    .replace(/\b(sess-[A-Za-z0-9_-]{20,})\b/gi, '[REDACTED]')
    .replace(/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]+\b/gi, '[REDACTED_JWT]')
    .replace(/\b[A-Fa-f0-9]{32,64}\b/g, '[REDACTED_HEX]');
}

function findCodexBinary() {
  if (process.env.CODEX_CLI_PATH) {
    const customPath = path.resolve(process.env.CODEX_CLI_PATH);
    if (fs.existsSync(customPath)) {
      return customPath;
    }
    if (process.platform === 'win32') {
      const extensions = (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';').filter(Boolean);
      for (const ext of extensions) {
        const candidate = customPath.endsWith(ext.toLowerCase()) || customPath.endsWith(ext.toUpperCase())
          ? customPath
          : customPath + ext.toLowerCase();
        if (fs.existsSync(candidate)) return candidate;
      }
    }
  }

  const isWin = process.platform === 'win32';
  const pathEnv = process.env.PATH || '';
  const dirs = pathEnv.split(path.delimiter).map(d => d.trim().replace(/^["']|["']$/g, '')).filter(Boolean);

  const extensions = isWin
    ? (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';').map(e => e.trim().toLowerCase()).filter(Boolean)
    : [''];

  for (const dir of dirs) {
    if (isWin) {
      for (const ext of extensions) {
        const candidate = path.join(dir, `codex${ext.startsWith('.') ? ext : '.' + ext}`);
        if (fs.existsSync(candidate)) {
          return candidate;
        }
      }
    }
    const direct = path.join(dir, 'codex');
    if (fs.existsSync(direct)) {
      return direct;
    }
  }

  return null;
}

function handleLunaCheck() {
  const binaryPath = findCodexBinary();
  if (!binaryPath) {
    return {
      content: [{
        type: 'text',
        text: 'Codex CLI binary not found in PATH or CODEX_CLI_PATH.'
      }],
      structuredContent: {
        binary: {
          found: false,
          path: null,
          version: null,
          error: 'Not found in PATH or CODEX_CLI_PATH'
        },
        auth: {
          checked: false,
          loggedIn: false,
          status: null,
          error: 'Codex CLI not available'
        }
      },
      isError: true
    };
  }

  let versionText = '';
  let versionError = null;
  try {
    const spawnOptions = {
      encoding: 'utf8',
      timeout: 10000,
      windowsHide: true,
      env: process.env
    };
    if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(binaryPath)) {
      spawnOptions.shell = true;
    }
    const vRes = spawnSync(binaryPath, ['--version'], spawnOptions);
    if (vRes.error) {
      versionError = vRes.error.message;
    } else if (vRes.status !== 0) {
      versionError = `Exit code ${vRes.status}: ${sanitizeSecrets((vRes.stderr || vRes.stdout || '').trim())}`;
    } else {
      versionText = sanitizeSecrets((vRes.stdout || '').trim());
    }
  } catch (err) {
    versionError = err.message;
  }

  let authStatusText = '';
  let authError = null;
  let loggedIn = false;
  try {
    const spawnOptions = {
      encoding: 'utf8',
      timeout: 10000,
      windowsHide: true,
      env: process.env
    };
    if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(binaryPath)) {
      spawnOptions.shell = true;
    }
    const aRes = spawnSync(binaryPath, ['login', 'status'], spawnOptions);
    const rawOutput = ((aRes.stdout || '') + (aRes.stderr || '')).trim();
    const sanitizedOutput = sanitizeSecrets(rawOutput);
    if (aRes.error) {
      authError = aRes.error.message;
    } else {
      authStatusText = sanitizedOutput;
      loggedIn = aRes.status === 0 && !/not logged in/i.test(sanitizedOutput);
      if (aRes.status !== 0) {
        authError = `Exit code ${aRes.status}: ${sanitizedOutput}`;
      }
    }
  } catch (err) {
    authError = err.message;
  }

  const isError = Boolean(versionError || authError || !loggedIn);
  const summaryText = [
    `Codex binary: ${binaryPath}`,
    `Version: ${versionText || `ERROR: ${versionError}`}`,
    `Auth status: ${authStatusText || `ERROR: ${authError}`}`
  ].join('\n');

  return {
    content: [{
      type: 'text',
      text: summaryText
    }],
    structuredContent: {
      binary: {
        found: true,
        path: binaryPath,
        version: versionText || null,
        error: versionError
      },
      auth: {
        checked: true,
        loggedIn,
        status: authStatusText || null,
        error: authError
      }
    },
    isError
  };
}

function killProcessTree(pid) {
  if (!pid) return;
  if (process.platform === 'win32') {
    try {
      spawnSync('taskkill', ['/pid', String(pid), '/T', '/F'], {
        windowsHide: true,
        stdio: 'ignore'
      });
    } catch (_) {}
  }
  try {
    process.kill(pid, 'SIGKILL');
  } catch (_) {}
}

let isExecuting = false;

async function handleLunaDelegate(args) {
  if (isExecuting) {
    return {
      content: [{
        type: 'text',
        text: 'Error: Concurrent Luna execution is prohibited. Another request is currently running.'
      }],
      structuredContent: {
        exitCode: 1,
        timedOut: false
      },
      isError: true
    };
  }

  isExecuting = true;
  try {
    return await executeLuna(args);
  } finally {
    isExecuting = false;
  }
}

async function executeLuna(args) {
  if (process.env.LUNA_BRIDGE_ACTIVE === '1') {
    return {
      content: [{
        type: 'text',
        text: 'Error: Recursive Luna delegation detected via LUNA_BRIDGE_ACTIVE environment marker.'
      }],
      structuredContent: {
        exitCode: 1,
        timedOut: false
      },
      isError: true
    };
  }

  const prompt = args?.prompt;
  if (typeof prompt !== 'string' || !prompt.trim()) {
    return {
      content: [{
        type: 'text',
        text: 'Error: "prompt" must be a non-empty string.'
      }],
      structuredContent: {
        exitCode: 1,
        timedOut: false
      },
      isError: true
    };
  }

  const rawCwd = args?.cwd;
  if (typeof rawCwd !== 'string' || !rawCwd.trim()) {
    return {
      content: [{
        type: 'text',
        text: 'Error: "cwd" must be a non-empty string.'
      }],
      structuredContent: {
        exitCode: 1,
        timedOut: false
      },
      isError: true
    };
  }

  if (!path.isAbsolute(rawCwd)) {
    return {
      content: [{
        type: 'text',
        text: `Error: "cwd" must be an absolute path: "${rawCwd}".`
      }],
      structuredContent: {
        exitCode: 1,
        timedOut: false
      },
      isError: true
    };
  }

  const resolvedCwd = path.resolve(rawCwd);
  try {
    const stat = fs.statSync(resolvedCwd);
    if (!stat.isDirectory()) {
      return {
        content: [{
          type: 'text',
          text: `Error: "cwd" is not a directory: "${resolvedCwd}".`
        }],
        structuredContent: {
          exitCode: 1,
          timedOut: false
        },
        isError: true
      };
    }
  } catch (_) {
    return {
      content: [{
        type: 'text',
        text: `Error: "cwd" directory does not exist: "${resolvedCwd}".`
      }],
      structuredContent: {
        exitCode: 1,
        timedOut: false
      },
      isError: true
    };
  }

  let mode = 'plan';
  if (args?.mode !== undefined) {
    if (args.mode !== 'plan' && args.mode !== 'accept-edits') {
      return {
        content: [{
          type: 'text',
          text: `Error: "mode" must be either "plan" or "accept-edits" (received: ${JSON.stringify(args.mode)}).`
        }],
        structuredContent: {
          model: 'gpt-6-luna',
          effort: 'high',
          mode: String(args.mode),
          taskId: typeof args?.taskId === 'string' ? args.taskId : null,
          exitCode: 1,
          timedOut: false,
          durationSeconds: 0
        },
        isError: true
      };
    }
    mode = args.mode;
  }

  let reasoningEffort = 'high';
  if (args?.reasoningEffort !== undefined) {
    if (args.reasoningEffort !== 'high' && args.reasoningEffort !== 'max') {
      return {
        content: [{
          type: 'text',
          text: `Error: "reasoningEffort" must be either "high" or "max" (received: ${JSON.stringify(args.reasoningEffort)}).`
        }],
        structuredContent: {
          model: 'gpt-6-luna',
          effort: String(args.reasoningEffort),
          mode,
          taskId: typeof args?.taskId === 'string' ? args.taskId : null,
          exitCode: 1,
          timedOut: false,
          durationSeconds: 0
        },
        isError: true
      };
    }
    reasoningEffort = args.reasoningEffort;
  }

  let taskId = null;
  if (args?.taskId !== undefined) {
    if (typeof args.taskId !== 'string' || !args.taskId.trim()) {
      return {
        content: [{
          type: 'text',
          text: 'Error: "taskId" if provided must be a non-empty string.'
        }],
        structuredContent: {
          model: 'gpt-6-luna',
          effort: reasoningEffort,
          mode,
          taskId: null,
          exitCode: 1,
          timedOut: false,
          durationSeconds: 0
        },
        isError: true
      };
    }
    taskId = args.taskId.trim();
  }

  let timeoutSec = 300;
  if (args?.timeoutSeconds !== undefined) {
    const t = args.timeoutSeconds;
    if (typeof t !== 'number' || !Number.isInteger(t) || t < 1 || t > 1800) {
      return {
        content: [{
          type: 'text',
          text: `Error: "timeoutSeconds" must be an integer between 1 and 1800 (received: ${t}).`
        }],
        structuredContent: {
          model: 'gpt-6-luna',
          effort: reasoningEffort,
          mode,
          taskId,
          exitCode: 1,
          timedOut: false,
          durationSeconds: 0
        },
        isError: true
      };
    }
    timeoutSec = t;
  }

  const binaryPath = findCodexBinary();
  if (!binaryPath) {
    return {
      content: [{
        type: 'text',
        text: 'Error: Codex CLI binary not found in PATH or CODEX_CLI_PATH.'
      }],
      structuredContent: {
        model: 'gpt-6-luna',
        effort: reasoningEffort,
        mode,
        taskId,
        exitCode: 1,
        timedOut: false,
        durationSeconds: 0
      },
      isError: true
    };
  }

  const sandboxMode = mode === 'accept-edits' ? 'workspace-write' : 'read-only';

  const cliArgs = [
    'exec',
    '-m', 'gpt-6-luna',
    '-c', `model_reasoning_effort=${reasoningEffort}`,
    '--ignore-user-config',
    '-c', 'agents.enabled=false',
    '-c', 'approval_policy=never',
    '--sandbox', sandboxMode,
    '--ephemeral',
    '-'
  ];

  const childEnv = {
    ...process.env,
    LUNA_BRIDGE_ACTIVE: '1'
  };

  const workerPrompt = mode === 'accept-edits'
    ? `[Worker Instruction: You are operating as a terminal Luna worker via luna-bridge. You have a comprehensive multi-step task and may perform multiple steps, tool calls, and local workspace file edits to complete it. Do NOT attempt further delegation, and do NOT invoke Codex CLI or agy.]\n\n${prompt}`
    : `[Worker Instruction: You are operating as a terminal Luna worker via luna-bridge in read-only plan mode. You have a comprehensive multi-step task and may perform multiple analysis steps and tool calls to complete it, but file edits are prohibited. Do NOT attempt further delegation, and do NOT invoke Codex CLI or agy.]\n\n${prompt}`;

  const startTime = Date.now();

  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let settled = false;

    const spawnOptions = {
      cwd: resolvedCwd,
      env: childEnv,
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true
    };
    if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(binaryPath)) {
      spawnOptions.shell = true;
    }

    const child = spawn(binaryPath, cliArgs, spawnOptions);

    const timer = setTimeout(() => {
      timedOut = true;
      killProcessTree(child.pid);
    }, timeoutSec * 1000);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');

    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });

    child.stdin.on('error', () => {});

    try {
      child.stdin.end(workerPrompt, 'utf8');
    } catch (_) {}

    function finish(exitCode, err) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);

      const durationSeconds = Math.max(0, Math.round(((Date.now() - startTime) / 1000) * 100) / 100);
      const actualExitCode = exitCode !== null ? exitCode : (timedOut ? 1 : (err ? 1 : 0));
      const hasOutput = typeof stdout === 'string' && stdout.trim().length > 0;
      const isError = timedOut || actualExitCode !== 0 || Boolean(err) || !hasOutput;

      let outputText = '';
      if (isError) {
        const MAX_ERR_CHARS = 8000;
        let sanitizedErr = sanitizeSecrets(stderr || '').trim();
        if (sanitizedErr.length > MAX_ERR_CHARS) {
          sanitizedErr = sanitizedErr.slice(0, MAX_ERR_CHARS) + '\n... [truncated]';
        }

        if (timedOut) {
          outputText = `Error: Luna execution timed out after ${timeoutSec} seconds.`;
        } else if (err) {
          outputText = `Error launching Codex process: ${err.message}`;
        } else if (actualExitCode !== 0) {
          outputText = `Error: Codex execution failed with exit code ${actualExitCode}.`;
        } else if (!hasOutput) {
          outputText = 'Error: Codex execution returned empty output.';
        }

        if (sanitizedErr) {
          outputText += `\n\nCaptured stderr:\n${sanitizedErr}`;
        }
      } else {
        outputText = stdout;
      }

      resolve({
        content: [{
          type: 'text',
          text: outputText
        }],
        structuredContent: {
          model: 'gpt-6-luna',
          effort: reasoningEffort,
          mode,
          taskId,
          exitCode: actualExitCode,
          timedOut,
          durationSeconds
        },
        isError
      });
    }

    child.on('error', (err) => {
      finish(null, err);
    });

    child.on('close', (code) => {
      finish(code, null);
    });
  });
}

function sendResponse(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function sendResult(id, result) {
  sendResponse({ jsonrpc: '2.0', id, result });
}

function sendError(id, code, message, data) {
  sendResponse({
    jsonrpc: '2.0',
    id,
    error: {
      code,
      message,
      ...(data !== undefined ? { data } : {})
    }
  });
}

let inputBuffer = '';

async function handleLine(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (_) {
    sendError(null, -32700, 'Parse error');
    return;
  }

  if (!msg || typeof msg !== 'object') {
    sendError(null, -32600, 'Invalid Request');
    return;
  }

  const { id, method, params } = msg;

  if (id === undefined || id === null) {
    return;
  }

  try {
    if (method === 'initialize') {
      sendResult(id, {
        protocolVersion: params?.protocolVersion || '2024-11-05',
        capabilities: {
          tools: {}
        },
        serverInfo: {
          name: 'luna-bridge',
          version: '1.0.0'
        }
      });
      return;
    }

    if (method === 'ping') {
      sendResult(id, {});
      return;
    }

    if (method === 'tools/list') {
      sendResult(id, {
        tools: [
          {
            name: 'luna_check',
            description: 'Checks Codex CLI availability and login status without making model requests.',
            inputSchema: {
              type: 'object',
              properties: {},
              additionalProperties: false
            }
          },
          {
            name: 'luna_delegate',
            description: 'Executes codex exec with GPT-6 Luna in plan (read-only) or accept-edits (workspace-write) mode.',
            inputSchema: {
              type: 'object',
              properties: {
                prompt: {
                  type: 'string',
                  description: 'Instructions for the Luna model.'
                },
                cwd: {
                  type: 'string',
                  description: 'Existing absolute directory path.'
                },
                mode: {
                  type: 'string',
                  enum: ['plan', 'accept-edits'],
                  default: 'plan',
                  description: 'Execution mode: "plan" (read-only) or "accept-edits" (workspace-write).'
                },
                reasoningEffort: {
                  type: 'string',
                  enum: ['high', 'max'],
                  default: 'high',
                  description: 'Reasoning effort: "high" or "max".'
                },
                taskId: {
                  type: 'string',
                  description: 'Optional task identifier for reporting.'
                },
                timeoutSeconds: {
                  type: 'integer',
                  minimum: 1,
                  maximum: 1800,
                  default: 300,
                  description: 'Timeout in seconds (1..1800, default 300).'
                }
              },
              required: ['prompt', 'cwd'],
              additionalProperties: false
            }
          }
        ]
      });
      return;
    }

    if (method === 'tools/call') {
      const name = params?.name;
      const callArgs = params?.arguments || {};

      if (name === 'luna_check') {
        const res = handleLunaCheck();
        sendResult(id, res);
        return;
      }

      if (name === 'luna_delegate') {
        const res = await handleLunaDelegate(callArgs);
        sendResult(id, res);
        return;
      }

      sendResult(id, {
        content: [{ type: 'text', text: `Unknown tool: ${name}` }],
        isError: true
      });
      return;
    }

    sendError(id, -32601, `Method not found: ${method}`);
  } catch (err) {
    sendError(id, -32603, `Internal error: ${err.message}`);
  }
}

function startServer() {
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    inputBuffer += chunk;
    let newlineIdx;
    while ((newlineIdx = inputBuffer.indexOf('\n')) !== -1) {
      const line = inputBuffer.slice(0, newlineIdx).trim();
      inputBuffer = inputBuffer.slice(newlineIdx + 1);
      if (!line) continue;
      handleLine(line);
    }
  });

  process.stdin.on('end', () => {
    process.exit(0);
  });
}

if (require.main === module) {
  startServer();
}

module.exports = {
  findCodexBinary,
  sanitizeSecrets,
  handleLunaCheck,
  handleLunaDelegate,
  killProcessTree
};
