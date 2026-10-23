[CmdletBinding()]
param(
    [ValidatePattern('^v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$')]
    [string]$Version = 'v1.2.0',
    [string]$OutputDirectory = $null
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).ProviderPath }
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..')).ProviderPath

$targetDir = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $repoRoot "dist\$Version" }
$zipName = "gemini-codex-setup-$Version.zip"
$zipPath = Join-Path $targetDir $zipName
$shaPath = Join-Path $targetDir 'SHA256.txt'

$testRunsDir = Join-Path $repoRoot '.test-runs'
if (-not (Test-Path -LiteralPath $testRunsDir)) {
    New-Item -ItemType Directory -Path $testRunsDir -Force | Out-Null
}

$uniqueId = [Guid]::NewGuid().ToString('N')
$stagingDir = Join-Path $testRunsDir "pkg-stage-$uniqueId"

# Canonical containment check function
function Test-SubPath([string]$ParentPath, [string]$ChildPath) {
    $parentFull = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/') + '\'
    $childFull = [System.IO.Path]::GetFullPath($ChildPath)
    return $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)
}

if (-not (Test-SubPath $repoRoot $stagingDir)) {
    throw "Staging directory containment check failed: $stagingDir is not inside $repoRoot"
}

# Determine allowed files
$allowedFiles = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)

$rootFiles = @('setup-antigravity.ps1', 'start.cmd', 'README.md', 'STABILITY.md', 'WORKFLOW_EVAL.md')
foreach ($rf in $rootFiles) {
    $src = Join-Path $repoRoot $rf
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        $allowedFiles.Add($rf, $src)
    } else {
        throw "Required source file missing: $src"
    }
}

$releaseNotesFile = "RELEASE_NOTES_$Version.md"
$releaseNotesSrc = Join-Path $repoRoot $releaseNotesFile
if (Test-Path -LiteralPath $releaseNotesSrc -PathType Leaf) {
    $allowedFiles.Add($releaseNotesFile, $releaseNotesSrc)
}

$collectSubdir = {
    param([string]$SubName, [string[]]$Exts)
    $dirPath = Join-Path $repoRoot $SubName
    if (Test-Path -LiteralPath $dirPath -PathType Container) {
        Get-ChildItem -LiteralPath $dirPath -File | ForEach-Object {
            $ext = $_.Extension.ToLowerInvariant()
            if ($Exts -contains $ext) {
                $rel = "$SubName/$($_.Name)"
                $allowedFiles.Add($rel, $_.FullName)
            }
        }
    }
}

& $collectSubdir 'scripts' @('.cjs', '.ps1')
& $collectSubdir 'tests' @('.cjs', '.ps1')

