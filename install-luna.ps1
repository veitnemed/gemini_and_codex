[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Status', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$CodexDirectory = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [ValidateSet('1.3', '1.2')][string]$WorkflowMode = '1.3'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$version = '1.3.0'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$CodexDirectory = [IO.Path]::GetFullPath($CodexDirectory)
$configPath = Join-Path $CodexDirectory 'config.toml'
$agentsPath = Join-Path $CodexDirectory 'AGENTS.md'
$overridePath = Join-Path $CodexDirectory 'AGENTS.override.md'
$rolesDirectory = Join-Path $CodexDirectory 'agents'
$runtimeDirectory = Join-Path $CodexDirectory "tools\luna-orchestrator\v$version"
$nodeTarget = Join-Path $runtimeDirectory 'node.exe'
$bridgeTarget = Join-Path $runtimeDirectory 'server.cjs'
$licenseTarget = Join-Path $runtimeDirectory 'LICENSE.node'
$roleNames = @('luna_fast', 'luna_think', 'luna_plan')
$activeRoles = if ($WorkflowMode -eq '1.2') { @('luna_think') } else { $roleNames }
$oldMcpBegin = '# >>> gemini-and-codex managed MCP >>>'
$oldMcpEnd = '# <<< gemini-and-codex managed MCP <<<'
$oldAgentsBegin = '# >>> gemini-and-codex managed agents >>>'
$oldAgentsEnd = '# <<< gemini-and-codex managed agents <<<'
$oldPromptBegin = '<!-- >>> gemini-and-codex delegation >>> -->'
$oldPromptEnd = '<!-- <<< gemini-and-codex delegation <<< -->'
$mcpBegin = '# >>> luna-orchestrator managed MCP >>>'
$mcpEnd = '# <<< luna-orchestrator managed MCP <<<'
$agentsBegin = '# >>> luna-orchestrator managed agents >>>'
$agentsEnd = '# <<< luna-orchestrator managed agents <<<'
$promptBegin = '<!-- >>> luna-orchestrator policy >>> -->'
$promptEnd = '<!-- <<< luna-orchestrator policy <<< -->'

function Read-Text([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [IO.File]::ReadAllText($Path, $utf8) }
    return ''
}

function Get-FileDigest([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Remove-Block([string]$Text, [string]$Begin, [string]$End) {
    $begins = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($Begin) + '\r?$').Count
    $ends = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($End) + '\r?$').Count
    if ($begins -ne $ends -or $begins -gt 1) { throw "Invalid or duplicate managed markers: $Begin" }
    if ($begins -eq 0) { return $Text }
    $pattern = '(?ms)^' + [regex]::Escape($Begin) + '\r?\n.*?^' + [regex]::Escape($End) + '(?:\r?\n|$)'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { throw "Invalid managed block: $Begin" }
    return $Text.Remove($match.Index, $match.Length)
}

function Restore-ManagedAgents([string]$Text) {
    # Repair the single-line comment emitted by the first v1.3.0 EXE when no
    # [agents] table existed. It was ignored by TOML and belongs to us.
    $Text = [regex]::Replace($Text, '(?m)^# >>> luna-orchestrator managed agents >>> # managed-full-section=true \[agents\] enabled = true max_concurrent_threads_per_session = 2 # <<< luna-orchestrator managed agents <<<[ \t]*(?:\r?\n|$)', '')
    $pattern = '(?ms)^' + [regex]::Escape($agentsBegin) + '\r?\n.*?^' + [regex]::Escape($agentsEnd) + '(?:\r?\n|$)'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $Text }
    if ([regex]::Matches($Text, '(?m)^' + [regex]::Escape($agentsBegin) + '\r?$').Count -ne 1) {
        throw 'Duplicate managed [agents] blocks.'
    }
    if ($match.Value -match '(?m)^# managed-full-section=true\r?$') {
        return $Text.Remove($match.Index, $match.Length)
    }
    $saved = [regex]::Match($match.Value, '(?m)^# original-agent-lines-b64=([A-Za-z0-9+/=]*)\r?$')
    if (-not $saved.Success) { throw 'Managed [agents] block lacks restoration data.' }
    $original = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($saved.Groups[1].Value))
    return $Text.Substring(0, $match.Index) + $original + $Text.Substring($match.Index + $match.Length)
}

