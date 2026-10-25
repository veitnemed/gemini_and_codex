[CmdletBinding()]
param(
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string]$Version = 'v1.3.1',
    [string]$OutputDirectory = $null,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$target = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $repo "dist\$Version" }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The Windows .NET Framework C# compiler is unavailable.' }
$nodeCommand = Get-Command node -ErrorAction Stop
$nodeSource = $nodeCommand.Source
$nodeVersion = (& $nodeSource --version).Trim()
if ($nodeVersion -ne 'v24.11.0') { throw "Expected Node.js v24.11.0 for this release; found $nodeVersion." }
$license = Join-Path $repo 'runtime\LICENSE.node'
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { throw 'Node.js license text is missing.' }
$files = [ordered]@{
    'install-luna.ps1' = (Join-Path $repo 'install-luna.ps1')
    'tools/luna-bridge/server.cjs' = (Join-Path $repo 'tools\luna-bridge\server.cjs')
    'agents/luna_fast.toml' = (Join-Path $repo 'agents\luna_fast.toml')
    'agents/luna_think.toml' = (Join-Path $repo 'agents\luna_think.toml')
    'agents/luna_plan.toml' = (Join-Path $repo 'agents\luna_plan.toml')
    'policy/luna-orchestrator.md' = (Join-Path $repo 'policy\luna-orchestrator.md')
    'policy/luna-v12.md' = (Join-Path $repo 'policy\luna-v12.md')
    'runtime/LICENSE.node' = $license
    'runtime/node.exe' = $nodeSource
}
foreach ($source in $files.Values) { if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing package source: $source" } }
$tempRoot = Join-Path $repo '.test-runs'
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$staging = Join-Path $tempRoot ('luna-exe-stage-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $tempRoot ('luna-payload-' + [Guid]::NewGuid().ToString('N') + '.zip')
$exeName = "Luna-Codex-Setup-$Version.exe"
$exePath = Join-Path $target $exeName
if ((Test-Path -LiteralPath $exePath) -and -not $Force) { throw "Release EXE already exists; use -Force to rebuild: $exePath" }
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($entry in $files.GetEnumerator()) {
        $destination = Join-Path $staging ($entry.Key.Replace('/', '\'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $entry.Value -Destination $destination
    }
    # Windows PowerShell 5.1 treats BOM-less UTF-8 source as the system code page.
    $installerSource = Join-Path $repo 'install-luna.ps1'
    $installerStaged = Join-Path $staging 'install-luna.ps1'
    [IO.File]::WriteAllText($installerStaged, [IO.File]::ReadAllText($installerSource, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true)))
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $payload, [IO.Compression.CompressionLevel]::Optimal, $false)
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $resourceArg = '/resource:' + $payload + ',LunaPayload.zip'
    $outArg = '/out:' + $exePath
    $source = Join-Path $repo 'src\LunaSetup.cs'
    & $compiler /nologo /target:winexe $outArg $resourceArg /reference:System.IO.Compression.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $source
    if ($LASTEXITCODE -ne 0) { throw "C# installer compilation failed with exit code $LASTEXITCODE." }
    $hash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecar = Join-Path $target 'SHA256.txt'
    [IO.File]::WriteAllText($sidecar, "$hash  $exeName`r`n", (New-Object Text.UTF8Encoding($false)))
    Write-Output "EXE: $exePath"
    Write-Output "SHA256: $hash"
    Write-Output "NODE: $nodeVersion"
} finally {
    $root = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\') + '\'
    foreach ($candidate in @($staging, $payload)) {
        $full = [IO.Path]::GetFullPath($candidate)
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe temporary cleanup path: $full" }
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    }
}
