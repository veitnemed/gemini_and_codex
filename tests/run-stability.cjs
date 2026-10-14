const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { connect } = require('../scripts/mcp-client.cjs');
const { validateEnvelope } = require('../scripts/check-antigravity.cjs');

async function run() {
  const [bundlePath, reportDirectory] = process.argv.slice(2);
  if (!bundlePath || !reportDirectory) {
    console.error('Usage: node run-stability.cjs BUNDLE_PATH REPORT_DIRECTORY');
    process.exit(1);
  }

  const repoRoot = path.resolve(__dirname, '..');
  const resolvedReportDir = path.resolve(reportDirectory);
  fs.mkdirSync(resolvedReportDir, { recursive: true });

  const runsDir = path.join(repoRoot, '.test-runs');
  fs.mkdirSync(runsDir, { recursive: true });
  const fixtureDir = path.join(runsDir, `ag-stability-${crypto.randomBytes(6).toString('hex')}`);
  fs.mkdirSync(fixtureDir, { recursive: true });

  const lowModel = 'gemini-3.8-flash-low';
  const highModel = 'gemini-3.8-flash-high';
  const boundedTimeout = 120;
  const overallTimeoutMs = 550 * 1000;

  const runLogPath = path.join(resolvedReportDir, `stability-report-${Date.now()}.json`);
  const reportData = {
    startedAt: new Date().toISOString(),
    bundlePath,
    reportDirectory: resolvedReportDir,
    fixtureDir,
    cases: [],
    overallVerdict: 'running'
  };

  const saveReport = () => {
    fs.writeFileSync(runLogPath, JSON.stringify(reportData, null, 2) + '\n', 'utf8');
  };
  saveReport();

  const client = connect(bundlePath, overallTimeoutMs);
  let heartbeat;

  try {
    const initRes = await client.request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'gemini-stability-runner', version: '1.0.0' }
    });
    client.notify('notifications/initialized');
    reportData.initialization = initRes;

    const checkRes = await client.request('tools/call', { name: 'agy_check', arguments: {} });
    reportData.agyCheck = checkRes;
    if (checkRes.isError) {
      throw new Error('agy_check reported error: agy CLI not available');
    }

    const cases = [
      { id: 'A', name: 'Low plan exact random nonce', model: lowModel, mode: 'plan' },
      { id: 'B', name: 'Low plan reads unique UTF8 fixture', model: lowModel, mode: 'plan' },
      { id: 'C', name: 'Low accept-edits writes unique token', model: lowModel, mode: 'accept-edits' },
      { id: 'D', name: 'High plan exact random nonce', model: highModel, mode: 'plan' }
    ];

    let anyFailed = false;

    for (const testCase of cases) {
      const caseRecord = {
        id: testCase.id,
        name: testCase.name,
        startedAt: new Date().toISOString(),
        outcome: 'running'
      };
      reportData.cases.push(caseRecord);
      saveReport();

      console.log(`\n[STABILITY] Starting Case ${testCase.id}: ${testCase.name}`);
      const caseStarted = Date.now();
      if (heartbeat) clearInterval(heartbeat);
      heartbeat = setInterval(() => {
        const elapsed = Math.round((Date.now() - caseStarted) / 1000);
        console.log(`[STABILITY] Waiting on Case ${testCase.id}... ${elapsed}s`);
      }, 5000);

      try {
        let prompt = '';
        let expectedResponse = '';
        let extraVerify = null;

        if (testCase.id === 'A') {
          const nonce = crypto.randomBytes(8).toString('hex');
          expectedResponse = `NONCE_${nonce}`;
          prompt = `Reply with exactly ${expectedResponse}. Do not use tools, do not inspect or modify files, do not run shell commands, do not delegate or invoke subagents.`;
        } else if (testCase.id === 'B') {
          const fixtureFileName = `fixture-${crypto.randomBytes(6).toString('hex')}.txt`;
          const fixtureFilePath = path.join(fixtureDir, fixtureFileName);
          const fixtureContent = `FIXTURE_CONTENT_${crypto.randomBytes(12).toString('hex')}_ЖИВЕЙ`;
          fs.writeFileSync(fixtureFilePath, fixtureContent, 'utf8');
          expectedResponse = fixtureContent;
          prompt = `Read the UTF-8 text file located at "${fixtureFilePath}" using file tools. Reply with EXACTLY and ONLY the contents of this file. Do not write or modify any files, do not run commands, do not delegate or invoke subagents.`;
        } else if (testCase.id === 'C') {
          const outputFileName = `output-${crypto.randomBytes(6).toString('hex')}.txt`;
          const outputFilePath = path.join(fixtureDir, outputFileName);
          const tokenToWrite = `TOKEN_${crypto.randomBytes(10).toString('hex')}`;
          const ackToken = `ACK_${crypto.randomBytes(8).toString('hex')}`;
          expectedResponse = ackToken;
          prompt = `Write exactly the text "${tokenToWrite}" into the file located at "${outputFilePath}" using file tools. Do not run shell commands, do not delegate or invoke subagents. Once the file is written, reply with EXACTLY and ONLY "${ackToken}".`;
          extraVerify = () => {
            if (!fs.existsSync(outputFilePath)) {
              throw new Error(`Expected output file not found on disk: ${outputFilePath}`);
            }
            const actualDiskContent = fs.readFileSync(outputFilePath, 'utf8').trim();
            if (actualDiskContent !== tokenToWrite) {
              throw new Error(`File content mismatch: expected "${tokenToWrite}", found "${actualDiskContent}"`);
            }
          };
        } else if (testCase.id === 'D') {
          const nonce = crypto.randomBytes(8).toString('hex');
          expectedResponse = `HIGH_NONCE_${nonce}`;
          prompt = `Reply with exactly ${expectedResponse}. Do not use tools, do not inspect or modify files, do not run shell commands, do not delegate or invoke subagents.`;
        }

        const delegateArgs = {
          prompt,
          cwd: repoRoot,
          model: testCase.model,
          mode: testCase.mode,
          outputFormat: 'json',
          timeoutSeconds: boundedTimeout
        };

        caseRecord.request = { name: 'agy_delegate', arguments: delegateArgs };
        saveReport();

        const rawMcpResult = await client.request('tools/call', caseRecord.request);
        caseRecord.rawMcpResult = rawMcpResult;
        saveReport();

        const envelope = validateEnvelope(rawMcpResult, expectedResponse);
        caseRecord.envelope = envelope;
        caseRecord.duration = envelope.duration_seconds;
        caseRecord.usage = envelope.usage;

        if (extraVerify) {
          extraVerify();
        }

        caseRecord.outcome = 'passed';
        console.log(`[STABILITY] PASS Case ${testCase.id} (${envelope.duration_seconds ?? 'n/a'}s)`);
      } catch (caseErr) {
        anyFailed = true;
        caseRecord.outcome = 'failed';
        caseRecord.error = caseErr.message;
        console.error(`[STABILITY] FAIL Case ${testCase.id}: ${caseErr.message}`);
      } finally {
        if (heartbeat) clearInterval(heartbeat);
        caseRecord.elapsedSeconds = (Date.now() - caseStarted) / 1000;
        caseRecord.finishedAt = new Date().toISOString();
        saveReport();
      }
    }

    reportData.overallVerdict = anyFailed ? 'failed' : 'passed';
    if (anyFailed) {
      process.exitCode = 1;
    }
  } catch (globalErr) {
    reportData.overallVerdict = 'failed';
    reportData.globalError = globalErr.message;
    console.error(`[STABILITY] FATAL: ${globalErr.message}`);
    process.exitCode = 1;
  } finally {
    if (heartbeat) clearInterval(heartbeat);
    reportData.finishedAt = new Date().toISOString();
    reportData.mcpStderr = client.stderr;
    saveReport();
    client.close();
    console.log(`\n[STABILITY] Final Verdict: ${reportData.overallVerdict.toUpperCase()}`);
    console.log(`[STABILITY] Report Path: ${runLogPath}`);
    console.log(`[STABILITY] Fixture Directory preserved for inspection: ${fixtureDir}`);
  }
}

if (require.main === module) {
  run().catch(err => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { run };
