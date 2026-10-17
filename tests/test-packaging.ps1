[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).ProviderPath }
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..')).ProviderPath
$buildScript = Join-Path $repoRoot 'scripts\build-release-pkg.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

$testRunsDir = Join-Path $repoRoot '.test-runs'
if (-not (Test-Path -LiteralPath $testRunsDir)) {
    New-Item -ItemType Directory -Path $testRunsDir -Force | Out-Null
}

$testId = [Guid]::NewGuid().ToString('N')
$testOutDir = Join-Path $testRunsDir "pkg-test-$testId"
New-Item -ItemType Directory -Path $testOutDir -Force | Out-Null

try {
    # 1. Fresh build into isolated test output directory
    $buildOutput = & $buildScript -Version 'v1.0.0' -OutputDirectory $testOutDir
    $zipPath = Join-Path $testOutDir 'gemini-codex-setup-v1.0.0.zip'
    $shaPath = Join-Path $testOutDir 'SHA256.txt'

    Assert-True (Test-Path -LiteralPath $zipPath -PathType Leaf) 'Archive created in isolated output directory'
    Assert-True (Test-Path -LiteralPath $shaPath -PathType Leaf) 'SHA256.txt created in isolated output directory'

    # Verify contents of the built archive include scripts/menu.ps1, tests/test-menu-behavior.ps1, and start.cmd
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $entryNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
        [void]$entryNames.Add($entry.FullName.Replace('\', '/'))
    }
    $archive.Dispose()

    Assert-True ($entryNames.Contains('start.cmd')) 'Archive contains start.cmd'
    Assert-True ($entryNames.Contains('WORKFLOW_EVAL.md')) 'Archive contains WORKFLOW_EVAL.md'
    Assert-True ($entryNames.Contains('scripts/menu.ps1')) 'Archive contains scripts/menu.ps1'
    Assert-True ($entryNames.Contains('tests/test-menu-behavior.ps1')) 'Archive contains tests/test-menu-behavior.ps1'
    Assert-True ($entryNames.Contains('tools/luna-bridge/server.cjs')) 'Archive contains tools/luna-bridge/server.cjs'

    $initialSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    $expectedSidecarText = "$initialSha  gemini-codex-setup-v1.0.0.zip"
    $actualSidecarText = (Get-Content -LiteralPath $shaPath -Raw).Trim()
    Assert-True ($actualSidecarText -eq $expectedSidecarText) 'Initial SHA256 sidecar content matches archive hash exactly'

    # 2. Existing verified ZIP with valid sidecar -> early return succeeds
    $secondOutput = & $buildScript -Version 'v1.0.0' -OutputDirectory $testOutDir
    $outputJoined = ($secondOutput | Out-String)
    Assert-True ($outputJoined.Contains('EXISTING_VERIFIED')) 'Early return succeeds when identical archive and valid sidecar exist'

    # 3. Existing verified ZIP with missing SHA256.txt sidecar -> regenerates valid sidecar and early returns
    Remove-Item -LiteralPath $shaPath -Force
    Assert-True (-not (Test-Path -LiteralPath $shaPath)) 'Sidecar file removed for test'

    $thirdOutput = & $buildScript -Version 'v1.0.0' -OutputDirectory $testOutDir
    $thirdJoined = ($thirdOutput | Out-String)
    Assert-True ($thirdJoined.Contains('EXISTING_VERIFIED')) 'Early return succeeds when sidecar was missing'
    Assert-True (Test-Path -LiteralPath $shaPath -PathType Leaf) 'Missing sidecar was recreated during early return'
    $recreatedSidecarText = (Get-Content -LiteralPath $shaPath -Raw).Trim()
    Assert-True ($recreatedSidecarText -eq $expectedSidecarText) 'Recreated sidecar has valid matching SHA256 content'

    # 4. Existing verified ZIP with corrupted / mismatching SHA256.txt sidecar -> rejects, does not report success
    Set-Content -LiteralPath $shaPath -Value "0000000000000000000000000000000000000000000000000000000000000000  gemini-codex-setup-v1.0.0.zip" -Encoding utf8
    $sidecarMismatchCaught = $false
    try {
        & $buildScript -Version 'v1.0.0' -OutputDirectory $testOutDir
    } catch {
        if ($_.Exception.Message -match 'Existing SHA256 sidecar .* does not match verified archive hash') {
            $sidecarMismatchCaught = $true
        } else {
            throw
        }
    }
    Assert-True $sidecarMismatchCaught 'Corrupted SHA256 sidecar is detected and rejected without silent overwrite'

    # Restore valid sidecar for subsequent check
    Set-Content -LiteralPath $shaPath -Value $expectedSidecarText -Encoding utf8

    # 5. Existing ZIP with mismatching content -> rejects, does not silently overwrite
    # Create a corrupted zip by appending dummy bytes or rewriting an entry
    $corruptZipPath = $zipPath
    $bytes = [System.IO.File]::ReadAllBytes($corruptZipPath)
    $bytes[0] = [byte]($bytes[0] -bxor 0xFF)
    [System.IO.File]::WriteAllBytes($corruptZipPath, $bytes)

    $mismatchCaught = $false
    try {
        & $buildScript -Version 'v1.0.0' -OutputDirectory $testOutDir
    } catch {
        $mismatchCaught = $true
    }
    Assert-True $mismatchCaught 'Mismatching existing ZIP is rejected and not silently overwritten'

    Write-Host 'All packaging integration tests PASSED.'
}
finally {
    if (Test-Path -LiteralPath $testOutDir) {
        Remove-Item -LiteralPath $testOutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