$lunaBridgeRel = 'tools/luna-bridge/server.cjs'
$lunaBridgeSrc = Join-Path $repoRoot ($lunaBridgeRel.Replace('/', '\'))
if (Test-Path -LiteralPath $lunaBridgeSrc -PathType Leaf) {
    $allowedFiles.Add($lunaBridgeRel, $lunaBridgeSrc)
} else {
    throw "Required source file missing: $lunaBridgeSrc"
}

# Check if target ZIP already exists
if (Test-Path -LiteralPath $zipPath) {
    Write-Host "Target zip already exists: $zipPath. Verifying byte-for-byte exact content..."
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $zipEntries = @{}
        foreach ($e in $archive.Entries) {
            $norm = $e.FullName.Replace('\', '/')
            if ($zipEntries.ContainsKey($norm)) {
                throw "Duplicate entry in existing zip: $norm"
            }
            $zipEntries[$norm] = $e
        }

        if ($zipEntries.Count -ne $allowedFiles.Count) {
            throw "Existing zip entry count ($($zipEntries.Count)) does not match allowed set ($($allowedFiles.Count)). Cannot overwrite existing release."
        }

        foreach ($pair in $allowedFiles.GetEnumerator()) {
            $rel = $pair.Key
            $src = $pair.Value
            if (-not $zipEntries.ContainsKey($rel)) {
                throw "Existing zip missing entry '$rel'. Cannot overwrite existing release."
            }
            $entry = $zipEntries[$rel]
            $sourceBytes = [System.IO.File]::ReadAllBytes($src)
            $entryStream = $entry.Open()
            $ms = New-Object System.IO.MemoryStream
            $entryStream.CopyTo($ms)
            $entryStream.Dispose()
            $entryBytes = $ms.ToArray()
            $ms.Dispose()

            if ($sourceBytes.Length -ne $entryBytes.Length) {
                throw "Existing zip entry '$rel' size mismatch. Cannot overwrite existing release."
            }
            for ($i = 0; $i -lt $sourceBytes.Length; $i++) {
                if ($sourceBytes[$i] -ne $entryBytes[$i]) {
                    throw "Existing zip entry '$rel' content mismatch at offset $i. Cannot overwrite existing release."
                }
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    $existingHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    $expectedSidecarContent = "$existingHash  $zipName"

    if (Test-Path -LiteralPath $shaPath) {
        $existingShaContent = (Get-Content -LiteralPath $shaPath -Raw).Trim()
        if ($existingShaContent -ne $expectedSidecarContent.Trim()) {
            throw "Existing SHA256 sidecar '$shaPath' does not match verified archive hash. Cannot overwrite existing release."
        }
    } else {
        $expectedSidecarContent | Out-File -LiteralPath $shaPath -Encoding utf8 -NoNewline
    }

    Write-Output "EXISTING_VERIFIED: $zipPath"
    Write-Output "SHA256: $existingHash"
    Write-Output "ENTRIES: $($allowedFiles.Count)"
    return
}

# Build staging directory
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
foreach ($pair in $allowedFiles.GetEnumerator()) {
    $rel = $pair.Key
    $src = $pair.Value
    $dest = Join-Path $stagingDir ($rel.Replace('/', '\'))
    $destDir = [System.IO.Path]::GetDirectoryName($dest)
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    [System.IO.File]::Copy($src, $dest, $false)
}

if (-not (Test-Path -LiteralPath $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

$tempZipPath = Join-Path $testRunsDir "build-$uniqueId.zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $tempZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# Verify temp zip before placing in destination
$archive = [System.IO.Compression.ZipFile]::OpenRead($tempZipPath)
try {
    $zipEntries = @{}
    foreach ($e in $archive.Entries) {
        $norm = $e.FullName.Replace('\', '/')
        if ($zipEntries.ContainsKey($norm)) {
            throw "Duplicate entry created in archive: $norm"
        }
        $zipEntries[$norm] = $e
    }

    if ($zipEntries.Count -ne $allowedFiles.Count) {
        throw "Built archive entry count ($($zipEntries.Count)) mismatch with allowed files ($($allowedFiles.Count))."
    }

    foreach ($pair in $allowedFiles.GetEnumerator()) {
        $rel = $pair.Key
        $src = $pair.Value
        if (-not $zipEntries.ContainsKey($rel)) {
            throw "Built archive is missing entry '$rel'."
        }
        $entry = $zipEntries[$rel]
        $sourceBytes = [System.IO.File]::ReadAllBytes($src)
        $entryStream = $entry.Open()
        $ms = New-Object System.IO.MemoryStream
        $entryStream.CopyTo($ms)
        $entryStream.Dispose()
        $entryBytes = $ms.ToArray()
        $ms.Dispose()

        if ($sourceBytes.Length -ne $entryBytes.Length) {
            throw "Built archive entry '$rel' size mismatch."
        }
        for ($i = 0; $i -lt $sourceBytes.Length; $i++) {
            if ($sourceBytes[$i] -ne $entryBytes[$i]) {
                throw "Built archive entry '$rel' byte mismatch at offset $i."
            }
        }
    }
}
finally {
    $archive.Dispose()
}

[System.IO.File]::Move($tempZipPath, $zipPath)

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
"$hash  $zipName" | Out-File -LiteralPath $shaPath -Encoding utf8 -NoNewline

# Safe staging cleanup with path containment check
if (Test-SubPath $testRunsDir $stagingDir -and (Test-Path -LiteralPath $stagingDir)) {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "ZIP: $zipPath"
Write-Output "SHA256: $hash"
Write-Output "ENTRIES: $($allowedFiles.Count)"
