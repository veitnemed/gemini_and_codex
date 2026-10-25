[CmdletBinding()]
param([string]$SetupExe = $null, [string]$ScreenshotPath = $null)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $SetupExe) { $SetupExe = Join-Path $repo 'dist\v1.3.1\Luna-Codex-Setup-v1.3.1.exe' }
if (-not $ScreenshotPath) { $ScreenshotPath = Join-Path $repo 'dist\v1.3.1\Luna-Control-preview.png' }
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('luna-ui-test-' + [Guid]::NewGuid().ToString('N'))
$profile = Join-Path $testDirectory 'profile with spaces'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $profile 'config.toml'), "model = `"gpt-6-sol`"`r`n", $utf8)
[IO.File]::WriteAllText((Join-Path $profile 'AGENTS.md'), "Keep my personal instruction.`r`n", $utf8)
$outputPath = Join-Path $testDirectory 'stdout.log'
$errorPath = Join-Path $testDirectory 'stderr.log'
$success = $false
try {
    $arguments = '--ui-smoke --codex-home "' + $profile + '" --screenshot "' + [IO.Path]::GetFullPath($ScreenshotPath) + '"'
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = [IO.Path]::GetFullPath($SetupExe)
    $process.StartInfo.Arguments = $arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $null = $process.Start()
    if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'UI test exceeded 60 seconds.' }
    [IO.File]::WriteAllText($outputPath, $process.StandardOutput.ReadToEnd(), $utf8)
    [IO.File]::WriteAllText($errorPath, $process.StandardError.ReadToEnd(), $utf8)
    if ($process.ExitCode -ne 0) { throw "UI test failed: $(Get-Content -LiteralPath $errorPath -Raw)" }
    $config = [IO.File]::ReadAllText((Join-Path $profile 'config.toml'), $utf8)
    $guidance = [IO.File]::ReadAllText((Join-Path $profile 'AGENTS.md'), $utf8)
    if (-not $config.Contains('# workflow-mode=1.3') -or -not $config.Contains('model = "gpt-6-sol"')) { throw 'UI did not persist 1.3 or changed root model.' }
    foreach ($role in @('fast', 'plan', 'think')) { if (-not $config.Contains("[mcp_servers.luna_$role]")) { throw "Missing final role: $role" } }
    if (-not $guidance.Contains('Keep my personal instruction.')) { throw 'UI switch lost personal instructions.' }
    foreach ($suffix in @('', '-1.2', '-default')) {
        $renderPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ScreenshotPath))) ([IO.Path]::GetFileNameWithoutExtension($ScreenshotPath) + $suffix + [IO.Path]::GetExtension($ScreenshotPath))
        if (-not (Test-Path -LiteralPath $renderPath -PathType Leaf)) { throw "UI did not render mode screenshot: $renderPath" }
    }
    $success = $true
    Write-Output "PASS: real UI buttons switched 1.3 -> 1.2 -> default -> 1.3, persisted the final mode, preserved user settings. Screenshot: $ScreenshotPath"
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup: $resolved" }
    if ($success) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
