[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).ProviderPath }
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..')).ProviderPath
$menuScript = Join-Path $repoRoot 'scripts\menu.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

# 1. Non-interactive test: verify menu opens and exits cleanly without running actions or calling models
$actionsRecorded = New-Object System.Collections.Generic.List[string]
$mockRunner = {
    param($Action, $CodexDirectory)
    $actionsRecorded.Add($Action)
    if ($Action -eq 'Status') {
        return [pscustomobject]@{
            Registered = $true
            Enabled = $true
            LunaRegistered = $true
            LunaEnabled = $true
            InstructionsInstalled = $true
            BridgePresent = $true
            LunaPresent = $true
            EffectiveInstructions = 'mock-path'
            Node = 'node'
            Codex = 'codex'
            Antigravity = 'agy'
        }
    }
    return 0
}

# Test Exit immediately (Option 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 0) "Option 7 exits without invoking any runner action"

# Test Status (Option 2 then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "2`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 1 -and $actionsRecorded[0] -eq 'Status') "Option 2 invokes read-only Status"

# Test Live Verification Decline (Option 3, decline with 'n', then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "3`r`nn`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 0) "Option 3 with decline does not invoke Test or call models"

# Test Live Verification Confirm (Option 3, confirm with 'y', then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "3`r`ny`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 1 -and $actionsRecorded[0] -eq 'Test') "Option 3 with confirmation invokes Test"

# Test Install/Update (Option 1 then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "1`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 1 -and $actionsRecorded[0] -eq 'Install') "Option 1 invokes Install"

# Test Enable (Option 4 then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "4`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 1 -and $actionsRecorded[0] -eq 'Enable') "Option 4 invokes Enable"

# Test Disable (Option 5 then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "5`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 1 -and $actionsRecorded[0] -eq 'Disable') "Option 5 invokes Disable"

# Test Uninstall Cancel (Option 6, 'n', then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "6`r`nn`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 0) "Option 6 with cancel does not invoke Uninstall"

# Test Uninstall Confirm (Option 6, 'y', then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "6`r`ny`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 1 -and $actionsRecorded[0] -eq 'Uninstall') "Option 6 with confirmation invokes Uninstall"

# Test Invalid input handling (Invalid input 'foo', then 7)
$actionsRecorded.Clear()
$reader = New-Object System.IO.StringReader "foo`r`n`r`n7`r`n"
& $menuScript -CodexDirectory 'mock-codex' -ActionRunner $mockRunner -InputReader $reader
Assert-True ($actionsRecorded.Count -eq 0) "Invalid option 'foo' does not invoke actions and recovers cleanly to exit"

Write-Host "All menu non-interactive behavior checks passed."
