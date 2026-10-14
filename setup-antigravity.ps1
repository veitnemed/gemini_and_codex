[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Enable', 'Disable', 'Status', 'Test', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$CodexDirectory = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [ValidateRange(60, 1800)]
    [int]$TimeoutSeconds = 300,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string]$LowModel = 'gemini-3.8-flash-low',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string]$HighModel = 'gemini-3.8-flash-high',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string]$Model = 'gemini-3.8-flash-low'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('Model')) {
    if (-not $PSBoundParameters.ContainsKey('LowModel')) {
        $LowModel = $Model
    }
} else {
    $Model = $LowModel
}
$upstreamUrl = 'https://github.com/IlleJiViN/codex-antigravity-subagent.git'
$upstreamCommit = '712480f2e0a744807fc59f1899812b4725289d92'
$serverName = 'antigravity_delegate'
$configBegin = '# >>> gemini-and-codex managed MCP >>>'
$configEnd = '# <<< gemini-and-codex managed MCP <<<'
$promptBegin = '<!-- >>> gemini-and-codex delegation >>> -->'
$promptEnd = '<!-- <<< gemini-and-codex delegation <<< -->'
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$CodexDirectory = [IO.Path]::GetFullPath($CodexDirectory)
$configPath = Join-Path $CodexDirectory 'config.toml'
$agentsPath = Join-Path $CodexDirectory 'AGENTS.md'
$overridePath = Join-Path $CodexDirectory 'AGENTS.override.md'
$bridgePath = Join-Path $CodexDirectory "tools\antigravity-bridge\$upstreamCommit"
$serverPath = Join-Path $bridgePath 'plugins\antigravity-subagent\mcp\dist\server.cjs'

function Read-Text([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [IO.File]::ReadAllText($Path, $utf8) }
    return ''
}

function Remove-Managed([string]$Text, [string]$Begin, [string]$End, [bool]$LeadingSeparator = $false) {
    $begins = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($Begin) + '\r?$').Count
    $ends = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($End) + '\r?$').Count
    if ($begins -ne $ends -or $begins -gt 1) { throw "Invalid or duplicate managed markers: $Begin" }
    if ($begins -eq 0) { return $Text }
    $pattern = '(?ms)^' + [regex]::Escape($Begin) + '\r?\n.*?^' + [regex]::Escape($End) + '(?:\r?\n|$)'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { throw "Invalid managed block: $Begin" }
    if ($LeadingSeparator -and $match.Index -ge 2 -and $Text.Substring($match.Index - 2, 2) -eq "`r`n") {
        return $Text.Remove($match.Index - 2, $match.Length + 2)
    }
    return $Text.Remove($match.Index, $match.Length)
}

