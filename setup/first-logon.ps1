<#
Runs once, automatically, the first time the console account logs in. Registered
by setup-console.ps1; needs no administrator rights, on purpose.

It does the two things that only exist inside this account:
  - the per-user quiet settings (guide button belongs to Steam, no toasts)
  - the Steam login, which Windows keeps per user, so an administrator cannot
    do it on this account's behalf

A marker file in %LOCALAPPDATA% keeps it from running again. The scheduled task
itself is removed by setup-console.ps1 -EnableShell, which needs admin.
#>
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$marker = Join-Path $env:LOCALAPPDATA 'Consolize\first-logon-done'

# What the SYSTEM finish task waits for: this account is ready to become a
# console. setup-console.ps1 grants this account write access to that folder.
$readyMarker = Join-Path $env:ProgramData 'Consolize\account-ready'

if (Test-Path $marker) { return }

Write-Host ''
Write-Host '  consolize: finishing this account' -ForegroundColor Cyan
Write-Host '  phase 2 of 3'
Write-Host ''

# --- per-user quiet settings -------------------------------------------------
$quietUser = Join-Path $here 'quiet-user.ps1'
if (Test-Path $quietUser) {
    Write-Host '==> Per-user quiet settings...' -ForegroundColor Cyan
    & $quietUser
} else {
    Write-Warning "quiet-user.ps1 not found next to this script ($here)."
}

# --- Steam must not autostart: consolize is what launches it -----------------
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path $runKey) {
    foreach ($p in (Get-ItemProperty $runKey).PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        if ($p.Name -match 'steam' -or [string]$p.Value -match 'steam\.exe') {
            Remove-ItemProperty -Path $runKey -Name $p.Name -Force -ErrorAction SilentlyContinue
            Write-Host "  removed Steam autostart for this account ($($p.Name))"
        }
    }
}

# --- Steam login -------------------------------------------------------------
function Get-SteamPath {
    foreach ($dir in @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        (Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        'C:\Program Files (x86)\Steam'
    )) {
        if ($dir -and (Test-Path (Join-Path ($dir -replace '/', '\') 'steam.exe'))) { return ($dir -replace '/', '\') }
    }
    return $null
}

function Test-SteamLogin {
    param([string]$SteamDir)
    $vdf = Join-Path $SteamDir 'config\loginusers.vdf'
    if (-not (Test-Path $vdf)) { return $false }
    $raw = Get-Content $vdf -Raw
    if ($raw -notmatch '"RememberPassword"\s+"1"') { return $false }
    # the account also has to be this Windows user's autologin account
    $auto = (Get-ItemProperty 'HKCU:\SOFTWARE\Valve\Steam' -Name AutoLoginUser -ErrorAction SilentlyContinue).AutoLoginUser
    return [bool]$auto
}

$steam = Get-SteamPath
if (-not $steam) {
    Write-Warning 'Steam is not installed. Run bootstrap-gaming.ps1 as admin first.'
} else {
    Write-Host ''
    Write-Host '==> Steam login for this account' -ForegroundColor Cyan
    if (Test-SteamLogin $steam) {
        Write-Host '  already signed in on this account.'
    } else {
        Write-Host '  Steam keeps its login per Windows user, so this account needs its own.'
        Write-Host '  Sign in with "Remember me" ticked and clear any Steam Guard code.'
        Write-Host '  Without it, the console boots into a login window a controller cannot fill in.'
        Write-Host ''
        Start-Process (Join-Path $steam 'steam.exe')

        Write-Host '  Waiting for the sign-in (close this window to skip)...'
        $waited = 0
        while (-not (Test-SteamLogin $steam) -and $waited -lt 1800) {
            Start-Sleep -Seconds 5
            $waited += 5
        }
        if (Test-SteamLogin $steam) {
            Write-Host '  signed in.' -ForegroundColor Green
            # Steam re-adds its autostart entry once it runs
            foreach ($p in (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ($p.Name -match 'steam' -or [string]$p.Value -match 'steam\.exe') {
                    Remove-ItemProperty -Path $runKey -Name $p.Name -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Warning '  no sign-in detected. Do it before enabling the shell, or the first boot strands you.'
        }
    }
}

$steamReady = $steam -and (Test-SteamLogin $steam)
if ($steamReady) {
    # only mark this done when it actually finished: otherwise the task should
    # run again at the next logon instead of silently skipping itself
    New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
    Set-Content $marker (Get-Date).ToString('s') -Encoding UTF8
    try {
        Set-Content $readyMarker (Get-Date).ToString('s') -Encoding UTF8
        Write-Host ''
        Write-Host 'This account is ready.' -ForegroundColor Green
        Write-Host 'The machine takes it from here: it checks everything, replaces the shell'
        Write-Host 'and reboots into console mode in a moment. Nothing else for you to do.'
        Write-Host ''
        Write-Host 'Closing in 20 seconds...'
        Start-Sleep -Seconds 20
    } catch {
        Write-Warning "Could not signal readiness ($($_.Exception.Message))."
        Write-Warning 'On the admin account run: .\setup-console.ps1 -Finish'
        Read-Host 'Press Enter to close'
    }
} else {
    Write-Host ''
    Write-Warning 'Steam is not signed in on this account, so the shell will NOT be replaced.'
    Write-Warning 'That is deliberate: booting into a login window a controller cannot fill'
    Write-Warning 'in would strand you. Sign in to Steam with "Remember me", then run:'
    Write-Host "    $($MyInvocation.MyCommand.Path)"
    Read-Host 'Press Enter to close'
}
