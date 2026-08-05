#Requires -RunAsAdministrator
<#
Microsoft Defender on a couch PC (F2). Two levels, your call:

  (default)  TUNE  - keep Defender, stop it from costing frames:
                     exclude every detected game library and shader cache,
                     scan only when idle at a 5% CPU cap, kill the scheduled
                     scan task. This is where nearly all the stutter goes.

  -Disable         - TURN DEFENDER OFF for good: real-time protection,
                     behavior monitoring, on-access scanning, cloud lookups,
                     every Defender scheduled task, and the "your PC is
                     unprotected" nagging. Same posture as SteamOS, which
                     ships with no antivirus at all. Your machine, your call.

ABOUT TAMPER PROTECTION (why other scripts fail here):
  Since Windows 10 2004, Tamper Protection makes Defender ignore
  DisableAntiSpyware and Set-MpPreference -DisableRealtimeMonitoring. Scripts
  that just write those keys report success and change nothing. There is no
  supported way to toggle Tamper Protection from a script, by design: it takes
  one click in the Windows Security UI. So -Disable opens that page for you,
  waits, verifies, and only then applies the real changes and confirms what
  actually stuck.

  .\tune-defender.ps1                  # tune only (recommended)
  .\tune-defender.ps1 -Disable         # guided full disable
  .\tune-defender.ps1 -Disable -Yes    # no prompts (fails fast if Tamper is on)
  .\tune-defender.ps1 -Restore         # put everything back
#>
param(
    [string[]]$ExtraPaths,
    [Alias('DisableRealtime')] [switch]$Disable,
    [switch]$Yes,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Host 'Defender cmdlets not present (already removed, or a third-party AV is in charge). Nothing to do.'
    return
}

$polDefender = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$polRtp = "$polDefender\Real-Time Protection"
$polSpynet = "$polDefender\Spynet"
$polSecCenter = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications'
$secCenterNotif = 'HKLM:\SOFTWARE\Microsoft\Windows Defender Security Center\Notifications'

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-GamePaths {
    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($steamDir in @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        (Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        'C:\Program Files (x86)\Steam'
    )) {
        if (-not $steamDir -or -not (Test-Path $steamDir)) { continue }
        $paths.Add($steamDir)

        # every configured library, including drives other than C:
        $vdf = Join-Path $steamDir 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                if (Test-Path $lib) { $paths.Add((Join-Path $lib 'steamapps')) }
            }
        }
        break
    }

    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Playnite'),
        'C:\Program Files\Epic Games',
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'D3DSCache')
    )) {
        if (Test-Path $p) { $paths.Add($p) }
    }

    if ($ExtraPaths) { foreach ($p in $ExtraPaths) { $paths.Add($p) } }
    return $paths | Sort-Object -Unique
}