function Find-Executable([string]$Name) {
    $found = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    if ($Name -eq 'agy') {
        $candidate = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if ($Name -eq 'codex') {
        $extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
        if (Test-Path -LiteralPath $extensionRoot) {
            $candidate = Get-ChildItem -LiteralPath $extensionRoot -Directory -Filter 'openai.chatgpt-*' |
                Sort-Object LastWriteTime -Descending | ForEach-Object {
                    foreach ($arch in @('windows-x86_64', 'windows-aarch64')) {
                        $binary = Join-Path $_.FullName "bin\$arch\codex.exe"
                        if (Test-Path -LiteralPath $binary -PathType Leaf) { $binary }
                    }
                } | Select-Object -First 1
            if ($candidate) { return $candidate }
        }
    }
    return $null
}

function Run-Checked([string]$Executable, [string[]]$Arguments) {
    if ([IO.Path]::GetFileNameWithoutExtension($Executable) -eq 'git') {
        $Arguments = @('-c', 'core.longpaths=true') + $Arguments
    }
    # Windows PowerShell represents native stderr as ErrorRecords even when
    # the command succeeds. Check the process exit code instead.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = & $Executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "Command failed ($exitCode): $Executable $($Arguments -join ' ')`n$($result -join "`n")" }
    return ($result -join "`n")
}

function Toml-String([string]$Value) {
    if ($Value -match '[\r\n\x00-\x1f]') { throw 'A TOML value contains control characters.' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

$configOriginal = Read-Text $configPath
$agentsOriginal = Read-Text $agentsPath
$overrideOriginal = Read-Text $overridePath
# Update the effective global instructions. Also clean an old managed block if
# the user switched between AGENTS.md and AGENTS.override.md after installation.
$effectivePromptPath = $agentsPath
if (-not [string]::IsNullOrWhiteSpace($overrideOriginal)) { $effectivePromptPath = $overridePath }
$configClean = Remove-Managed $configOriginal $configBegin $configEnd $true
$agentsClean = Remove-Managed $agentsOriginal $promptBegin $promptEnd
$overrideClean = Remove-Managed $overrideOriginal $promptBegin $promptEnd
if ($configClean -match '(?m)^\s*\[\s*mcp_servers\.antigravity_delegate(?:\.|\s*\])') {
    throw 'An unmanaged antigravity_delegate table already exists. Rename it or review it before installation.'
}

if ($Action -eq 'Status') {
    $configBlock = if ($configOriginal.Contains($configBegin)) {
        $start = $configOriginal.IndexOf($configBegin)
        $finish = $configOriginal.IndexOf($configEnd, $start)
        $configOriginal.Substring($start, $finish - $start)
    } else { '' }
    $effectiveText = if ($effectivePromptPath -eq $overridePath) { $overrideOriginal } else { $agentsOriginal }
    [pscustomobject]@{
        CodexDirectory = $CodexDirectory
        Registered = $configBlock.Contains("[mcp_servers.$serverName]")
        Enabled = ($configBlock -match '(?m)^enabled = true\r?$')
        InstructionsInstalled = $effectiveText.Contains($promptBegin)
        BridgePresent = (Test-Path -LiteralPath $serverPath -PathType Leaf)
        EffectiveInstructions = $effectivePromptPath
        Node = Find-Executable 'node'
        Codex = Find-Executable 'codex'
        Antigravity = Find-Executable 'agy'
    }
    return
}

$nodePath = Find-Executable 'node'
$agyPath = Find-Executable 'agy'
$codexPath = Find-Executable 'codex'
$gitPath = Find-Executable 'git'
if ($Action -eq 'Test') {
    if (-not $nodePath) { throw 'Node.js is missing.' }
    $managedStart = $configOriginal.IndexOf($configBegin)
    if ($managedStart -lt 0) { throw 'Install the managed bridge first.' }
    $managedEnd = $configOriginal.IndexOf($configEnd, $managedStart)
    $managedSettings = $configOriginal.Substring($managedStart, $managedEnd - $managedStart)
    if ($managedSettings -notmatch '(?m)^enabled = true\r?$') { throw 'The managed bridge is disabled. Enable it first.' }
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { throw 'The managed bridge is missing.' }
    if ($PSCmdlet.ShouldProcess('Antigravity CLI through MCP', "One live read-only check with $Model (max 120 seconds)")) {
        & $nodePath (Join-Path $PSScriptRoot 'scripts\check-antigravity.cjs') $serverPath $Model ([Math]::Min($TimeoutSeconds, 120)) (Join-Path $PSScriptRoot 'logs')
        if ($LASTEXITCODE -ne 0) { throw 'Antigravity verification failed. See the diagnostic output and JSON log.' }
    }
    return
}
if ($Action -in @('Install', 'Enable')) {
    $missing = @()
    foreach ($entry in @(@('Node.js >=20', $nodePath), @('Codex CLI or its VS Code extension', $codexPath), @('Antigravity CLI (agy)', $agyPath))) {
        if (-not $entry[1]) { $missing += $entry[0] }
    }
    if ($Action -eq 'Install' -and -not $gitPath) { $missing += 'Git' }
    if ($missing.Count) { throw "Install these prerequisites first: $($missing -join ', '). See README.md." }
    $nodeVersion = Run-Checked $nodePath @('--version')
    if ($nodeVersion -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 20) { throw 'Node.js 20 or newer is required.' }
    if ($Action -eq 'Enable' -and -not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        throw 'Bridge is missing. Run -Action Install first.'
    }
}
if ($Action -eq 'Disable' -and -not $configOriginal.Contains($configBegin)) {
    throw 'No managed installation found. Run -Action Install first.'
}

$changes = [ordered]@{}
if ($Action -eq 'Uninstall') {
    $changes[$configPath] = $configClean
    $changes[$agentsPath] = $agentsClean
    $changes[$overridePath] = $overrideClean
} else {
    if (-not $nodePath) { throw 'Node.js is required to keep a valid MCP command. Use Uninstall to remove the configuration.' }
    $enabledText = if ($Action -eq 'Disable') { 'false' } else { 'true' }
    $block = @"
$configBegin
[mcp_servers.$serverName]
command = $(Toml-String $nodePath)
args = [$(Toml-String $serverPath)]
enabled = $enabledText
startup_timeout_sec = 20
tool_timeout_sec = $($TimeoutSeconds + 30)
$configEnd
"@
    # Tables must follow the original root keys. The leading separator belongs
    # to our block so uninstall can preserve even a missing final newline.
    $changes[$configPath] = $configClean + "`r`n" + $block + "`r`n"
    $changes[$agentsPath] = $agentsClean
    $changes[$overridePath] = $overrideClean
    if ($Action -ne 'Disable') {
        $prompt = @"
$promptBegin
## Strict Antigravity Supervisor Mode

Codex is the supervisor / orchestrator; Gemini (via Antigravity) is the implementation
owner. Codex assigns tasks, evaluates Gemini's reports, and directs follow-ups.
Codex must NOT perform routine project investigation, file editing, implementation,
or testing itself instead of Gemini. Strict orchestrator mode applies: delegate even
initial project discovery, investigation, and all substantive tasks to Gemini.
The user explicitly overrides any legacy policy of merely delegating suitable chunks.

When MCP agy_delegate is available:
- Call agy_check before the first delegation.
- Model selection: use $LowModel for all mechanical commands, Git operations, file
  operations, and fast bounded tasks; use $HighModel strictly for substantive reasoning,
  system design, or complex multi-file refactoring. Named reasoning levels are selected
  strictly through model name variants (e.g. -low, -high); never invent parameters for
  agy_delegate, which only accepts model, mode, outputFormat, timeoutSeconds, cwd, prompt, agent.
- Decomposition & Scope: one Antigravity delegation = one bounded logical operation,
  typically 1-3 tool calls. Decompose release and workflow phases into separate steps,
  inspect results between phases, and never give a whole multi-stage release or workflow
  in a single prompt.
- Execution mode: mode=plan is execution mode for analysis, research, file discovery,
  and proposals without edits (not a model or reasoning level); mode=accept-edits is
  for implementation and file modifications already authorized by the user.
- Delegation parameters: set outputFormat=json, pass the workspace cwd, clear task scope,
  relevant project instructions, permitted files, acceptance criteria, and an explicit
  prohibition on further delegation. For timeoutSeconds, use short bounded local timeouts
  and >=300s for network or large analysis tasks as needed (MCP timeoutSeconds must be
  in the range 1..1800; zero is unsupported, never pretend timeouts can be unlimited).
- Request concise reports: normally up to 5 bullets plus concrete evidence.
- No concurrent edits: never allow two agents to modify the same files concurrently.
- Narrow technical exception: only if Gemini demonstrably cannot execute a technical action
  (e.g. headless shell command denied), Codex may perform that narrow action and must
  explicitly explain the limitation. No silent fallback to doing a failed task itself.
- Economy & Retries: send only necessary context, batch independent queries, and reuse
  collected evidence. Avoid re-doing Gemini's full investigation; verify key evidence
  and run targeted checks. If a delegation fails, retry at most once when there is a
  concrete fix; otherwise report the blocker.
- Reporting: before each delegation, briefly state the task and chosen model to the user.
  Afterward report actual tool calls and task count vs retries, completed/failed status,
  and duration when supplied by the tool. Empty output, denied actions, or incomplete
  work are failures even with SUCCESS. Never invent CLI results, usage, or savings.
- Learning constraints: preserve user intellectual work in educational projects; Gemini
  must not solve or disclose exercises contrary to project rules.

When agy_delegate is unavailable or disabled:
- Report that execution is unavailable. Do NOT silently launch agy through shell commands
  and do NOT perform project investigation, editing, implementation, or testing directly.
  Codex may still converse and analyze information already provided in context.

Project instructions and user requests take precedence.
$promptEnd
"@
        $cleanPrompt = if ($effectivePromptPath -eq $overridePath) { $overrideClean } else { $agentsClean }
        $changes[$effectivePromptPath] = $prompt + "`r`n" + $cleanPrompt
    }
}

if (-not $PSCmdlet.ShouldProcess($CodexDirectory, "$Action Antigravity delegation (pinned bridge, MCP configuration and global instructions)")) { return }

if ($Action -eq 'Install') {
    if (-not (Test-Path -LiteralPath $bridgePath)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bridgePath) | Out-Null
        Write-Host "Downloading bridge commit $upstreamCommit..."
        # Prevent Git progress on stderr from becoming a terminating PS5 error.
        Run-Checked $gitPath @('clone', '--quiet', '--no-checkout', $upstreamUrl, $bridgePath) | Out-Null
    }
    $origin = Run-Checked $gitPath @('-C', $bridgePath, 'remote', 'get-url', 'origin')
    if ($origin.Trim() -ne $upstreamUrl) { throw 'Existing bridge directory has a different Git origin.' }
    $dirty = Run-Checked $gitPath @('-C', $bridgePath, 'status', '--porcelain')
    $head = & $gitPath -C $bridgePath rev-parse HEAD 2>$null
    # A fresh --no-checkout clone appears dirty; only checkout when the bundle
    # is absent. Never overwrite an already installed modified working tree.
    if ((Test-Path -LiteralPath $serverPath) -and $dirty) { throw 'Bridge has local changes. They will not be overwritten.' }
    if (Test-Path -LiteralPath $serverPath) {
        if ($head.Trim() -ne $upstreamCommit) { throw 'Installed bridge commit differs from the pinned version.' }
    } else {
        if (Test-Path -LiteralPath (Join-Path $bridgePath 'README.md')) { throw 'Existing checkout is incomplete; inspect it before retrying.' }
        Run-Checked $gitPath @('-C', $bridgePath, 'checkout', '--quiet', '--detach', $upstreamCommit) | Out-Null
    }
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { throw 'The upstream bundle is missing.' }
    Run-Checked $nodePath @('--check', $serverPath) | Out-Null
}

$pending = @($changes.Keys | Where-Object { (Read-Text $_) -cne $changes[$_] })
if (-not $pending.Count) { Write-Host 'Already configured. No files changed.'; return }
foreach ($originalEntry in @(@($configPath, $configOriginal), @($agentsPath, $agentsOriginal), @($overridePath, $overrideOriginal))) {
    if ((Read-Text $originalEntry[0]) -cne $originalEntry[1]) { throw 'Settings changed during setup. Retry to avoid overwriting another edit.' }
}
New-Item -ItemType Directory -Force -Path $CodexDirectory | Out-Null
$backupDirectory = Join-Path $CodexDirectory ('backups\antigravity-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
$restore = @()
foreach ($target in $pending) {
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    $backup = Join-Path $backupDirectory ([IO.Path]::GetFileName($target))
    if ($exists) { Copy-Item -LiteralPath $target -Destination $backup }
    $restore += [pscustomobject]@{ Path = $target; Existed = $exists; Backup = $backup }
}
$restore | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDirectory 'restore.json') -Encoding UTF8
$writtenPaths = New-Object 'System.Collections.Generic.List[string]'
try {
    foreach ($target in $pending) {
        $stage = $target + '.antigravity-' + [guid]::NewGuid().ToString('N') + '.tmp'
        $replaceBackup = $stage + '.previous'
        try {
            $writeEncoding = $utf8
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $oldBytes = [IO.File]::ReadAllBytes($target)
                if ($oldBytes.Length -ge 3 -and $oldBytes[0] -eq 239 -and $oldBytes[1] -eq 187 -and $oldBytes[2] -eq 191) {
                    $writeEncoding = New-Object System.Text.UTF8Encoding($true, $true)
                }
            }
            [IO.File]::WriteAllText($stage, $changes[$target], $writeEncoding)
            if (Test-Path -LiteralPath $target) { [IO.File]::Replace($stage, $target, $replaceBackup) }
            else { [IO.File]::Move($stage, $target) }
            $writtenPaths.Add($target)
        } finally {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage }
            if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup }
        }
    }
} catch {
    foreach ($entry in $restore) {
        if (-not $writtenPaths.Contains($entry.Path)) { continue }
        if ($entry.Existed) { Copy-Item -LiteralPath $entry.Backup -Destination $entry.Path -Force }
        elseif (Test-Path -LiteralPath $entry.Path) { Remove-Item -LiteralPath $entry.Path }
    }
    throw
}
Write-Host "$Action complete. Backup: $backupDirectory"
Write-Host 'Restart the Codex extension (or CLI) and open a new chat to apply the change.'
Write-Host 'No agent task was launched. Google sign-in and task permissions remain local to Antigravity.'
