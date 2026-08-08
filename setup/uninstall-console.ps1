#Requires -RunAsAdministrator
<#
Takes consolize back off a machine.

This project turns off Defender, turns off the firewall, lowers UAC and replaces
the Windows shell. Anything that does that to someone's computer owes them one
command that undoes it, and until now there wasn't one: nine scripts knew how to
reverse themselves and nothing called them, and five more had no way back at all.

What it does, in the order that keeps the machine usable at every step:

  1. gives the shell back        so a failure after this still lets you sign in
  2. undoes the boot and logon   Windows logo, sign-in screen, autologon
  3. restores the protections    Defender, firewall, UAC
  4. restores the tuning         power, performance, startup, the quiet layers
  5. removes what was installed  scheduled tasks, Steam entries, the files

The console account is kept unless you ask for it to go, because it owns the
Steam library, the saves and the screenshots. -RemoveAccount deletes the account
and, with -DeleteProfile, its files as well.

Anything already back to normal is skipped and said so, so this can be run again
after a partial run.

  .\uninstall-console.ps1                              # undo everything, keep the account
  .\uninstall-console.ps1 -UserName gamer              # name it if it cannot be guessed
  .\uninstall-console.ps1 -RemoveAccount               # and delete the account, keep its files
  .\uninstall-console.ps1 -RemoveAccount -DeleteProfile
  .\uninstall-console.ps1 -WhatIfOnly                  # just say what would happen
#>
param(
    [string]$UserName,
    [switch]$RemoveAccount,
    [switch]$DeleteProfile,
    [switch]$KeepFiles,
    [switch]$Yes,
    [switch]$WhatIfOnly
)
# Continue, not Stop. A machine half way out of consolize is worse than either
# end of the trip, so every step runs even when the one before it failed.
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$installDir = Split-Path $here -Parent
$stateDir = Join-Path $env:ProgramData 'Consolize'
$steps = @()

function Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
    if ($WhatIfOnly) { Write-Host '    (would run)' -ForegroundColor DarkGray; return }
    try {
        & $Action
        $script:steps += [pscustomobject]@{ Name = $Name; Result = 'done' }
    } catch {
        Write-Warning "    $($_.Exception.Message)"
        $script:steps += [pscustomobject]@{ Name = $Name; Result = "failed: $($_.Exception.Message)" }
    }
}

function Invoke-Sibling {
    param([string]$Script, [hashtable]$Arguments = @{})
    $path = Join-Path $here $Script
    if (-not (Test-Path $path)) { Write-Warning "    $Script is not here, skipping"; return }
    & $path @Arguments
}

# --- who was the console account --------------------------------------------
# Asking the machine rather than assuming 'gamer': whoever installed this may
# have called it anything, and undoing the wrong account's settings is worse
# than not undoing them.
if (-not $UserName) {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $UserName = (Get-ItemProperty $winlogon -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
    if ($UserName) { Write-Host "Console account, from the autologon setting: $UserName" }
}
if (-not $UserName) {
    $answers = Join-Path $stateDir 'answers.json'
    if (Test-Path $answers) {
        try { $UserName = (Get-Content $answers -Raw | ConvertFrom-Json).UserName } catch { }
        if ($UserName) { Write-Host "Console account, from the setup answers: $UserName" }
    }
}
if (-not $UserName) {
    Write-Warning 'Could not work out which account was the console one.'
    Write-Warning 'Pass it: .\uninstall-console.ps1 -UserName <name>'
    Write-Warning 'Carrying on with the machine-wide parts only.'
}

Write-Host ''
Write-Host '  consolize uninstall' -ForegroundColor Cyan
Write-Host ''
$accountFate = if (-not $RemoveAccount) { 'kept, with its Steam library and saves' }
               elseif ($DeleteProfile) { 'deleted, with its files' }
               else { 'deleted, its files kept' }

Write-Host "  console account : $(if ($UserName) { $UserName } else { '(unknown, machine-wide parts only)' })"
Write-Host "  installed in    : $installDir"
Write-Host "  state in        : $stateDir"
Write-Host "  the account     : $accountFate"
Write-Host "  installed files : $(if ($KeepFiles) { 'kept' } else { 'removed' })"
Write-Host ''

if (-not $Yes -and -not $WhatIfOnly) {
    $answer = Read-Host 'This puts Defender, the firewall, UAC and the shell back. Continue? [y/N]'
    if ($answer -notmatch '^[yY]') { Write-Host 'Nothing was changed.'; return }
}

# --- 1. the shell, first ------------------------------------------------------
# Before anything else, because every step after this one can fail and still
# leave a machine someone can sign into and fix by hand.
Step 'Giving the Windows shell back' {
    $arguments = @{ DisableGlobally = $true }
    if ($UserName) { $arguments.UserName = $UserName }
    Invoke-Sibling 'disable-shell-launcher.ps1' $arguments
}

# --- 2. boot and logon --------------------------------------------------------
Step 'Windows logo and sign-in screen back' {
    Invoke-Sibling 'boot-silent.ps1' @{ Restore = $true }
}

Step 'Autologon off' {
    if ($UserName) { Invoke-Sibling 'set-autologon.ps1' @{ UserName = $UserName; Remove = $true } }
    else { Invoke-Sibling 'set-autologon.ps1' @{ Remove = $true } }
}

# --- 3. the protections -------------------------------------------------------
Step 'Defender back on' {
    Invoke-Sibling 'tune-defender.ps1' @{ Restore = $true }
}

Step 'Firewall back to its defaults' {
    Invoke-Sibling 'firewall-console.ps1' @{ Restore = $true }
}

Step 'SSH and Remote Desktop off' {
    # Off is the Windows default, whether or not consolize opened them.
    Invoke-Sibling 'remote-console.ps1' @{ Restore = $true }
}

Step 'UAC back to normal' {
    $arguments = @{ Restore = $true }
    if ($UserName) { $arguments.UserName = $UserName }
    Invoke-Sibling 'console-elevation.ps1' $arguments
}

# --- 4. the tuning ------------------------------------------------------------
Step 'Power plan and sleep back' {
    Invoke-Sibling 'power-console.ps1' @{ Restore = $true }
}

Step 'Visual effects and scheduling back' {
    Invoke-Sibling 'tune-performance.ps1' @{ Restore = $true }
}

Step 'Startup items back' {
    Invoke-Sibling 'clean-startup.ps1' @{ Restore = $true }
}

Step 'Machine-wide quiet layer off' {
    Invoke-Sibling 'quiet-machine.ps1' @{ Restore = $true }
}

# --- 5. what was installed ----------------------------------------------------
Step 'Scheduled tasks removed' {
    foreach ($task in @('ConsolizeFirstLogon', 'ConsolizeFinish')) {
        if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false
            Write-Host "  removed $task"
        } else {
            Write-Host "  $task was not registered"
        }
    }
}

