[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'setup-antigravity.ps1'
$runDirectory = Join-Path $repoRoot ('.test-runs\' + [guid]::NewGuid().ToString('N'))
$testCodex = Join-Path $runDirectory 'Codex home with spaces'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bomUtf8 = New-Object System.Text.UTF8Encoding($true)
New-Item -ItemType Directory -Force -Path $testCodex | Out-Null
$configFile = Join-Path $testCodex 'config.toml'
$agentsFile = Join-Path $testCodex 'AGENTS.md'
$overrideFile = Join-Path $testCodex 'AGENTS.override.md'
$originalConfig = 'model = "unchanged-model"' + "`r`n" + 'custom_note = """' + "`n" + '[mcp_servers.text_inside_string]' + "`n" + '"""' + "`r`n" + '[mcp_servers.existing]' + "`r`n" + 'command = "keep-me"'
$originalAgents = '# Existing rules' + "`r`n" + '- Keep the learning restrictions.'
[IO.File]::WriteAllText($configFile, $originalConfig, $bomUtf8)
[IO.File]::WriteAllText($agentsFile, $originalAgents, $utf8)
$originalConfigBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
$originalAgentsBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

& $installer -Action Install -CodexDirectory $testCodex -WhatIf
Assert-True (-not (Test-Path -LiteralPath (Join-Path $testCodex 'tools'))) 'WhatIf creates no download directory'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq $originalConfigBytes) 'WhatIf preserves configuration bytes'

& $installer -Action Install -CodexDirectory $testCodex
$status = & $installer -Action Status -CodexDirectory $testCodex
Assert-True ($status.Registered -and $status.Enabled -and $status.InstructionsInstalled -and $status.BridgePresent) 'Installation is enabled and complete'
$installedConfig = [IO.File]::ReadAllText($configFile)
Assert-True ($installedConfig.StartsWith($originalConfig)) 'Original TOML root keys and multiline string stay before new table'
Assert-True ([IO.File]::ReadAllText($agentsFile).EndsWith($originalAgents)) 'Original instructions are preserved'
$firstConfigBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
$firstAgentsBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile))
$backupCount = @(Get-ChildItem -LiteralPath (Join-Path $testCodex 'backups') -Directory).Count
& $installer -Action Install -CodexDirectory $testCodex
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq $firstConfigBytes) 'Repeated install leaves configuration identical'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile)) -ceq $firstAgentsBytes) 'Repeated install leaves instructions identical'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $testCodex 'backups') -Directory).Count -eq $backupCount) 'Repeated install creates no unnecessary backup'

$previousCodexDirectory = $env:CODEX_HOME
try {
    $env:CODEX_HOME = $testCodex
    $parsedConfig = & $status.Codex mcp get antigravity_delegate --json | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $parsedConfig.enabled -and $parsedConfig.transport.type -eq 'stdio') 'Codex itself parses the installed TOML and server registration'
} finally { $env:CODEX_HOME = $previousCodexDirectory }

$bundle = Join-Path $testCodex 'tools\antigravity-bridge\712480f2e0a744807fc59f1899812b4725289d92\plugins\antigravity-subagent\mcp\dist\server.cjs'
& node (Join-Path $PSScriptRoot 'mcp-smoke.cjs') $bundle
Assert-True ($LASTEXITCODE -eq 0) 'Real bundled MCP server works on Windows'

& $installer -Action Disable -CodexDirectory $testCodex
$status = & $installer -Action Status -CodexDirectory $testCodex
Assert-True ($status.Registered -and -not $status.Enabled -and -not $status.InstructionsInstalled) 'Disable turns off MCP and removes delegation instruction'
$testRejected = $false
try { & $installer -Action Test -CodexDirectory $testCodex } catch { $testRejected = $_.Exception.Message -like '*disabled*' }
Assert-True $testRejected 'Live verification cannot bypass disabled mode'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile)) -ceq $originalAgentsBytes) 'Disable restores exact original instruction bytes'
$disabledConfigBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
$failedWrite = $false
$lockStream = [IO.File]::Open($agentsFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    try { & $installer -Action Enable -CodexDirectory $testCodex } catch { $failedWrite = $true }
} finally { $lockStream.Dispose() }
Assert-True $failedWrite 'A locked instruction file causes a write failure'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq $disabledConfigBytes) 'Write failure rolls back the already updated TOML'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile)) -ceq $originalAgentsBytes) 'Write failure preserves the locked instruction file'
& $installer -Action Enable -CodexDirectory $testCodex
$status = & $installer -Action Status -CodexDirectory $testCodex
Assert-True ($status.Enabled -and $status.InstructionsInstalled) 'Enable restores the mode'

# Switching to a global override must move the managed rule, keeping both files.
$originalOverride = '# User override' + "`n" + '- Keep this override.'
[IO.File]::WriteAllText($overrideFile, $originalOverride, $utf8)
& $installer -Action Enable -CodexDirectory $testCodex
$status = & $installer -Action Status -CodexDirectory $testCodex
Assert-True ($status.EffectiveInstructions -eq $overrideFile -and $status.InstructionsInstalled) 'Nonempty global override receives the rule'
Assert-True ([IO.File]::ReadAllText($agentsFile) -ceq $originalAgents) 'Old managed rule removed from base instructions'

& $installer -Action Uninstall -CodexDirectory $testCodex
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq $originalConfigBytes) 'Uninstall restores exact TOML bytes including BOM and missing final newline'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsFile)) -ceq $originalAgentsBytes) 'Uninstall restores exact base instruction bytes'
Assert-True ([IO.File]::ReadAllText($overrideFile) -ceq $originalOverride) 'Uninstall preserves user override'
Assert-True (Test-Path -LiteralPath $bundle) 'Uninstall retains downloaded source'

$conflictConfig = $originalConfig + "`r`n[mcp_servers.antigravity_delegate]`r`ncommand = `"user-owned`""
[IO.File]::WriteAllText($configFile, $conflictConfig, $utf8)
$rejected = $false
try { & $installer -Action Enable -CodexDirectory $testCodex } catch { $rejected = $_.Exception.Message -like '*unmanaged*' }
Assert-True $rejected 'Unmanaged server-name conflict is rejected'
Assert-True ([IO.File]::ReadAllText($configFile) -ceq $conflictConfig) 'Conflict does not change configuration'

Write-Host "All installer checks passed. Evidence retained in $runDirectory"
