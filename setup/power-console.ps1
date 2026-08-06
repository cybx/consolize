#Requires -RunAsAdministrator
<#
Console power behavior (F3): press the power button, the game freezes where it
is; press it again (or the controller button), you are back in seconds. No
password prompt, no screensaver mid-cutscene, no 3am wake-ups.

  .\power-console.ps1                       # sleep on power button (recommended)
  .\power-console.ps1 -RestMode Hibernate   # slower resume, survives power loss
  .\power-console.ps1 -MonitorTimeout 30    # blank the screen anyway, on OLED say
  .\power-console.ps1 -SleepTimeout 60      # and suspend after an hour idle
  .\power-console.ps1 -ListWakeDevices      # what can wake this machine
  .\power-console.ps1 -Restore              # back to Windows defaults

Neither the screen nor the machine switches itself off by default. That is on
purpose: blanking the display drops the HDMI signal, so the television may change
input by itself and the desktop can come back at a different resolution. A
console leaves that to the TV, which is designed for it. On an OLED panel you
may still want a timeout, hence -MonitorTimeout.

Sleep vs hibernate, the honest trade:
  Sleep     resumes in ~2s and a USB receiver (8BitDo dongle and friends) can
            wake the machine, but a power cut loses the session.
  Hibernate resumes in ~15s from NVMe, survives power loss, and nothing on USB
            can wake it: that is the case power button or an HDMI-CEC adapter.
