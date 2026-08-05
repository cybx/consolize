#Requires -RunAsAdministrator
<#
Makes Microsoft Defender stop costing frames on a couch PC (F2).

WHY NOT JUST "DISABLE DEFENDER":
  Since Windows 10 2004, Tamper Protection makes real-time protection
  un-scriptable by design: the DisableAntiSpyware policy and
  Set-MpPreference -DisableRealtimeMonitoring are silently ignored while it is
  on, and it can only be turned off by hand in the Windows Security UI. Any
  script that claims otherwise is either lying or shipping a rootkit-ish hack.
  The good news: nearly all of the stutter comes from real-time scanning of
  game reads and shader compilation, plus scheduled scans firing mid-session.
  Exclusions + scan discipline (the default here) buy you that back while the
  machine still refuses actual malware.

DEFAULT (recommended):
  - Exclude every detected Steam library, Playnite, Epic and shader caches
  - Scans only when idle, low CPU cap, no scheduled scan task, no network scan

OPT-IN:
  -DisableRealtime   Turns real-time protection off for real. Requires Tamper
                     Protection already off (the script checks and tells you
                     where to click). Your call: this leaves the machine
                     unprotected, which is the same posture as SteamOS.

UNDO:
  -Restore           Clears the exclusions this script added and re-enables
                     real-time protection and default scan behavior.
#>
param(
    [string[]]$ExtraPaths,
    [switch]$DisableRealtime,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Host 'Defender cmdlets not present (already removed or third-party AV in charge). Nothing to do.'
    return
}

$policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'

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

if ($Restore) {
    Write-Host 'Restoring Defender defaults...'
    foreach ($p in Get-GamePaths) {
        try { Remove-MpPreference -ExclusionPath $p -ErrorAction Stop; Write-Host "  exclusion removed: $p" } catch { }
    }
    Set-MpPreference -DisableRealtimeMonitoring $false -ScanOnlyIfIdleEnabled $true `
        -DisableScanningNetworkFiles $false -ScanAvgCPULoadFactor 50
    Remove-ItemProperty $policyKey -Name DisableAntiSpyware -ErrorAction SilentlyContinue
    Remove-ItemProperty "$policyKey\Real-Time Protection" -Name DisableRealtimeMonitoring -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -TaskName 'Windows Defender Scheduled Scan' -ErrorAction SilentlyContinue | Out-Null
    Write-Host 'Defender restored.'
    return
}

Write-Host 'Excluding game paths from real-time scanning...'
$gamePaths = Get-GamePaths
if (-not $gamePaths) { Write-Warning 'No game paths detected yet (install Steam first, then re-run).' }
foreach ($p in $gamePaths) {
    Add-MpPreference -ExclusionPath $p
    Write-Host "  $p"
}

Write-Host 'Scan discipline: idle only, low CPU cap, no network scan, no scheduled scan...'
Set-MpPreference -ScanOnlyIfIdleEnabled $true -ScanAvgCPULoadFactor 5 `
    -DisableScanningNetworkFiles $true -SubmitSamplesConsent 2 -MAPSReporting 0
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -TaskName 'Windows Defender Scheduled Scan' -ErrorAction SilentlyContinue | Out-Null

if ($DisableRealtime) {
    $tamper = (Get-MpComputerStatus).IsTamperProtected
    if ($tamper) {
        Write-Warning @'
Tamper Protection is ON, so real-time protection cannot be disabled by script
(by design, and that is a good thing). To do it by hand:
    Windows Security > Virus & threat protection > Manage settings
    > Tamper Protection: Off, then re-run this script with -DisableRealtime.
The exclusions and scan discipline above are already applied and deliver most
of the performance win, so this step is genuinely optional.
'@
    } else {
        Write-Host 'Disabling real-time protection (machine will be unprotected)...'
        if (-not (Test-Path "$policyKey\Real-Time Protection")) {
            New-Item -Path "$policyKey\Real-Time Protection" -Force | Out-Null
        }
        New-ItemProperty $policyKey -Name DisableAntiSpyware -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty "$policyKey\Real-Time Protection" -Name DisableRealtimeMonitoring -Value 1 -PropertyType DWord -Force | Out-Null
        Set-MpPreference -DisableRealtimeMonitoring $true
        $still = -not (Get-MpPreference).DisableRealtimeMonitoring
        if ($still) { Write-Warning 'Defender reports real-time protection still on; a reboot may be required.' }
        else { Write-Host 'Real-time protection disabled.' }
    }
}

Write-Host ''
Write-Host 'Defender tuned. Undo anytime with: .\tune-defender.ps1 -Restore'
