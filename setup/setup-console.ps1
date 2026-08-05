#Requires -RunAsAdministrator
<#
Turns this machine into a console, start to finish. This is what the installer
one-liner runs; the individual scripts stay usable on their own.

It works in two phases, because Windows makes one thing per-user that we cannot
fake from an admin session: the Steam login. Steam keeps the account and its
autologin under HKCU, so logging in as the administrator does not carry over to
the console account.

  Phase 1 (here, as admin)   everything machine-wide: apps, runtimes, quiet
                             layer, power, startup, performance, autologon, and
                             a one-shot task that finishes the console account
                             the first time it logs in
  Phase 2 (console account)  log in once, let the one-shot task run, finish the
                             Steam login with "Remember me"
  Phase 3 (here, as admin)   .\setup-console.ps1 -EnableShell

  .\setup-console.ps1                          # phase 1, interactive
  .\setup-console.ps1 -UserName gamer -Yes     # phase 1, defaults, no prompts
  .\setup-console.ps1 -EnableShell             # phase 3, after the Steam login
#>
param(
    [string]$UserName = 'gamer',
    [switch]$EnableShell,
    [switch]$Yes,
    [switch]$SkipUpdates
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$exe = 'C:\Program Files\Consolize\consolize.exe'

function Step { param([string]$Text) Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Ask {
    param([string]$Question, [string]$Default = 'y')
    if ($Yes) { return $Default -eq 'y' }
    $suffix = if ($Default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default -eq 'y' }
    return $answer -match '^[yYsS]'
}

# ============================================================ phase 3 ========

if ($EnableShell) {
    Step "Preflight for '$UserName'"
    & (Join-Path $here 'preflight.ps1') -UserName $UserName
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'Preflight found blocking issues. Fix them and run this again.' -ForegroundColor Red
        return
    }

    if (-not (Ask "Replace the shell for '$UserName' now?")) { Write-Host 'Stopped.'; return }
    & (Join-Path $here 'enable-shell-launcher.ps1') -UserName $UserName -SkipPreflight

    # the first-logon task has done its job
    Unregister-ScheduledTask -TaskName 'ConsolizeFirstLogon' -Confirm:$false -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'Done. Reboot and the machine comes up as a console.' -ForegroundColor Green
    Write-Host 'If anything goes wrong: log in as another admin and run' -ForegroundColor DarkGray
    Write-Host "  .\disable-shell-launcher.ps1 -UserName $UserName" -ForegroundColor DarkGray
    if (Ask 'Reboot now?' 'n') { Restart-Computer -Force }
    return
}

# ============================================================ phase 1 ========

Write-Host ''
Write-Host '  consolize setup' -ForegroundColor Cyan
Write-Host '  phase 1 of 3: everything that does not need the console account'
Write-Host ''

$caption = (Get-CimInstance Win32_OperatingSystem).Caption
if ($caption -notmatch 'Enterprise|Education|IoT') {
    Write-Warning "$caption has no Shell Launcher. Provisioning still works, but the shell cannot be replaced on this edition."
    if (-not (Ask 'Continue anyway?' 'n')) { return }
}

# --- console account ---------------------------------------------------------
# Two accounts, on purpose:
#   this one (the account Windows was installed with) keeps the normal desktop
#   and stays your way in when the console account misbehaves;
#   the console account is the only one whose shell gets replaced.
Step "Console account '$UserName'"
Write-Host "  This account ($env:USERNAME) keeps the normal Windows desktop and stays"
Write-Host "  your way back in. Only '$UserName' boots into the console."

if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
    Write-Host "  '$UserName' exists."
} else {
    Write-Host ''
    if (-not (Ask "Create the console account '$UserName'?")) {
        Write-Host ''
        Write-Host "  Skipping. You can point this at an existing account instead:"
        Write-Host "    .\setup-console.ps1 -UserName $env:USERNAME"
        Write-Host '  Careful with that: replacing the shell on the only account leaves'
        Write-Host '  Ctrl+Shift+Esc as the single escape hatch.'
        return
    }
    $pw = Read-Host "Password for $UserName (blank for no password)" -AsSecureString
    $params = @{ Name = $UserName; FullName = 'Console'; Description = 'consolize console account' }
    if ($pw.Length -gt 0) { $params['Password'] = $pw } else { $params['NoPassword'] = $true }
    New-LocalUser @params | Out-Null
    Add-LocalGroupMember -Group 'Users' -Member $UserName -ErrorAction SilentlyContinue
    Write-Host "  created."
}

$otherAdmins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.ObjectClass -eq 'User' -and $_.Name -notlike "*\$UserName" }
if (-not $otherAdmins) {
    Write-Warning 'There is no second administrator account. That is your way back in if the shell misbehaves. Create one before enabling the shell.'
}

# --- apps and runtimes -------------------------------------------------------
Step 'Apps, drivers and runtimes'
$bootstrapArgs = @{}
if ($Yes) { $bootstrapArgs['Preset'] = 'recommended' }
if ($SkipUpdates) { $bootstrapArgs['UpdateScope'] = 'security' }
& (Join-Path $here 'bootstrap-gaming.ps1') @bootstrapArgs

# --- machine-wide frontend choice -------------------------------------------
$machineConfig = Join-Path $env:ProgramData 'Consolize\config.json'
if (-not (Test-Path $machineConfig)) {
    Step 'Boot frontend'
    & (Join-Path $here 'install-frontend.ps1') -Install steam -BootInto steam -Machine
}

# --- the rest of the machine layer -------------------------------------------
Step 'Quiet layer (nothing pops over a game)'
& (Join-Path $here 'quiet-machine.ps1')

Step 'Performance tuning'
$aggressive = Ask 'Also strip background services (Search indexing, SysMain, telemetry)?' 'y'
if ($aggressive) { & (Join-Path $here 'tune-performance.ps1') -Aggressive }
else { & (Join-Path $here 'tune-performance.ps1') }

Step 'Power: rest mode'
& (Join-Path $here 'power-console.ps1')

Step 'Emptying Windows startup'
& (Join-Path $here 'clean-startup.ps1') -All

Step 'Autologon'
if (Ask "Set '$UserName' to log in automatically at boot?") {
    & (Join-Path $here 'set-autologon.ps1') -UserName $UserName
}

# --- one-shot task that finishes the console account -------------------------
Step "One-shot task for $UserName's first logon"
$taskName = 'ConsolizeFirstLogon'
$userScript = Join-Path $here 'first-logon.ps1'
try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$userScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Description 'consolize: finish console account setup on first logon' | Out-Null
    Write-Host '  registered (it removes itself after it runs).'
} catch {
    Write-Warning "  could not register the task: $($_.Exception.Message)"
    Write-Warning "  run first-logon.ps1 by hand in the $UserName session instead."
}

# --- hand off ----------------------------------------------------------------
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Green
Write-Host ' Phase 1 done.' -ForegroundColor Green
Write-Host '====================================================='
Write-Host ''
Write-Host " Phase 2: log in as '$UserName' now."
Write-Host '   A window opens by itself and finishes that account: per-user quiet'
Write-Host '   settings, then Steam so you can log in with "Remember me" ticked.'
Write-Host '   That login cannot be done from this account: Steam keeps it per user.'
Write-Host ''
Write-Host ' Phase 3: come back here as admin and run'
Write-Host "   .\setup-console.ps1 -EnableShell -UserName $UserName"
Write-Host ''
if (Ask 'Sign out now so you can log in as the console account?' 'n') {
    shutdown.exe /l
}