function Enable-Agents([string]$Text) {
    $headers = [regex]::Matches($Text, '(?m)^\[agents\](?:\r?\n|$)')
    if ($headers.Count -gt 1) { throw 'Duplicate [agents] tables in config.toml.' }
    if ($headers.Count -eq 0) {
        $separator = if ($Text.Length -eq 0 -or $Text.EndsWith("`n")) { '' } else { "`r`n" }
        return $Text + $separator + (@(
            $agentsBegin, '# managed-full-section=true', '[agents]', 'enabled = true',
            'max_concurrent_threads_per_session = 2', $agentsEnd, ''
        ) -join "`r`n")
    }
    $header = $headers[0]
    $afterHeader = $header.Index + $header.Length
    $next = [regex]::Match($Text.Substring($afterHeader), '(?m)^\s*\[\[?[^\r\n]+\]\]?\s*\r?$')
    $end = if ($next.Success) { $afterHeader + $next.Index } else { $Text.Length }
    $body = $Text.Substring($afterHeader, $end - $afterHeader)
    $settings = [regex]::Matches($body, '(?m)^[ \t]*(?:enabled|max_concurrent_threads_per_session|max_threads)[ \t]*=[ \t]*[^\r\n]*(?:\r?\n|$)')
    $originalLines = ($settings | ForEach-Object { $_.Value }) -join ''
    $cleanBody = [regex]::Replace($body, '(?m)^[ \t]*(?:enabled|max_concurrent_threads_per_session|max_threads)[ \t]*=[ \t]*[^\r\n]*(?:\r?\n|$)', '')
    $saved = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($originalLines))
    $managed = "$agentsBegin`r`n# original-agent-lines-b64=$saved`r`nenabled = true`r`nmax_concurrent_threads_per_session = 2`r`n$agentsEnd`r`n"
    $cleanBody = $cleanBody.TrimStart("`r", "`n")
    return $Text.Substring(0, $afterHeader) + $managed + $cleanBody + $Text.Substring($end)
}

