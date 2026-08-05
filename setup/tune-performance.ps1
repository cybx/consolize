#Requires -RunAsAdministrator
<#
Performance tuning that actually does something (F2).

The internet is full of "gaming tweaks" that measure as noise or make things
worse. This script implements only settings with a documented mechanism, and
the header of each block says what it actually buys. The myths we deliberately
skip are listed at the bottom, with the reason.

  .\tune-performance.ps1              # safe set, no functional trade-offs
  .\tune-performance.ps1 -Aggressive  # also strips background services a
                                      # console does not need (Search indexing,
                                      # SysMain, telemetry, memory compression
                                      # on high-RAM machines)
  .\tune-performance.ps1 -Restore
#>
param(
    [switch]$Aggressive,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Host "  $Name = $Value"
}

$mmcssGames = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
$mmcss = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$gfxDrivers = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'

if ($Restore) {
    Write-Host 'Restoring Windows defaults...'
    Set-RegValue $gfxDrivers 'HwSchMode' 1
    Set-RegValue $mmcss 'SystemResponsiveness' 20
    Set-RegValue $mmcssGames 'GPU Priority' 8
    Set-RegValue $mmcssGames 'Priority' 2
    Set-RegValue $mmcssGames 'Scheduling Category' 'Medium' 'String'
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2
    foreach ($svc in @('SysMain', 'WSearch', 'DiagTrack')) {
        try { Set-Service $svc -StartupType Automatic -ErrorAction Stop; Start-Service $svc -ErrorAction SilentlyContinue } catch { }
    }
    Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue
    DISM /Online /Set-ReservedStorageState /State:Enabled | Out-Null
    Write-Host 'Restored. Reboot to apply.'
    return
}

# --- Hardware-accelerated GPU Scheduling -------------------------------------
# Moves frame queue management from a CPU thread to the GPU's own scheduler.
# Small latency win, and NVIDIA frame generation requires it.
Write-Host 'Hardware-accelerated GPU Scheduling on...'
Set-RegValue $gfxDrivers 'HwSchMode' 2

# --- Game Mode ---------------------------------------------------------------
# Keeps background work off the cores the game is using. Default on, but
# people turn it off chasing myths, so pin it.
Write-Host 'Game Mode on...'
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode' 1
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1

# --- MMCSS "Games" profile ---------------------------------------------------
# The Multimedia Class Scheduler reserves CPU for tasks that register as
# multimedia. Games register under this profile; the defaults are conservative
# because Windows assumes other foreground work matters too. On a console it
# does not.
Write-Host 'Multimedia scheduler tuned for games...'
Set-RegValue $mmcss 'SystemResponsiveness' 10          # % reserved for non-multimedia, default 20
Set-RegValue $mmcssGames 'GPU Priority' 8
Set-RegValue $mmcssGames 'Priority' 6
Set-RegValue $mmcssGames 'Scheduling Category' 'High' 'String'
Set-RegValue $mmcssGames 'SFIO Priority' 'High' 'String'

# --- Pagefile sanity ---------------------------------------------------------
# Disabling the pagefile is a popular tweak and a reliable way to make games
# crash: several engines commit far more address space than they touch.
$cs = Get-CimInstance Win32_ComputerSystem
if (-not $cs.AutomaticManagedPagefile) {
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
    if (-not $pf) {
        Write-Warning 'Pagefile is disabled. Re-enabling system management: some games crash without one.'
        $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $true }
    }
} else {
    Write-Host 'Pagefile: system managed (correct).'
}

# --- Reserved storage --------------------------------------------------------
# Windows parks ~7 GB for update staging. A console with a game library would
# rather have the space; updates still work, they just stage on demand.
Write-Host 'Reserved storage off (frees roughly 7 GB)...'
DISM /Online /Set-ReservedStorageState /State:Disabled | Out-Null

if ($Aggressive) {
    Write-Host ''
    Write-Host 'Aggressive: trimming background services a console does not use...' -ForegroundColor Yellow

    # Search indexing: pure overhead when nobody searches from the couch.
    # SysMain (Superfetch): prefetching designed for spinning disks; on NVMe it
    # mostly costs background IO and RAM.
    # DiagTrack: telemetry upload.
    foreach ($svc in @('WSearch', 'SysMain', 'DiagTrack')) {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if (-not $s) { Write-Host "  $svc not present"; continue }
        try {
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            Set-Service $svc -StartupType Disabled -ErrorAction Stop
            Write-Host "  $svc disabled"
        } catch {
            Write-Warning "  $svc : $($_.Exception.Message)"
        }
    }

    # Memory compression trades CPU for RAM. Worth it at 16 GB, not at 32 GB+
    # where the RAM was never the constraint.
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($ramGB -ge 32) {
        Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue
        Write-Host "  memory compression off ($ramGB GB RAM, the CPU cost is not worth it)"
    } else {
        Write-Host "  memory compression kept on ($ramGB GB RAM, disabling it would hurt)"
    }

    # Short quantum with a stronger foreground boost. Real, documented, and
    # small: do not expect frames from it.
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
}

Write-Host ''
Write-Host 'Done. Reboot to apply.' -ForegroundColor Green
Write-Host ''
Write-Host 'Deliberately NOT done, because these hurt or do nothing:' -ForegroundColor DarkGray
Write-Host '  bcdedit useplatformclock / disabledynamictick: breaks modern timer and' -ForegroundColor DarkGray
Write-Host '    power management, a classic cause of stutter it claims to fix' -ForegroundColor DarkGray
Write-Host '  disabling the pagefile: crashes games that commit large address space' -ForegroundColor DarkGray
Write-Host '  timer resolution forcing: Windows 11 already handles this per process' -ForegroundColor DarkGray
Write-Host '  Nagle / TcpAckFrequency edits: obsolete, unmeasurable on modern links' -ForegroundColor DarkGray
Write-Host '  blanket "debloat" scripts: they break Windows Update and the Store' -ForegroundColor DarkGray
Write-Host '  disabling SSD defrag scheduling: Windows already sends TRIM, not defrag' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Bigger wins live in firmware, not the registry. On the new build check:' -ForegroundColor Cyan
Write-Host '  Resizable BAR enabled, XMP/EXPO on for the RAM, and the GPU in the' -ForegroundColor Cyan
Write-Host '  CPU-attached PCIe x16 slot. Those beat every registry tweak combined.' -ForegroundColor Cyan