#>
param(
    [ValidateSet('Sleep', 'Hibernate')] [string]$RestMode = 'Sleep',
    # 0 = never, and that is the right default on a TV. When Windows blanks the
    # display it drops the HDMI signal: many TVs then switch input on their own,
    # and coming back can reset the resolution and shuffle windows. A console
    # leaves screen blanking to the television, which is built for it.
    # Set a number of minutes if the panel is an OLED you worry about.
    [int]$MonitorTimeout = 0,
    [int]$SleepTimeout = 0,
    [switch]$ListWakeDevices,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

# powercfg action codes: 0 do nothing, 1 sleep, 2 hibernate, 3 shut down
$actionCode = if ($RestMode -eq 'Hibernate') { 2 } else { 1 }

function Invoke-PowerCfg {
    param([Parameter(ValueFromRemainingArguments)] [string[]]$Arguments)
    # 2>&1 wraps each native stderr line in an ErrorRecord, and under
    # $ErrorActionPreference='Stop' that is a TERMINATING error: the warning
    # below would never run and the whole provisioning would abort on any
    # machine powercfg complains about (no Ultimate Performance template, a VM
    # that cannot hibernate). Drop back to Continue just for the call.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powercfg.exe @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warning "powercfg $($Arguments -join ' '): $out" }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-ActivePowerScheme {
    $activeText = (powercfg /getactivescheme) -join ' '
    $activeMatch = [regex]::Match($activeText, '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b')
    if (-not $activeMatch.Success) { throw "Could not identify the active power scheme: $activeText" }
    return $activeMatch.Value.ToLowerInvariant()
}

if ($ListWakeDevices) {
    Write-Host 'Devices allowed to wake this machine:'
    powercfg /devicequery wake_armed
    Write-Host ''
    Write-Host 'Devices that COULD be allowed (use -EnableWake or Device Manager):'
    powercfg /devicequery wake_programmable
    return
}

# What the machine looked like before, written down before anything is changed.
# Without this, -Restore wrote its "defaults" into the Ultimate Performance
# scheme this script creates and then re-activated that scheme, so the owner was
# told power was back to normal while the console scheme was still driving the
# machine and a full size hiberfil.sys still had tens of gigabytes of the disk.
$stateFile = Join-Path $env:ProgramData 'Consolize\power-before.json'

function Save-PowerState {
    if (Test-Path $stateFile) {
        try { return Get-Content $stateFile -Raw | ConvertFrom-Json }
        catch { throw "The saved power state is unreadable ($stateFile). Refusing to overwrite it." }
    }

    # Labels such as "Power Scheme GUID" and "Hibernate" are translated by
    # Windows. UUIDs and hiberfil.sys are stable on every display language.
    $active = Get-ActivePowerScheme
    $hibernateOn = Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys')
    $hiberboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled

    $state = [pscustomobject]@{
        ActiveScheme   = $active
        HibernateWasOn = [bool]$hibernateOn
        HiberbootWas   = $hiberboot
        StateVersion   = 2
        ConsoleScheme  = $null
        SavedAt        = (Get-Date).ToString('o')
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
    $state | ConvertTo-Json | Set-Content $stateFile
    Write-Host "  previous power state recorded in $stateFile"
    return $state
}

if ($Restore) {
    Write-Host 'Restoring Windows power settings...'

    $before = $null
    if (Test-Path $stateFile) {
        try { $before = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { }
    }

    if ($before) {
        if ($before.ActiveScheme) {
            Invoke-PowerCfg /setactive $before.ActiveScheme
            if ((Get-ActivePowerScheme) -ne ([string]$before.ActiveScheme).ToLowerInvariant()) {
                throw "Could not reactivate the original power scheme ($($before.ActiveScheme)); saved state was kept."
            }
            Write-Host "  back on the power scheme that was active before ($($before.ActiveScheme))"
        }

        # Version 1 changed the owner's active plan before creating the console
        # plan. Repair those older installations with conservative Windows
        # defaults. Version 2 never touches the original plan at all.
        if (-not ($before.PSObject.Properties.Name -contains 'StateVersion')) {
            foreach ($rail in @('setacvalueindex', 'setdcvalueindex')) {
                Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
                Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 1
                Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_BUTTONS LIDACTION 1
                Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
                Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_SLEEP AWAYMODE 0
                Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
                Invoke-PowerCfg "/$rail" SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1
            }
            Invoke-PowerCfg /change monitor-timeout-ac 10
            Invoke-PowerCfg /change standby-timeout-ac 30
            Invoke-PowerCfg /change disk-timeout-ac 20
            Invoke-PowerCfg /change hibernate-timeout-ac 180
            Write-Host '  repaired the original plan changed by an older Consolize version'
        }

        if ($before.HibernateWasOn) {
            Invoke-PowerCfg /hibernate on
        } else {
            # A full hiberfil.sys is the size of RAM. Leaving 32 GB of a 256 GB
            # console SSD spoken for, on a machine that never hibernated before,
            # is not a small thing to leave behind.
            Invoke-PowerCfg /hibernate off
            Write-Host '  hibernation off again, and hiberfil.sys released'
        }
        # Do this last: powercfg /hibernate may itself change Fast Startup.
        $hiberboot = if ($null -ne $before.HiberbootWas) { $before.HiberbootWas } else { 1 }
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value $hiberboot

        if (($before.PSObject.Properties.Name -contains 'ConsoleScheme') -and
            $before.ConsoleScheme -and $before.ConsoleScheme -ne $before.ActiveScheme) {
            Invoke-PowerCfg /delete $before.ConsoleScheme
            Write-Host "  removed the Consolize-only power scheme ($($before.ConsoleScheme))"
        }
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warning '  no record of the previous power state, so the scheme and hibernation'
        Write-Warning '  are left as they are. Pick a plan in Settings > System > Power if the'
        Write-Warning '  machine is still on the console one.'
    }

    Write-Host 'Power settings restored.'
    return
}

$before = Save-PowerState

# Tune a private copy, never SCHEME_CURRENT while it still points to the owner's
# plan. This is the difference between a reversible setup and merely guessing
# Windows defaults during uninstall.
$target = $null
if (($before.PSObject.Properties.Name -contains 'ConsoleScheme') -and $before.ConsoleScheme) {
    $knownSchemes = (powercfg /list) -join ' '
    if ($knownSchemes -match [regex]::Escape([string]$before.ConsoleScheme)) {
        $target = [string]$before.ConsoleScheme
    }
}

if (-not $target) {
    $uuidPattern = '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b'
    $bases = @(
        'e9a42b02-d5df-448d-aa00-03f14749eb61', # Ultimate Performance template
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c', # High Performance
        [string]$before.ActiveScheme             # guaranteed final fallback
    )
    foreach ($base in $bases) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $duplicateOutput = & powercfg.exe -duplicatescheme $base 2>&1
            $duplicateExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        $match = [regex]::Match(($duplicateOutput -join ' '), $uuidPattern)
        if ($duplicateExit -eq 0 -and $match.Success) {
            $target = $match.Value
            break
        }
    }
    if (-not $target) { throw 'Could not create an isolated Consolize power scheme.' }

    Invoke-PowerCfg /changename $target 'Consolize Console'
    if ($before.PSObject.Properties.Name -contains 'ConsoleScheme') {
        $before.ConsoleScheme = $target
    } else {
        $before | Add-Member -NotePropertyName ConsoleScheme -NotePropertyValue $target
    }
    $before | ConvertTo-Json | Set-Content $stateFile
}

Invoke-PowerCfg /setactive $target
if ((Get-ActivePowerScheme) -ne $target.ToLowerInvariant()) {
    throw "Could not activate the private Consolize power scheme ($target); refusing to modify the owner's plan."
}

Write-Host "Rest mode: $RestMode"
Write-Host '  power button, sleep button and Start menu power action'
foreach ($rail in @('setacvalueindex', 'setdcvalueindex')) {
    Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION $actionCode
    Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION $actionCode
    Invoke-PowerCfg "/$rail" SCHEME_CURRENT SUB_BUTTONS LIDACTION $actionCode
}

if ($RestMode -eq 'Hibernate') {
    Write-Host '  hibernation file enabled (full size, so resume keeps the whole session)'
    Invoke-PowerCfg /hibernate on
    Invoke-PowerCfg /hibernate /type full
}

Write-Host 'No password on wake (a console does not ask who you are)...'
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0

Write-Host "Timeouts: screen $(if ($MonitorTimeout -eq 0) { 'never blanked (the TV handles that; blanking drops HDMI)' } else { "off after $MonitorTimeout min" }), sleep $(if ($SleepTimeout -eq 0) { 'never (movies and downloads keep running)' } else { "after $SleepTimeout min" })..."
Invoke-PowerCfg /change monitor-timeout-ac $MonitorTimeout
Invoke-PowerCfg /change monitor-timeout-dc $MonitorTimeout
Invoke-PowerCfg /change standby-timeout-ac $SleepTimeout
Invoke-PowerCfg /change standby-timeout-dc $SleepTimeout
Invoke-PowerCfg /change disk-timeout-ac 0
Invoke-PowerCfg /change disk-timeout-dc 0
Invoke-PowerCfg /change hibernate-timeout-ac 0
Invoke-PowerCfg /change hibernate-timeout-dc 0

Write-Host 'Wake timers off (nothing wakes the TV at 3am)...'
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0
Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0

Write-Host 'USB selective suspend off (wireless receivers stay responsive)...'
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0

Write-Host 'Fast startup off (it is the usual suspect behind "the PC rebooted instead of resuming")...'
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0

Write-Host "Active power scheme: Consolize Console ($target)"

Write-Host ''
Write-Host 'Wake sources right now:'
powercfg /devicequery wake_armed

Write-Host ''
Write-Host 'To let a controller receiver wake the machine from sleep, enable it in'
Write-Host 'Device Manager > the receiver > Power Management > "Allow this device to'
Write-Host 'wake the computer". List the candidates with: .\power-console.ps1 -ListWakeDevices'
if ($RestMode -eq 'Hibernate') {
    Write-Host 'Note: nothing on USB wakes a hibernated PC. Power button or HDMI-CEC only.'
}
