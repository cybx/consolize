#Requires -RunAsAdministrator
<#
Black screen from firmware to frontend (F2). No Windows logo, no spinner, no
"Welcome", no error dialogs at boot.

This uses two Device Lockdown features that only Enterprise, Education and IoT
Enterprise have, which is a large part of why this project targets those
editions:

  Unbranded Boot (Client-EmbeddedBootExp)
      Suppresses the Windows logo, the boot animation and boot error screens.

  Custom Logon (Client-EmbeddedLogon)
      Suppresses the logon UI itself: the welcome screen, the sign-out and
      shutdown screens, and the blocked-shutdown resolver.

What still shows and cannot be scripted away:
  - the motherboard or laptop vendor logo, which is firmware, not Windows
  - on some machines a brief black-to-accent flash while LogonUI hands over,
    which only a custom credential provider fully removes

  .\boot-silent.ps1
  .\boot-silent.ps1 -Restore
#>
param([switch]$Restore)
$ErrorActionPreference = 'Stop'

$logonUI = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Host "  $Name = $Value"
}

if ($Restore) {
    Write-Host 'Restoring the normal Windows boot experience...'
    bcdedit.exe /set '{globalsettings}' bootuxdisabled off | Out-Null
    bcdedit.exe /deletevalue '{current}' quietboot 2>&1 | Out-Null
    bcdedit.exe /deletevalue '{current}' bootstatuspolicy 2>&1 | Out-Null
    bcdedit.exe /deletevalue '{current}' noerrordisplay 2>&1 | Out-Null
    Remove-ItemProperty $logonUI -Name AnimationDisabled -ErrorAction SilentlyContinue
    Remove-ItemProperty $logonUI -Name BrandingNeutral -ErrorAction SilentlyContinue
    Remove-ItemProperty $policies -Name DisableStatusMessages -ErrorAction SilentlyContinue
    Set-RegValue $winlogon 'EnableFirstLogonAnimation' 1
    Write-Host 'Restored. The logo and welcome screen come back on the next boot.'
    return
}

# --- optional features -------------------------------------------------------
Write-Host 'Enabling the Device Lockdown boot and logon features...'
foreach ($feature in @('Client-DeviceLockdown', 'Client-EmbeddedBootExp', 'Client-EmbeddedLogon')) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue).State
    if (-not $state) {
        Write-Warning "  $feature not available on this edition, skipping."
        continue
    }
    if ($state -eq 'Enabled') { Write-Host "  $feature already enabled"; continue }
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop | Out-Null
        Write-Host "  $feature enabled"
    } catch {
        Write-Warning "  $feature : $($_.Exception.Message)"
    }
}

# --- boot: no logo, no animation, no error screens ---------------------------
Write-Host ''
Write-Host 'Boot: logo, animation and error screens off...'
bcdedit.exe /set '{globalsettings}' bootuxdisabled on | Out-Null
bcdedit.exe /set '{current}' quietboot on | Out-Null
bcdedit.exe /set '{current}' bootstatuspolicy ignoreallfailures | Out-Null
bcdedit.exe /set '{current}' noerrordisplay on | Out-Null
bcdedit.exe /timeout 0 | Out-Null
Write-Host '  bcdedit: bootuxdisabled, quietboot, bootstatuspolicy, noerrordisplay, timeout 0'

# --- logon: no welcome screen, no status text --------------------------------
Write-Host ''
Write-Host 'Logon: welcome screen and status messages off...'
Set-RegValue $logonUI 'AnimationDisabled' 1
# BrandingNeutral hides the logon screen furniture (power, language, ease of
# access and the rest). 1 keeps the surface blank on a machine that logs itself in.
Set-RegValue $logonUI 'BrandingNeutral' 1
Set-RegValue $winlogon 'EnableFirstLogonAnimation' 0
# GPO equivalent: "Remove Boot / Shutdown / Logon / Logoff status messages"
Set-RegValue $policies 'DisableStatusMessages' 1

Write-Host ''
Write-Host 'Done. Reboot to see it.' -ForegroundColor Green
Write-Host 'Expected: vendor firmware logo, then black, then the frontend.' -ForegroundColor DarkGray
Write-Host 'Undo with: .\boot-silent.ps1 -Restore' -ForegroundColor DarkGray
