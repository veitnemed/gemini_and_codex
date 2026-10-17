# Interactive Menu for Gemini & Codex Installer / Supervisor Bridge
# Provides a clean console interface for setup-antigravity.ps1 actions.

[CmdletBinding()]
param(
    [string]$CodexDirectory = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [scriptblock]$ActionRunner = $null,
    [System.IO.TextReader]$InputReader = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).ProviderPath
$installerScript = Join-Path $repoRoot 'setup-antigravity.ps1'

if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
    throw "Installer script not found: $installerScript"
}

function Write-Styled {
    param(
        [string]$Text,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$NoNewline
    )
    if ($Host.UI -and $Host.UI.RawUI) {
        if ($NoNewline) {
            Write-Host $Text -ForegroundColor $ForegroundColor -NoNewline
        } else {
            Write-Host $Text -ForegroundColor $ForegroundColor
        }
    } else {
        if ($NoNewline) {
            Write-Host $Text -NoNewline
        } else {
            Write-Host $Text
        }
    }
}

function Show-Header {
    Write-Styled "====================================================================" -ForegroundColor DarkCyan
    Write-Styled "       GEMINI & CODEX SUPERVISOR BRIDGE - SETUP & MANAGEMENT        " -ForegroundColor Cyan
    Write-Styled "====================================================================" -ForegroundColor DarkCyan
    Write-Styled "Target Codex Directory: $CodexDirectory" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Menu {
    Write-Styled "Select an action:" -ForegroundColor White
    Write-Styled "  [1] Install/update global Codex guidance and bridges" -ForegroundColor Green
    Write-Styled "  [2] Status (read-only)" -ForegroundColor Cyan
    Write-Styled "  [3] Live verification (warns: calls Antigravity and Luna, consumes quota)" -ForegroundColor Yellow
    Write-Styled "  [4] Enable" -ForegroundColor Green
    Write-Styled "  [5] Disable" -ForegroundColor Magenta
    Write-Styled "  [6] Uninstall" -ForegroundColor Red
    Write-Styled "  [7] Exit" -ForegroundColor Gray
    Write-Host ""
}

function Read-UserChoice {
    param([System.IO.TextReader]$Reader)
    if ($Reader) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { return $null }
        return $line.Trim()
    }
    Write-Styled "Enter choice [1-7]: " -ForegroundColor White -NoNewline
    $line = [Console]::ReadLine()
    if ($null -eq $line) { return $null }
    return $line.Trim()
}

function Read-UserConfirmation {
    param(
        [string]$PromptText,
        [System.IO.TextReader]$Reader
    )
    Write-Styled "$PromptText [y/N]: " -ForegroundColor Yellow -NoNewline
    if ($Reader) {
        $ans = $Reader.ReadLine()
        if ($null -eq $ans) { return $false }
        return ($ans.Trim().ToLowerInvariant() -in @('y', 'yes'))
    }
    $ans = [Console]::ReadLine()
    if ($null -eq $ans) { return $false }
    return ($ans.Trim().ToLowerInvariant() -in @('y', 'yes'))
}

function Wait-ForKeyOrEnter {
    param([System.IO.TextReader]$Reader)
    Write-Host ""
    Write-Styled "Press Enter to continue..." -ForegroundColor DarkGray -NoNewline
    if ($Reader) {
        [void]$Reader.ReadLine()
        Write-Host ""
        return
    }
    [void][Console]::ReadLine()
    Write-Host ""
}

