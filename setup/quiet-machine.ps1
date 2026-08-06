#Requires -RunAsAdministrator
<#
Machine-wide quiet layer (F2). Idempotent: safe to re-run.

Goal: a console never shows anything on top of the game and never reboots by
itself. Run once as admin; per-user tweaks live in quiet-user.ps1.
#>
$ErrorActionPreference = 'Stop'

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Host "  $Path\$Name = $Value"
}

Write-Host 'Game DVR off machine-wide (Game Bar overlay must never own the guide button)...'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0

Write-Host 'Lock screen off...'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1

Write-Host 'First-logon animation off...'
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 0

Write-Host 'Privacy settings screen off (it appears at every new account first sign-in)...'
# Without this, the console account's first sign-in lands on "choose privacy
# settings" full screen. It wants a mouse, a controller cannot dismiss it, and
# the frontend never gets to start.
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 1
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'DisablePrivacyExperience' 1

Write-Host 'Startup sound off...'
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation' 'DisableStartupSound' 1

Write-Host 'Windows Update: download + install in the 04:00 window, never auto-reboot under a session...'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 4
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'ScheduledInstallDay' 0
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'ScheduledInstallTime' 4
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'SetActiveHours' 1
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ActiveHoursStart' 14
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ActiveHoursEnd' 8

Write-Host 'Quiet boot (no Windows logo or spinner)...'
bcdedit.exe /set '{globalsettings}' bootuxdisabled on | Out-Null
bcdedit.exe /set '{current}' quietboot on | Out-Null

Write-Host 'Done. Reboot to see the quiet boot.'
