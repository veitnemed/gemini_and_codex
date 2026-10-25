[CmdletBinding()]
param([string]$SetupExe = $null)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $SetupExe) { $SetupExe = Join-Path $repo 'dist\v1.3.0\Luna-Codex-Setup-v1.3.0.exe' }
$runsRoot = Join-Path $repo '.test-runs'
$run = Join-Path $runsRoot ('luna-installer-' + [Guid]::NewGuid().ToString('N'))
$profile = Join-Path $run 'profile with spaces'
$collision = Join-Path $run 'collision'
$withoutAgents = Join-Path $run 'without agents table'
$exe = [IO.Path]::GetFullPath($SetupExe)
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Build the Luna EXE first: $exe" }

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Invoke-Setup([string[]]$Arguments, [int]$ExpectedExit) {
    $savedErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $exe --quiet @Arguments 2>&1 | Out-String
    } finally { $ErrorActionPreference = $savedErrorAction }
    $exit = $LASTEXITCODE
    Assert ($exit -eq $ExpectedExit) "EXE exit $exit; expected $ExpectedExit. $output"
    return $output
}

$utf8 = New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Path $profile -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $collision 'agents') -Force | Out-Null
New-Item -ItemType Directory -Path $withoutAgents -Force | Out-Null
$config = @(
    '# workflow-mode=1.2',
    'model = "gpt-6-sol"',
    'model_reasoning_effort = "high"',
    '[agents]',
    'enabled = false',
    'max_concurrent_threads_per_session = 4',
    '[mcp_servers.personal]',
    'command = "cmd"',
    'enabled = false',
    ''
) -join "`r`n"
$instructions = "# My own guidance`r`nKeep this paragraph exactly.`r`n"
[IO.File]::WriteAllText((Join-Path $profile 'config.toml'), $config, $utf8)
[IO.File]::WriteAllText((Join-Path $profile 'AGENTS.md'), $instructions, $utf8)
[IO.File]::WriteAllText((Join-Path $collision 'config.toml'), $config, $utf8)
[IO.File]::WriteAllText((Join-Path $collision 'agents\luna_fast.toml'), 'name = "user_owned"', $utf8)
$noAgentConfig = "model = `"gpt-6-sol`"`r`n"
[IO.File]::WriteAllText((Join-Path $withoutAgents 'config.toml'), $noAgentConfig, $utf8)

try {
    $first = Invoke-Setup @('--codex-home', $profile) 0
    Assert ($first.Contains('Install complete')) 'EXE performed installation'
    $installed = [IO.File]::ReadAllText((Join-Path $profile 'config.toml'), $utf8)
    Assert ($installed.Contains('# workflow-mode=1.3')) 'fresh installation persists default 1.3 workflow'
    $activeGuidance = [IO.File]::ReadAllText((Join-Path $profile 'AGENTS.md'), $utf8)
    Assert ($installed.Contains('model = "gpt-6-sol"')) 'root model remains selected by the user'
    Assert ($installed.Contains('[mcp_servers.personal]')) 'personal MCP server remains'
    Assert (-not $installed.Contains('antigravity_delegate')) 'new package has no Antigravity registration'
    Assert ($activeGuidance.Contains($instructions)) 'personal instructions remain'
    Assert ($activeGuidance.Contains('luna_plan') -and $activeGuidance.Contains('luna_fast')) 'automatic routing policy installed'
    Assert ($activeGuidance.Contains('delegate the substantive work before doing it yourself')) 'delegation-first policy installed instead of an older soft policy'
    Assert ([regex]::Matches($installed, '(?m)^default_tools_approval_mode = "writes"\r?$').Count -eq 3) 'read-only Luna tools do not require routine approval'
    foreach ($role in @('fast', 'think', 'plan')) {
        Assert ($installed.Contains("[mcp_servers.luna_$role]")) "MCP profile $role registered"
        $roleText = [IO.File]::ReadAllText((Join-Path $profile "agents\luna_$role.toml"), $utf8)
        $effort = @{ fast = 'medium'; think = 'max'; plan = 'high' }[$role]
        Assert ($roleText.Contains('model = "gpt-6-luna"') -and $roleText.Contains("model_reasoning_effort = `"$effort`"")) "native role $role has the fixed model and effort"
    }
    $runtime = Join-Path $profile 'tools\luna-orchestrator\v1.3.0'
    Assert (Test-Path -LiteralPath (Join-Path $runtime 'node.exe') -PathType Leaf) 'bundled Node runtime installed'
    Assert (Test-Path -LiteralPath (Join-Path $runtime 'server.cjs') -PathType Leaf) 'Luna bridge installed'
    $status = Invoke-Setup @('--status', '--codex-home', $profile) 0
    Assert ($status.Contains('Ready=True') -and $status.Contains('WorkflowMode=1.3')) 'status reads the managed mode rather than a personal comment'

    $second = Invoke-Setup @('--codex-home', $profile) 0
    Assert ($second.Contains('Install complete')) 'second installation succeeds'
    Assert ([IO.File]::ReadAllText((Join-Path $profile 'config.toml'), $utf8) -ceq $installed) 'reinstall is idempotent'
    Assert ([IO.File]::ReadAllText((Join-Path $profile 'AGENTS.md'), $utf8) -ceq $activeGuidance) 'reinstall does not duplicate policy'

    $toCompat = Invoke-Setup @('--mode', '1.2', '--codex-home', $profile) 0
    $compatConfig = [IO.File]::ReadAllText((Join-Path $profile 'config.toml'), $utf8)
    Assert ($compatConfig.Contains('# workflow-mode=1.2') -and $compatConfig.Contains('[mcp_servers.luna_think]')) '1.2 mode persists and retains Luna Max'
    Assert (-not $compatConfig.Contains('[mcp_servers.luna_fast]') -and -not $compatConfig.Contains('[mcp_servers.luna_plan]')) '1.2 removes inactive MCP registrations'
    Assert (-not (Test-Path -LiteralPath (Join-Path $profile 'agents\luna_fast.toml')) -and -not (Test-Path -LiteralPath (Join-Path $profile 'agents\luna_plan.toml'))) '1.2 removes unchanged managed inactive role files'
    Assert ($compatConfig.Contains('model = "gpt-6-sol"') -and $compatConfig.Contains('[mcp_servers.personal]')) 'switch preserves root model and unrelated MCP'
    $compatStatus = Invoke-Setup @('--status', '--codex-home', $profile) 0
    Assert ($compatStatus.Contains('WorkflowMode=1.2') -and $compatStatus.Contains('Ready=True')) 'status reports active 1.2 mode'
    $backToModern = Invoke-Setup @('--mode', '1.3', '--codex-home', $profile) 0
    Assert ([IO.File]::ReadAllText((Join-Path $profile 'config.toml'), $utf8).Contains('# workflow-mode=1.3')) 'switching back persists 1.3 mode'
    Assert ((Test-Path -LiteralPath (Join-Path $profile 'agents\luna_fast.toml')) -and (Test-Path -LiteralPath (Join-Path $profile 'agents\luna_plan.toml'))) 'switching back restores 1.3 roles'

    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCommand) {
        $previous = $env:CODEX_HOME
        try {
            $env:CODEX_HOME = $profile
            $parsed = & $codexCommand.Source mcp list --json | ConvertFrom-Json
            Assert ($LASTEXITCODE -eq 0) 'Codex CLI accepts installed TOML'
            foreach ($role in @('fast', 'think', 'plan')) {
                $entry = $parsed | Where-Object { $_.name -eq "luna_$role" }
                Assert ($null -ne $entry -and $entry.enabled -and $entry.transport.args[-1] -eq $role) "Codex CLI sees enabled profile $role"
            }
        } finally { $env:CODEX_HOME = $previous }
    }

    $removed = Invoke-Setup @('--uninstall', '--codex-home', $profile) 0
    Assert ($removed.Contains('Uninstall complete')) 'EXE performed uninstall'
    Assert ([IO.File]::ReadAllText((Join-Path $profile 'config.toml'), $utf8) -ceq $config) 'uninstall restores personal config exactly'
    Assert ([IO.File]::ReadAllText((Join-Path $profile 'AGENTS.md'), $utf8) -ceq $instructions) 'uninstall restores personal guidance exactly'
    foreach ($role in @('fast', 'think', 'plan')) {
        Assert (-not (Test-Path -LiteralPath (Join-Path $profile "agents\luna_$role.toml"))) "managed role $role removed"
    }

    $noAgentInstall = Invoke-Setup @('--codex-home', $withoutAgents) 0
    Assert ($noAgentInstall.Contains('Install complete')) 'fresh profile without agents table installs'
    $noAgentInstalled = [IO.File]::ReadAllText((Join-Path $withoutAgents 'config.toml'), $utf8)
    Assert ([regex]::Matches($noAgentInstalled, '(?m)^\[agents\]\r?$').Count -eq 1) 'fresh profile receives a real agents table'
    $noAgentStatus = Invoke-Setup @('--status', '--codex-home', $withoutAgents) 0
    Assert ($noAgentStatus.Contains('Ready=True')) 'fresh profile has native roles enabled'
    if ($codexCommand) {
        $previous = $env:CODEX_HOME
        try {
            $env:CODEX_HOME = $withoutAgents
            $null = & $codexCommand.Source mcp list --json
            Assert ($LASTEXITCODE -eq 0) 'Codex CLI parses the fresh profile'
        } finally { $env:CODEX_HOME = $previous }
    }
    $null = Invoke-Setup @('--uninstall', '--codex-home', $withoutAgents) 0
    Assert ([IO.File]::ReadAllText((Join-Path $withoutAgents 'config.toml'), $utf8) -ceq $noAgentConfig) 'uninstall removes the added agents table'

    $failed = Invoke-Setup @('--codex-home', $collision) 1
    Assert ($failed.Contains('user-owned role')) 'conflicting role is reported'
    Assert ([IO.File]::ReadAllText((Join-Path $collision 'config.toml'), $utf8) -ceq $config) 'collision leaves personal config unchanged'
    Write-Output 'PASS: EXE installs three profiles including fresh profiles, Codex parses config, reinstall is idempotent, uninstall restores settings, and user-owned roles are protected.'
} finally {
    $safeRoot = [IO.Path]::GetFullPath($runsRoot).TrimEnd('\') + '\'
    $safeRun = [IO.Path]::GetFullPath($run)
    if (-not $safeRun.StartsWith($safeRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe cleanup path: $safeRun" }
    if (Test-Path -LiteralPath $safeRun) { Remove-Item -LiteralPath $safeRun -Recurse -Force }
}