function Invoke-InstallerAction {
    param(
        [string]$ActionName,
        [string]$TargetDir,
        [scriptblock]$CustomRunner
    )
    if ($CustomRunner) {
        $runnerRes = & $CustomRunner -Action $ActionName -CodexDirectory $TargetDir
        if ($runnerRes -is [int]) {
            return $runnerRes
        }
        if (Test-Path Variable:\LASTEXITCODE) {
            return $LASTEXITCODE
        }
        return 0
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerScript -Action $ActionName -CodexDirectory $TargetDir
    if (Test-Path Variable:\LASTEXITCODE) {
        return $LASTEXITCODE
    }
    return 0
}

# Format and display read-only status in a pleasant human-readable format
function Show-StatusDisplay {
    param($StatusResult)
    Write-Host ""
    Write-Styled "--- Current Bridge & Environment Status ---" -ForegroundColor Cyan
    if ($null -eq $StatusResult) {
        Write-Styled "No status data returned." -ForegroundColor DarkYellow
        return
    }

    if ($StatusResult -is [System.Management.Automation.PSCustomObject]) {
        $props = $StatusResult.PSObject.Properties
        foreach ($p in $props) {
            $name = $p.Name
            $val = $p.Value
            $color = [ConsoleColor]::Gray
            if ($val -is [bool]) {
                if ($val) {
                    $color = [ConsoleColor]::Green
                    $val = "Yes"
                } else {
                    $color = [ConsoleColor]::DarkYellow
                    $val = "No"
                }
            } elseif ($null -eq $val -or [string]::IsNullOrWhiteSpace([string]$val)) {
                $color = [ConsoleColor]::DarkGray
                $val = "(none / missing)"
            } else {
                $color = [ConsoleColor]::White
            }
            Write-Styled ("  {0,-24}: " -f $name) -ForegroundColor DarkCyan -NoNewline
            Write-Styled "$val" -ForegroundColor $color
        }
    } else {
        Write-Host ($StatusResult | Out-String)
    }
}

# Main interactive loop
$exitCode = 0

while ($true) {
    Show-Header
    Show-Menu
    $choice = Read-UserChoice -Reader $InputReader

    if ($null -eq $choice) {
        # End of stream (e.g. piped or EOF)
        break
    }

    switch ($choice) {
        '1' {
            Write-Host ""
            Write-Styled ">> Action: Install/update global Codex guidance and bridges" -ForegroundColor Green
            Write-Styled "Configuring pinned bridges, MCP servers, and strict supervisor instructions..." -ForegroundColor Gray
            try {
                $res = Invoke-InstallerAction -ActionName 'Install' -TargetDir $CodexDirectory -CustomRunner $ActionRunner
                if ($res -eq 0 -or $null -eq $res) {
                    Write-Styled "`n[SUCCESS] Installation / update completed successfully." -ForegroundColor Green
                } else {
                    Write-Styled "`n[FAILED] Installation / update encountered errors (Exit code $res)." -ForegroundColor Red
                    $exitCode = $res
                }
            } catch {
                Write-Styled "`n[FAILED] Error during Install: $($_.Exception.Message)" -ForegroundColor Red
                $exitCode = 1
            }
            Wait-ForKeyOrEnter -Reader $InputReader
        }
        '2' {
            Write-Host ""
            Write-Styled ">> Action: Status (read-only)" -ForegroundColor Cyan
            try {
                if ($ActionRunner) {
                    $statusObj = & $ActionRunner -Action 'Status' -CodexDirectory $CodexDirectory
                    Show-StatusDisplay -StatusResult $statusObj
                } else {
                    # Call setup-antigravity.ps1 -Action Status
                    # It outputs a PSCustomObject
                    $statusObj = & $installerScript -Action Status -CodexDirectory $CodexDirectory
                    Show-StatusDisplay -StatusResult $statusObj
                }
                Write-Styled "`n[SUCCESS] Status retrieved successfully (no changes made)." -ForegroundColor Green
            } catch {
                Write-Styled "`n[FAILED] Error retrieving status: $($_.Exception.Message)" -ForegroundColor Red
                $exitCode = 1
            }
            Wait-ForKeyOrEnter -Reader $InputReader
        }
        '3' {
            Write-Host ""
            Write-Styled ">> Action: Live verification" -ForegroundColor Yellow
            Write-Styled "====================================================================" -ForegroundColor DarkYellow
            Write-Styled "WARNING: Live verification executes real queries through both the   " -ForegroundColor Yellow
            Write-Styled "Antigravity CLI bridge and the Luna bridge.                        " -ForegroundColor Yellow
            Write-Styled "This CALLS BOTH MODELS and CONSUMES your shared model quota.        " -ForegroundColor Yellow
            Write-Styled "====================================================================" -ForegroundColor DarkYellow
            Write-Host ""
            $confirmed = Read-UserConfirmation -PromptText "Proceed with live model verification?" -Reader $InputReader
            if ($confirmed) {
                Write-Styled "Running live verification..." -ForegroundColor Gray
                try {
                    $res = Invoke-InstallerAction -ActionName 'Test' -TargetDir $CodexDirectory -CustomRunner $ActionRunner
                    if ($res -eq 0 -or $null -eq $res) {
                        Write-Styled "`n[SUCCESS] Live verification passed successfully." -ForegroundColor Green
                    } else {
                        Write-Styled "`n[FAILED] Live verification failed (Exit code $res)." -ForegroundColor Red
                        $exitCode = $res
                    }
                } catch {
                    Write-Styled "`n[FAILED] Error during live verification: $($_.Exception.Message)" -ForegroundColor Red
                    $exitCode = 1
                }
            } else {
                Write-Styled "Live verification cancelled. No model calls were made." -ForegroundColor DarkGray
            }
            Wait-ForKeyOrEnter -Reader $InputReader
        }
        '4' {
            Write-Host ""
            Write-Styled ">> Action: Enable" -ForegroundColor Green
            try {
                $res = Invoke-InstallerAction -ActionName 'Enable' -TargetDir $CodexDirectory -CustomRunner $ActionRunner
                if ($res -eq 0 -or $null -eq $res) {
                    Write-Styled "`n[SUCCESS] Bridge enabled successfully." -ForegroundColor Green
                } else {
                    Write-Styled "`n[FAILED] Enable failed (Exit code $res)." -ForegroundColor Red
                    $exitCode = $res
                }
            } catch {
                Write-Styled "`n[FAILED] Error during Enable: $($_.Exception.Message)" -ForegroundColor Red
                $exitCode = 1
            }
            Wait-ForKeyOrEnter -Reader $InputReader
        }
        '5' {
            Write-Host ""
            Write-Styled ">> Action: Disable" -ForegroundColor Magenta
            try {
                $res = Invoke-InstallerAction -ActionName 'Disable' -TargetDir $CodexDirectory -CustomRunner $ActionRunner
                if ($res -eq 0 -or $null -eq $res) {
                    Write-Styled "`n[SUCCESS] Bridge disabled successfully." -ForegroundColor Green
                } else {
                    Write-Styled "`n[FAILED] Disable failed (Exit code $res)." -ForegroundColor Red
                    $exitCode = $res
                }
            } catch {
                Write-Styled "`n[FAILED] Error during Disable: $($_.Exception.Message)" -ForegroundColor Red
                $exitCode = 1
            }
            Wait-ForKeyOrEnter -Reader $InputReader
        }
        '6' {
            Write-Host ""
            Write-Styled ">> Action: Uninstall" -ForegroundColor Red
            Write-Styled "This will remove the managed MCP server entries and guidance from Codex." -ForegroundColor Yellow
            $confirmed = Read-UserConfirmation -PromptText "Are you sure you want to uninstall?" -Reader $InputReader
            if ($confirmed) {
                try {
                    $res = Invoke-InstallerAction -ActionName 'Uninstall' -TargetDir $CodexDirectory -CustomRunner $ActionRunner
                    if ($res -eq 0 -or $null -eq $res) {
                        Write-Styled "`n[SUCCESS] Uninstallation completed successfully." -ForegroundColor Green
                    } else {
                        Write-Styled "`n[FAILED] Uninstallation failed (Exit code $res)." -ForegroundColor Red
                        $exitCode = $res
                    }
                } catch {
                    Write-Styled "`n[FAILED] Error during Uninstall: $($_.Exception.Message)" -ForegroundColor Red
                    $exitCode = 1
                }
            } else {
                Write-Styled "Uninstallation cancelled. No changes made." -ForegroundColor DarkGray
            }
            Wait-ForKeyOrEnter -Reader $InputReader
        }
        '7' {
            Write-Styled "Exiting." -ForegroundColor Gray
            if ($exitCode -ne 0) { exit $exitCode }
            return
        }
        default {
            Write-Styled "Invalid option '$choice'. Please enter a number between 1 and 7." -ForegroundColor Red
            Wait-ForKeyOrEnter -Reader $InputReader
        }
    }
}

if ($exitCode -ne 0) {
    exit $exitCode
}