function Toml-String([string]$Value) {
    if ($Value -match '[\r\n\x00-\x1f]') { throw 'A TOML string contains control characters.' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Build-McpBlock {
    $node = Toml-String $nodeTarget
    $bridge = Toml-String $bridgeTarget
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($mcpBegin)
    $lines.Add("# workflow-mode=$WorkflowMode")
    foreach ($role in $activeRoles) {
        $profile = $role.Substring(5)
        $lines.Add("[mcp_servers.$role]")
        $lines.Add("command = $node")
        $lines.Add("args = [$bridge, `"$profile`"]")
        $lines.Add('enabled = true')
        $lines.Add('default_tools_approval_mode = "writes"')
        $lines.Add('startup_timeout_sec = 20')
        $lines.Add('tool_timeout_sec = 630')
        $lines.Add('')
    }
    $lines.Add($mcpEnd)
    return ($lines -join "`r`n") + "`r`n"
}

function Get-RoleText([string]$Source) {
    $body = Read-Text $Source
    if (-not $body.EndsWith("`n")) { $body += "`r`n" }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($body))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    return "# managed by luna-orchestrator; sha256=$digest`r`n$body"
}

function Test-ManagedRole([string]$Text) {
    $m = [regex]::Match($Text, '(?s)^# managed by (?:luna-orchestrator|gemini-and-codex); sha256=([0-9a-f]{64})\r?\n(.*)$')
    if (-not $m.Success) { return $false }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($m.Groups[2].Value))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    return $digest -ceq $m.Groups[1].Value
}

function Remove-LegacyAntigravityInstructions([string]$Text) {
    $pattern = '(?ms)^## Автоматическое делегирование Antigravity\r?\n(?:(?!^# Режим напарника по коду\r?$).)*?(?=^# Режим напарника по коду\r?$)'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success -and $m.Value.Contains('agy_delegate')) { return $Text.Remove($m.Index, $m.Length) }
    return $Text
}

$configOriginal = Read-Text $configPath
$agentsOriginal = Read-Text $agentsPath
$overrideOriginal = Read-Text $overridePath
$effectivePath = if ([string]::IsNullOrWhiteSpace($overrideOriginal)) { $agentsPath } else { $overridePath }
$roleTargets = @{}
foreach ($role in $roleNames) { $roleTargets[$role] = Join-Path $rolesDirectory "$role.toml" }

if ($Action -eq 'Status') {
    $allEnabled = $true
    $managedMcp = [regex]::Match($configOriginal, '(?ms)^' + [regex]::Escape($mcpBegin) + '\r?\n(.*?)^' + [regex]::Escape($mcpEnd) + '\r?$')
    $modeMatch = [regex]::Match($managedMcp.Groups[1].Value, '(?m)^# workflow-mode=(1\.3|1\.2)\r?$')
    $statusMode = if ($modeMatch.Success) { $modeMatch.Groups[1].Value } else { 'unknown' }
    $activeRoles = if ($statusMode -eq '1.2') { @('luna_think') } elseif ($statusMode -eq '1.3') { $roleNames } else { @() }
    Write-Output "WorkflowMode=$statusMode"
    foreach ($role in $roleNames) {
        $table = [regex]::Match($configOriginal, '(?ms)^\[mcp_servers\.' + $role + '\]\r?\n(.*?)(?=^\[|^# <<<|\z)')
        $registered = $table.Success
        $enabled = $registered -and $table.Groups[1].Value -match '(?m)^enabled[ \t]*=[ \t]*true\r?$'
        $present = Test-Path -LiteralPath $roleTargets[$role] -PathType Leaf
        $owned = $present -and (Test-ManagedRole (Read-Text $roleTargets[$role]))
        Write-Output "$role`: registered=$registered enabled=$enabled role=$present managed=$owned"
        $shouldExist = $role -in $activeRoles
        if ($shouldExist -and (-not $registered -or -not $enabled -or -not $owned)) { $allEnabled = $false }
        if (-not $shouldExist -and $registered) { $allEnabled = $false }
    }
    $agentTable = [regex]::Match($configOriginal, '(?ms)^\[agents\]\r?\n(.*?)(?=^\[|\z)')
    $agentsEnabled = $agentTable.Success -and $agentTable.Groups[1].Value -match '(?m)^enabled[ \t]*=[ \t]*true\r?$'
    $twoChildren = $agentTable.Success -and $agentTable.Groups[1].Value -match '(?m)^max_concurrent_threads_per_session[ \t]*=[ \t]*2\r?$'
    $policyInstalled = (Read-Text $effectivePath).Contains($promptBegin)
    $runtimePresent = (Test-Path -LiteralPath $nodeTarget -PathType Leaf) -and (Test-Path -LiteralPath $bridgeTarget -PathType Leaf)
    $allEnabled = $allEnabled -and $statusMode -ne 'unknown' -and $agentsEnabled -and $twoChildren -and $policyInstalled -and $runtimePresent
    Write-Output "PolicyInstalled=$policyInstalled AgentsEnabled=$agentsEnabled MaxChildrenTwo=$twoChildren RuntimePresent=$runtimePresent"
    Write-Output "Ready=$allEnabled"
    return
}

$configClean = Restore-ManagedAgents $configOriginal
$configClean = Remove-Block $configClean $oldAgentsBegin $oldAgentsEnd
$configClean = Remove-Block $configClean $oldMcpBegin $oldMcpEnd
$configClean = Remove-Block $configClean $mcpBegin $mcpEnd
foreach ($role in $roleNames) {
    if ($configClean -match ('(?m)^\[mcp_servers\.' + $role + '\]\r?$')) {
        throw "Unmanaged MCP table $role already exists; leaving user settings untouched."
    }
}

$promptChanges = @{}
foreach ($promptPath in @($agentsPath, $overridePath)) {
    $clean = Remove-Block (Read-Text $promptPath) $oldPromptBegin $oldPromptEnd
    $clean = Remove-Block $clean $promptBegin $promptEnd
    if ($Action -eq 'Install') { $clean = Remove-LegacyAntigravityInstructions $clean }
    $promptChanges[$promptPath] = $clean
}

$changes = @{}
if ($Action -eq 'Install') {
    $nodeSource = Join-Path $PSScriptRoot 'runtime\node.exe'
    if (-not (Test-Path -LiteralPath $nodeSource -PathType Leaf)) {
        $found = Get-Command node -ErrorAction SilentlyContinue
        if (-not $found) { throw 'Node runtime is absent from the package and PATH.' }
        $nodeSource = $found.Source
    }
    $bridgeSource = Join-Path $PSScriptRoot 'tools\luna-bridge\server.cjs'
    $licenseSource = Join-Path $PSScriptRoot 'runtime\LICENSE.node'
    $policySource = Join-Path $PSScriptRoot 'policy\luna-orchestrator.md'
    foreach ($source in @($bridgeSource, $licenseSource, $policySource)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Installer payload is missing: $source" }
    }
    $roleContents = @{}
    foreach ($role in $roleNames) {
        if ($role -notin $activeRoles) { continue }
        $source = Join-Path $PSScriptRoot "agents\$role.toml"
        $roleContents[$role] = Get-RoleText $source
        $existing = Read-Text $roleTargets[$role]
        if ($existing -and -not (Test-ManagedRole $existing)) {
            throw "A user-owned role exists at $($roleTargets[$role]); installation stopped without overwriting it."
        }
        $changes[$roleTargets[$role]] = $roleContents[$role]
    }
    foreach ($role in $roleNames) {
        if ($role -in $activeRoles) { continue }
        $target = $roleTargets[$role]
        $existing = Read-Text $target
        if ($existing -and (Test-ManagedRole $existing)) { $changes[$target] = $null }
    }
    $changes[$configPath] = (Enable-Agents $configClean).TrimEnd("`r", "`n") + "`r`n" + (Build-McpBlock)
    $policyFile = if ($WorkflowMode -eq '1.2') { Join-Path $PSScriptRoot 'policy\luna-v12.md' } else { $policySource }
    if (-not (Test-Path -LiteralPath $policyFile -PathType Leaf)) { throw "Installer payload is missing: $policyFile" }
    $policy = (Read-Text $policyFile).TrimEnd("`r", "`n")
    $changes[$effectivePath] = "$promptBegin`r`n$policy`r`n$promptEnd`r`n" + $promptChanges[$effectivePath]
    $otherPath = if ($effectivePath -eq $agentsPath) { $overridePath } else { $agentsPath }
    $changes[$otherPath] = $promptChanges[$otherPath]
} else {
    foreach ($role in $roleNames) {
        $existingRole = Read-Text $roleTargets[$role]
        if ($existingRole.StartsWith('# managed by luna-orchestrator;') -and -not (Test-ManagedRole $existingRole)) {
            throw "Modified managed role was preserved: $($roleTargets[$role])"
        }
    }
    $changes[$configPath] = $configClean
    $changes[$agentsPath] = $promptChanges[$agentsPath]
    $changes[$overridePath] = $promptChanges[$overridePath]
}

if (-not $PSCmdlet.ShouldProcess($CodexDirectory, "$Action Luna orchestrator v$version")) { return }
New-Item -ItemType Directory -Path $CodexDirectory -Force | Out-Null
$backupDir = Join-Path $CodexDirectory ('backups\luna-orchestrator-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$snapshots = New-Object 'System.Collections.Generic.List[object]'
$targets = @($changes.Keys)
if ($Action -eq 'Install') { $targets += @($nodeTarget, $bridgeTarget, $licenseTarget) }
foreach ($target in $targets) {
    $existing = Test-Path -LiteralPath $target -PathType Leaf
    $nameHash = [Security.Cryptography.SHA256]::Create()
    try { $snapshotName = [BitConverter]::ToString($nameHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($target))).Replace('-', '').ToLowerInvariant() + '.bak' }
    finally { $nameHash.Dispose() }
    $snapshot = Join-Path $backupDir $snapshotName
    if ($existing) { Copy-Item -LiteralPath $target -Destination $snapshot }
    $snapshots.Add([pscustomobject]@{ Path = $target; Existed = $existing; Backup = $snapshot })
}
$snapshots | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $backupDir 'restore.json') -Encoding UTF8

try {
    if ($Action -eq 'Install') {
        New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
        foreach ($pair in @(@($nodeSource, $nodeTarget), @($bridgeSource, $bridgeTarget), @($licenseSource, $licenseTarget))) {
            $src = $pair[0]; $dst = $pair[1]
            if ((Test-Path -LiteralPath $dst -PathType Leaf) -and
                (Get-FileDigest $src) -eq (Get-FileDigest $dst)) { continue }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    foreach ($target in $changes.Keys) {
        if ($null -eq $changes[$target]) { if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }; continue }
        if ($Action -eq 'Uninstall' -and $target -in @($agentsPath, $overridePath) -and
            -not (Test-Path -LiteralPath $target -PathType Leaf) -and -not $changes[$target]) { continue }
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $stage = "$target.luna-stage-$([Guid]::NewGuid().ToString('N'))"
        [IO.File]::WriteAllText($stage, $changes[$target], $utf8)
        Move-Item -LiteralPath $stage -Destination $target -Force
    }
    if ($Action -eq 'Uninstall') {
        foreach ($role in $roleNames) {
            $target = $roleTargets[$role]
            if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Read-Text $target).StartsWith('# managed by luna-orchestrator;')) {
                if (-not (Test-ManagedRole (Read-Text $target))) { throw "Modified managed role was preserved: $target" }
                Remove-Item -LiteralPath $target -Force
            }
        }
    }
} catch {
    foreach ($entry in $snapshots) {
        if ($entry.Existed) { Copy-Item -LiteralPath $entry.Backup -Destination $entry.Path -Force }
        elseif (Test-Path -LiteralPath $entry.Path -PathType Leaf) { Remove-Item -LiteralPath $entry.Path -Force }
    }
    throw
}

Write-Output "$Action complete. Backup: $backupDir"
Write-Output "WorkflowMode=$WorkflowMode"
Write-Output 'Restart Codex and open a new chat to load the Luna workflow.'