Step 'Steam library entries and their artwork removed' {
    # Runs as whoever is running this, which is an administrator and usually not
    # the console account, so the console account's own Steam profile is the one
    # that matters. The script walks every profile under the Steam install, so
    # it reaches it either way.
    Invoke-Sibling 'add-console-shortcuts.ps1' @{ Remove = $true; Force = $true }
}

if (-not $KeepFiles) {
    Step 'Installed files removed' {
        # This script lives in the directory being deleted, so the directory
        # goes after everything else and the deletion is told to keep going.
        $targets = @($stateDir)

        # Run from a clone rather than from an install and $installDir is the
        # working copy, so this step would delete the repository, uncommitted
        # work included. An install has the binary in it and no git directory;
        # anything else is somebody's source tree and is left alone.
        $looksInstalled = (Test-Path (Join-Path $installDir 'consolize.exe')) -and
                          -not (Test-Path (Join-Path $installDir '.git'))
        if ($looksInstalled) {
            $targets += $installDir
        } else {
            Write-Host "  $installDir is not an install (no consolize.exe, or a git working copy), left alone"
        }

        foreach ($dir in $targets) {
            if (Test-Path $dir) {
                Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $dir) { Write-Warning "  $dir is still there, delete it after the next restart" }
                else { Write-Host "  removed $dir" }
            }
        }
    }
}

# --- the account, only if asked ----------------------------------------------
if ($RemoveAccount -and $UserName) {
    Step "Console account '$UserName' removed" {
        $account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
        if (-not $account) { Write-Host "  $UserName does not exist"; return }

        $profilePath = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -like "*\$UserName" } | Select-Object -First 1)

        Remove-LocalUser -Name $UserName
        Write-Host "  removed the account $UserName"

        if ($DeleteProfile -and $profilePath) {
            # Through the profile object, not Remove-Item: the profile is also a
            # registry hive and a list entry, and deleting only the folder
            # leaves Windows believing the account still has a profile.
            Remove-CimInstance -InputObject $profilePath
            Write-Host "  removed its profile at $($profilePath.LocalPath)"
        } elseif ($profilePath) {
            Write-Host "  kept its files at $($profilePath.LocalPath) (Steam library, saves, screenshots)"
        }
    }
} elseif ($RemoveAccount) {
    Write-Warning 'Cannot remove the account: its name is not known. Pass -UserName.'
}

# --- what happened ------------------------------------------------------------
Write-Host ''
Write-Host '  summary' -ForegroundColor Cyan
foreach ($step in $steps) {
    $colour = if ($step.Result -eq 'done') { 'Green' } else { 'Red' }
    Write-Host ("  {0,-46} {1}" -f $step.Name, $step.Result) -ForegroundColor $colour
}

Write-Host ''
if ($WhatIfOnly) {
    Write-Host 'Nothing was changed. Drop -WhatIfOnly to do it.' -ForegroundColor Yellow
    return
}

$failed = @($steps | Where-Object { $_.Result -ne 'done' })
if ($failed.Count) {
    Write-Host "$($failed.Count) step(s) did not finish. Everything else was undone." -ForegroundColor Yellow
    Write-Host 'Running this again is safe: what is already back to normal is skipped.' -ForegroundColor Yellow
} else {
    Write-Host 'consolize is off this machine.' -ForegroundColor Green
}
Write-Host 'Restart for the shell, the boot screen and the power plan to take effect.'