function Set-DefenderTasks {
    param([ValidateSet('Enable', 'Disable')] [string]$Action)
    $tasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -ErrorAction SilentlyContinue
    foreach ($t in $tasks) {
        try {
            if ($Action -eq 'Disable') { Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null }
            else { Enable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null }
        } catch {
            Write-Warning "  scheduled task '$($t.TaskName)': $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------- restore ---

if ($Restore) {
    Write-Host 'Restoring Defender to defaults...'
    foreach ($p in Get-GamePaths) {
        try { Remove-MpPreference -ExclusionPath $p -ErrorAction Stop; Write-Host "  exclusion removed: $p" } catch { }
    }

    foreach ($item in @(
        @{ Path = $polDefender;    Name = 'DisableAntiSpyware' },
        @{ Path = $polDefender;    Name = 'DisableAntiVirus' },
        @{ Path = $polDefender;    Name = 'DisableRoutinelyTakingAction' },
        @{ Path = $polRtp;         Name = 'DisableRealtimeMonitoring' },
        @{ Path = $polRtp;         Name = 'DisableBehaviorMonitoring' },
        @{ Path = $polRtp;         Name = 'DisableOnAccessProtection' },
        @{ Path = $polRtp;         Name = 'DisableScanOnRealtimeEnable' },
        @{ Path = $polRtp;         Name = 'DisableIOAVProtection' },
        @{ Path = $polSpynet;      Name = 'SpynetReporting' },
        @{ Path = $polSpynet;      Name = 'SubmitSamplesConsent' },
        @{ Path = $polSecCenter;   Name = 'DisableNotifications' },
        @{ Path = $secCenterNotif; Name = 'DisableNotifications' }
    )) {
        Remove-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction SilentlyContinue
    }

    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false `
            -DisableIOAVProtection $false -DisableScriptScanning $false `
            -ScanOnlyIfIdleEnabled $true -DisableScanningNetworkFiles $false `
            -ScanAvgCPULoadFactor 50 -MAPSReporting 2 -SubmitSamplesConsent 1
    } catch {
        Write-Warning "Set-MpPreference: $($_.Exception.Message)"
    }
    Set-DefenderTasks -Action Enable

    Write-Host ''
    Write-Host 'Defender restored. Turn Tamper Protection back ON in Windows Security'
    Write-Host '(Virus & threat protection > Manage settings) to lock it that way.'
    return
}

# ------------------------------------------------------------------- tune ---

Write-Host 'Excluding game paths from scanning...'
$gamePaths = Get-GamePaths
if (-not $gamePaths) { Write-Warning 'No game paths detected yet (install Steam first, then re-run).' }
foreach ($p in $gamePaths) {
    Add-MpPreference -ExclusionPath $p
    Write-Host "  $p"
}

Write-Host 'Scan discipline: idle only, 5% CPU cap, no network scan, no scheduled scan...'
Set-MpPreference -ScanOnlyIfIdleEnabled $true -ScanAvgCPULoadFactor 5 -DisableScanningNetworkFiles $true
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -TaskName 'Windows Defender Scheduled Scan' -ErrorAction SilentlyContinue | Out-Null

if (-not $Disable) {
    Write-Host ''
    Write-Host 'Defender tuned and still protecting the machine.'
    Write-Host 'To turn it off entirely: .\tune-defender.ps1 -Disable'
    Write-Host 'To undo everything:      .\tune-defender.ps1 -Restore'
    return
}

# ---------------------------------------------------------------- disable ---

Write-Host ''
Write-Host '=== DISABLING MICROSOFT DEFENDER ===' -ForegroundColor Yellow
Write-Host 'This machine will have no antivirus. Fine for a console-style PC that'
Write-Host 'only runs games from stores you trust; a bad idea if it doubles as your'
Write-Host 'download-anything desktop. Undo anytime with -Restore.'

if (-not $Yes) {
    $answer = Read-Host 'Type DISABLE to continue'
    if ($answer -ne 'DISABLE') { Write-Host 'Aborted, Defender left on (tuning above still applied).'; return }
}

# Tamper Protection gate: nothing below sticks while it is on.
$tamper = (Get-MpComputerStatus).IsTamperProtected
if ($tamper -and $Yes) {
    throw 'Tamper Protection is ON: Defender would ignore every change. Turn it off in Windows Security > Virus & threat protection > Manage settings, then re-run.'
}
if ($tamper) {
    Write-Host ''
    Write-Host 'Tamper Protection is ON. It cannot be switched off by script (by design),' -ForegroundColor Yellow
    Write-Host 'so do it once by hand. Opening the page now:'
    Write-Host '    Virus & threat protection > Virus & threat protection settings >'
    Write-Host '    Manage settings > Tamper Protection: Off'
    try { Start-Process 'windowsdefender://threatsettings' } catch { Write-Warning 'Could not open Windows Security, open it from the Start menu.' }

    while ($tamper) {
        $null = Read-Host 'Press Enter once Tamper Protection is Off (or Ctrl+C to abort)'
        $tamper = (Get-MpComputerStatus).IsTamperProtected
        if ($tamper) { Write-Warning 'Still reporting ON, try again (the toggle can take a second to register).' }
    }
    Write-Host 'Tamper Protection is off, applying changes...' -ForegroundColor Green
}

Write-Host 'Real-time engine off (policy + preferences)...'
Set-RegValue $polDefender 'DisableAntiSpyware' 1
Set-RegValue $polDefender 'DisableAntiVirus' 1
Set-RegValue $polDefender 'DisableRoutinelyTakingAction' 1
Set-RegValue $polRtp 'DisableRealtimeMonitoring' 1
Set-RegValue $polRtp 'DisableBehaviorMonitoring' 1
Set-RegValue $polRtp 'DisableOnAccessProtection' 1
Set-RegValue $polRtp 'DisableScanOnRealtimeEnable' 1
Set-RegValue $polRtp 'DisableIOAVProtection' 1

Write-Host 'Cloud lookups and sample submission off...'
Set-RegValue $polSpynet 'SpynetReporting' 0
Set-RegValue $polSpynet 'SubmitSamplesConsent' 2

try {
    Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true `
        -DisableIOAVProtection $true -DisableScriptScanning $true `
        -MAPSReporting 0 -SubmitSamplesConsent 2
} catch {
    Write-Warning "Set-MpPreference: $($_.Exception.Message)"
}

Write-Host 'All Defender scheduled tasks off...'
Set-DefenderTasks -Action Disable

Write-Host 'Security Center nagging off (no "your PC is unprotected" toast over a game)...'
Set-RegValue $polSecCenter 'DisableNotifications' 1
Set-RegValue $secCenterNotif 'DisableNotifications' 1

# Report what actually stuck instead of assuming success.
Start-Sleep -Seconds 2
$status = Get-MpComputerStatus
Write-Host ''
Write-Host '--- Defender status now ---'
Write-Host "  Real-time protection : $($status.RealTimeProtectionEnabled)"
Write-Host "  Behavior monitoring  : $($status.BehaviorMonitorEnabled)"
Write-Host "  On-access protection : $($status.OnAccessProtectionEnabled)"
Write-Host "  Tamper Protection    : $($status.IsTamperProtected)"

if ($status.RealTimeProtectionEnabled) {
    Write-Warning @'
Real-time protection still reports ON. Usual causes: Tamper Protection got
re-enabled, or a pending reboot. Reboot and re-run; if it survives a reboot
with Tamper Protection off, something else (MDM policy) is enforcing it.
'@
} else {
    Write-Host ''
    Write-Host 'Defender is off. Undo anytime with: .\tune-defender.ps1 -Restore' -ForegroundColor Green
}
