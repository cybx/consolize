#Requires -RunAsAdministrator
<#
Machine-wide quiet layer (F2). Idempotent: safe to re-run.

Goal: a console never shows anything on top of the game and never reboots by
itself. Run once as admin; per-user tweaks live in quiet-user.ps1.

  .\quiet-machine.ps1
  .\quiet-machine.ps1 -Restore   # put the machine back
#>
param([switch]$Restore)
$ErrorActionPreference = 'Stop'

# Every value this writes, in one list, so undoing it cannot drift from doing
# it. Almost all of these are policy values that did not exist before: for those
# the way back is to delete the value, not to write a "default" into it, because
# an absent policy is what Windows treats as no policy at all. Writing a guessed
# default would leave the policy in force, saying something else.
$settings = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Value = 0
       Note = 'Game DVR off machine-wide (Game Bar overlay must never own the guide button)' }

    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'; Name = 'NoLockScreen'; Value = 1
       Note = 'Lock screen off' }

    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation'; Value = 0
       Note = 'First-logon animation off' }

    # Without these, the console account's first sign-in lands on "choose privacy
    # settings" full screen. It wants a mouse, a controller cannot dismiss it,
    # and the frontend never gets to start.
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'; Name = 'DisablePrivacyExperience'; Value = 1
       Note = 'Privacy settings screen off (it appears at every new account first sign-in)' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'DisablePrivacyExperience'; Value = 1 }

    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation'; Name = 'DisableStartupSound'; Value = 1
       Note = 'Startup sound off' }

    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions'; Value = 4
       Note = 'Windows Update: download + install in the 04:00 window, never auto-reboot under a session' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'ScheduledInstallDay'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'ScheduledInstallTime'; Value = 4 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoRebootWithLoggedOnUsers'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetActiveHours'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursStart'; Value = 14 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursEnd'; Value = 8 }
)

if ($Restore) {
    Write-Host 'Undoing the machine-wide quiet layer...'
    foreach ($setting in $settings) {
        if (Test-Path $setting.Path) {
            Remove-ItemProperty -Path $setting.Path -Name $setting.Name -Force -ErrorAction SilentlyContinue
            Write-Host "  removed $($setting.Path)\$($setting.Name)"
        }
    }

    Write-Host 'Boot logo and spinner back...'
    # Missing values are already restored. Suppress native stderr directly:
    # 2>&1 becomes a terminating NativeCommandError under PowerShell 5.1 + EAP Stop.
    bcdedit.exe /deletevalue '{globalsettings}' bootuxdisabled 2>$null
    bcdedit.exe /deletevalue '{current}' quietboot 2>$null

    Write-Host ''
    Write-Host 'Done. A value that already existed with a different setting before consolize' -ForegroundColor Yellow
    Write-Host 'ran is not recovered, because the old value was never recorded. Removing it is' -ForegroundColor Yellow
    Write-Host 'what returns Windows to its own default, which is the case on a fresh machine.' -ForegroundColor Yellow
    return
}

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Host "  $Path\$Name = $Value"
}

foreach ($setting in $settings) {
    if ($setting.Note) { Write-Host "$($setting.Note)..." }
    Set-RegValue $setting.Path $setting.Name $setting.Value
}

Write-Host 'Quiet boot (no Windows logo or spinner)...'
bcdedit.exe /set '{globalsettings}' bootuxdisabled on | Out-Null
bcdedit.exe /set '{current}' quietboot on | Out-Null

Write-Host 'Done. Reboot to see the quiet boot.'
