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
param(
    [switch]$Restore,
    # Hiding the logon UI is only safe once the machine actually logs itself in
    # and boots into a frontend. Applied earlier, any failure anywhere in
    # provisioning leaves a black screen with no visible way to sign in. So the
    # logon half is opt-in and the finish task turns it on last, after the shell
    # is in place.
    [switch]$IncludeLogon
)
$ErrorActionPreference = 'Stop'

$logonUI = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
# Custom Logon reads its settings from here, NOT from LogonUI: writing
# BrandingNeutral under LogonUI reported success and did nothing at all.
$embeddedLogon = 'HKLM:\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon'
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
    foreach ($name in @('BrandingNeutral', 'HideAutoLogonUI', 'AnimationDisabled')) {
        Remove-ItemProperty $embeddedLogon -Name $name -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty $policies -Name DisableStatusMessages -ErrorAction SilentlyContinue

    # Restore the boot menu timeout this script zeroed. Without this a dual boot
    # machine keeps the other OS permanently unreachable, while the script says
    # everything is back to normal.
    $savedTimeout = Join-Path $env:ProgramData 'Consolize\boot-timeout.txt'
    if (Test-Path $savedTimeout) {
        $value = (Get-Content $savedTimeout -Raw).Trim()
        if ($value -match '^\d+$') { bcdedit.exe /timeout $value | Out-Null; Write-Host "  boot menu timeout restored to $value" }
        Remove-Item $savedTimeout -Force -ErrorAction SilentlyContinue
    } else {
        bcdedit.exe /timeout 30 | Out-Null
        Write-Host '  boot menu timeout restored to the Windows default (30)'
    }
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

# Zeroing the boot menu timeout on a dual boot machine hides the other OS, so
# only do it when Windows is the only entry, and record the old value first.
$entries = (bcdedit.exe /enum osloader | Select-String -Pattern '^identifier' -AllMatches).Count
if ($entries -le 1) {
    $current = (bcdedit.exe /enum '{bootmgr}' | Select-String -Pattern 'timeout\s+(\d+)').Matches.Groups[1].Value
    if ($current) {
        New-Item -ItemType Directory -Force -Path (Join-Path $env:ProgramData 'Consolize') | Out-Null
        Set-Content (Join-Path $env:ProgramData 'Consolize\boot-timeout.txt') $current -Encoding UTF8
    }
    bcdedit.exe /timeout 0 | Out-Null
    Write-Host '  bcdedit: bootuxdisabled, quietboot, bootstatuspolicy, noerrordisplay, timeout 0'
} else {
    Write-Host "  bcdedit: bootuxdisabled, quietboot, bootstatuspolicy, noerrordisplay"
    Write-Host "  ($entries boot entries found, leaving the menu timeout alone so the other OS stays reachable)"
}

# --- logon: no welcome screen, no status text --------------------------------
if (-not $IncludeLogon) {
    Write-Host ''
    Write-Host 'Logon screen left visible for now.' -ForegroundColor DarkGray
    Write-Host 'It is hidden at the very end, once the console actually logs itself in:' -ForegroundColor DarkGray
    Write-Host 'hiding it before that turns any setup failure into a black screen with no' -ForegroundColor DarkGray
    Write-Host 'visible way to sign in.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Done. Reboot to see it.' -ForegroundColor Green
    return
}

Write-Host ''
Write-Host 'Logon: welcome screen and status messages off...'
Set-RegValue $logonUI 'AnimationDisabled' 1
# BrandingNeutral is a bitmask, not a flag: 1 logon buttons, 2 power,
# 4 language, 8 ease of access, 16 switch user, 32 blocked shutdown resolver.
# 49 = buttons + switch user + BSDR, which is what a self-logging-in console
# should never show.
Set-RegValue $embeddedLogon 'BrandingNeutral' 49
Set-RegValue $embeddedLogon 'HideAutoLogonUI' 1
Set-RegValue $embeddedLogon 'AnimationDisabled' 1
Set-RegValue $winlogon 'EnableFirstLogonAnimation' 0
# GPO equivalent: "Remove Boot / Shutdown / Logon / Logoff status messages"
Set-RegValue $policies 'DisableStatusMessages' 1

Write-Host ''
Write-Host 'Done. Reboot to see it.' -ForegroundColor Green
Write-Host 'Expected: vendor firmware logo, then black, then the frontend.' -ForegroundColor DarkGray
Write-Host 'Undo with: .\boot-silent.ps1 -Restore' -ForegroundColor DarkGray
