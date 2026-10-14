[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'setup-antigravity.ps1'
$runDirectory = Join-Path $repoRoot ('.test-runs\offline-' + [guid]::NewGuid().ToString('N'))
$testCodex = Join-Path $runDirectory 'Codex Home'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$upstreamCommit = '712480f2e0a744807fc59f1899812b4725289d92'

New-Item -ItemType Directory -Force -Path $testCodex | Out-Null

# Create mock bridge directory and bundle so Enable/Status/Uninstall work completely offline
$mockBridgeDir = Join-Path $testCodex "tools\antigravity-bridge\$upstreamCommit\plugins\antigravity-subagent\mcp\dist"
New-Item -ItemType Directory -Force -Path $mockBridgeDir | Out-Null
$mockServer = Join-Path $mockBridgeDir 'server.cjs'
[IO.File]::WriteAllText($mockServer, '// mock server bundle', $utf8)

$configFile = Join-Path $testCodex 'config.toml'
$agentsFile = Join-Path $testCodex 'AGENTS.md'
$overrideFile = Join-Path $testCodex 'AGENTS.override.md'

$originalConfig = 'model = "test-model"' + "`r`n" + '[custom_section]' + "`r`n" + 'key = "value"'
$originalAgents = '# Existing project rules' + "`r`n" + '- Preserve educational restrictions: do not solve exercises for students.'
[IO.File]::WriteAllText($configFile, $originalConfig, $utf8)
[IO.File]::WriteAllText($agentsFile, $originalAgents, $utf8)

$origConfigBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
$origAgentsBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

try {
    # 1. Test parameter validation for invalid model names
    $badLowFailed = $false
    try { & $installer -Action Enable -CodexDirectory $testCodex -LowModel 'bad model with spaces' } catch { $badLowFailed = $true }
    Assert-True $badLowFailed 'Validation rejects invalid LowModel with spaces'

    $badHighFailed = $false
    try { & $installer -Action Enable -CodexDirectory $testCodex -HighModel 'bad$high' } catch { $badHighFailed = $true }
    Assert-True $badHighFailed 'Validation rejects invalid HighModel'

    $badModelFailed = $false
    try { & $installer -Action Enable -CodexDirectory $testCodex -Model '@bad-model' } catch { $badModelFailed = $true }
    Assert-True $badModelFailed 'Validation rejects invalid legacy Model'

    # 2. Test default policy generation (Enable with defaults)
    & $installer -Action Enable -CodexDirectory $testCodex
    $status = & $installer -Action Status -CodexDirectory $testCodex
    Assert-True ($status.Enabled -and $status.InstructionsInstalled) 'Default installation enables MCP and installs policy'

    $policy = [IO.File]::ReadAllText($agentsFile)

    # Check strict supervisor / implementation owner
    Assert-True ($policy.Contains('Strict Antigravity Supervisor Mode')) 'Policy contains header Strict Antigravity Supervisor Mode'
    Assert-True ($policy -match 'Codex is the supervisor' -and $policy -match 'implementation\s+owner') 'Policy defines Codex as supervisor and Gemini as implementation owner'
    Assert-True ($policy -match 'Codex must NOT perform routine project investigation,\s*file editing,\s*implementation,\s*or testing') 'Policy forbids Codex from routine investigation, editing, implementation, or testing'
    Assert-True ($policy -match 'Strict orchestrator mode applies:\s*delegate even\s*initial project discovery') 'Policy mandates delegating initial discovery and substantive tasks'

    # Check model defaults and reasoning levels
    Assert-True ($policy.Contains('gemini-3.8-flash-low')) 'Policy exposes gemini-3.8-flash-low default for fast/bounded tasks'
    Assert-True ($policy.Contains('gemini-3.8-flash-high')) 'Policy exposes gemini-3.8-flash-high default for serious tasks'
    Assert-True ($policy -match 'Model selection:\s*use\s+\S+\s+for all mechanical commands[\s\S]*?use\s+\S+\s+strictly for substantive reasoning') 'Policy enforces Low-for-mechanical and High-for-reasoning rule'
    Assert-True ($policy -match 'Named\s+reasoning\s+levels\s+are\s+selected\s+strictly\s+through\s+model\s+name\s+variants[\s\S]*?never\s+invent\s+parameters\s+for\s+agy_delegate') 'Policy clarifies reasoning levels use model variants without inventing MCP flags'
    Assert-True ($policy -match 'agy_delegate,\s*which only accepts model,\s*mode,\s*outputFormat,\s*timeoutSeconds,\s*cwd,\s*prompt,\s*agent') 'Policy restricts delegation parameters to supported MCP arguments'

    # Check atomic operations / decomposition
    Assert-True ($policy -match 'Decomposition & Scope:\s*one Antigravity delegation\s*=\s*one bounded logical operation') 'Policy enforces atomic-operation decomposition'

    # Check execution modes
    Assert-True ($policy -match 'mode=plan is execution mode for analysis,\s*research,\s*file discovery[\s\S]*?not a model or reasoning level') 'Policy defines mode=plan as execution mode for analysis/proposals without edits'
    Assert-True ($policy -match 'mode=accept-edits is\s+for implementation and file modifications') 'Policy defines mode=accept-edits for authorized modifications'

    # Check narrow technical exception & no silent fallback
    Assert-True ($policy -match 'only if Gemini demonstrably cannot execute a technical action[\s\S]*?No silent fallback') 'Policy restricts Codex actions to narrow demonstrable blockers with no silent fallback'

    # Check offline / disabled MCP behavior
    Assert-True ($policy -match 'When agy_delegate is unavailable or disabled:[\s\S]*?Report that execution is unavailable') 'Policy directs supervisor to report execution unavailable when MCP is off'
    Assert-True ($policy -match 'Do NOT silently launch agy through shell commands[\s\S]*?do NOT perform project investigation') 'Policy forbids supervisor shell launch or manual takeover when MCP is off'

    # Check reporting and learning constraints
    Assert-True ($policy -match 'actual tool calls and task count vs retries[\s\S]*?duration when supplied') 'Policy requires reporting tool calls, task counts vs retries, and duration'
    Assert-True ($policy -match 'preserve user intellectual work in educational projects[\s\S]*?must not solve or disclose exercises') 'Policy preserves educational and learning constraints'

    # Check original user rules preserved
    Assert-True ($policy.EndsWith($originalAgents)) 'Original user instructions are preserved at the end of AGENTS.md'

    # 3. Test legacy -Model backwards compatibility
    & $installer -Action Enable -CodexDirectory $testCodex -Model 'legacy-fallback-model'
    $legacyPolicy = [IO.File]::ReadAllText($agentsFile)
    Assert-True ($legacyPolicy.Contains('legacy-fallback-model')) 'Legacy -Model overrides low model in generated policy'
    Assert-True ($legacyPolicy.Contains('gemini-3.8-flash-high')) 'Legacy -Model preserves default high model'
    Assert-True ($legacyPolicy.EndsWith($originalAgents)) 'Original user rules preserved under -Model'

    # 4. Test explicit LowModel and HighModel
    & $installer -Action Enable -CodexDirectory $testCodex -LowModel 'my-fast-agent' -HighModel 'my-deep-agent'
    $customPolicy = [IO.File]::ReadAllText($agentsFile)
    Assert-True ($customPolicy.Contains('my-fast-agent') -and $customPolicy.Contains('my-deep-agent')) 'Explicit LowModel and HighModel are written into policy'
    Assert-True ($customPolicy.EndsWith($originalAgents)) 'Original user rules preserved under explicit LowModel and HighModel'

    # 5. Test Disable removes managed policy and restores exact original file
    & $installer -Action Disable -CodexDirectory $testCodex
    $disabledStatus = & $installer -Action Status -CodexDirectory $testCodex
    Assert-True (-not $disabledStatus.Enabled -and -not $disabledStatus.InstructionsInstalled) 'Disable deactivates MCP and removes instructions'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile)) -ceq $origAgentsBytes) 'Disable restores exact original AGENTS.md bytes'

    # 6. Test Uninstall restores exact original files
    & $installer -Action Uninstall -CodexDirectory $testCodex
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq $origConfigBytes) 'Uninstall restores exact original config.toml bytes'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile)) -ceq $origAgentsBytes) 'Uninstall restores exact original AGENTS.md bytes'

    Write-Host 'All offline policy tests PASSED successfully.'
} finally {
    if (Test-Path -LiteralPath $runDirectory) {
        $resolvedRepo = [System.IO.Path]::GetFullPath($repoRoot)
        $testRunsRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepo '.test-runs'))
        $resolvedRunDir = [System.IO.Path]::GetFullPath($runDirectory)
        $prefix = $testRunsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

        if ($resolvedRunDir.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            $resolvedRunDir -ne $testRunsRoot) {
            Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

