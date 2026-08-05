#Requires -RunAsAdministrator
<#
Console power behavior (F3): press the power button, the game freezes where it
is; press it again (or the controller button), you are back in seconds. No
password prompt, no screensaver mid-cutscene, no 3am wake-ups.

  .\power-console.ps1                       # sleep on power button (recommended)
  .\power-console.ps1 -RestMode Hibernate   # slower resume, survives power loss
  .\power-console.ps1 -MonitorTimeout 30 -SleepTimeout 0
  .\power-console.ps1 -ListWakeDevices      # what can wake this machine
  .\power-console.ps1 -Restore              # back to Windows defaults

Sleep vs hibernate, the honest trade:
  Sleep     resumes in ~2s and a USB receiver (8BitDo dongle and friends) can
            wake the machine, but a power cut loses the session.
  Hibernate resumes in ~15s from NVMe, survives power loss, and nothing on USB
            can wake it: that is the case power button or an HDMI-CEC adapter.
#>
param(
    [ValidateSet('Sleep', 'Hibernate')] [string]$RestMode = 'Sleep',
    [int]$MonitorTimeout = 20,
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

if ($ListWakeDevices) {
    Write-Host 'Devices allowed to wake this machine:'
    powercfg /devicequery wake_armed
    Write-Host ''
    Write-Host 'Devices that COULD be allowed (use -EnableWake or Device Manager):'
    powercfg /devicequery wake_programmable
    return
}

if ($Restore) {
    Write-Host 'Restoring Windows power defaults...'
    Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
    Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
    Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP AWAYMODE 0
    Invoke-PowerCfg /change monitor-timeout-ac 10
    Invoke-PowerCfg /change standby-timeout-ac 30
    Invoke-PowerCfg /change disk-timeout-ac 20
    Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 1
    Invoke-PowerCfg /setactive SCHEME_CURRENT
    Write-Host 'Power settings restored.'
    return
}

Write-Host "Rest mode: $RestMode"
Write-Host '  power button, sleep button and Start menu power action'
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION $actionCode
Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION $actionCode
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION $actionCode
Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION $actionCode
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $actionCode

if ($RestMode -eq 'Hibernate') {
    Write-Host '  hibernation file enabled (full size, so resume keeps the whole session)'
    Invoke-PowerCfg /hibernate on
    Invoke-PowerCfg /hibernate /type full
}

Write-Host 'No password on wake (a console does not ask who you are)...'
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0

Write-Host "Timeouts: screen off after $MonitorTimeout min, sleep $(if ($SleepTimeout -eq 0) { 'never (movies and downloads keep running)' } else { "after $SleepTimeout min" })..."
Invoke-PowerCfg /change monitor-timeout-ac $MonitorTimeout
Invoke-PowerCfg /change standby-timeout-ac $SleepTimeout
Invoke-PowerCfg /change disk-timeout-ac 0
Invoke-PowerCfg /change hibernate-timeout-ac 0

Write-Host 'Wake timers off (nothing wakes the TV at 3am)...'
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0

Write-Host 'USB selective suspend off (wireless receivers stay responsive)...'
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0

Write-Host 'Fast startup off (it is the usual suspect behind "the PC rebooted instead of resuming")...'
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0

# Ultimate Performance if the SKU exposes it, otherwise High Performance:
# both stop core parking, which is what causes micro-stutter on some CPUs.
$ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$schemes = (powercfg /list) -join "`n"
# Modern Standby machines have no Ultimate Performance template, so this call
# fails exactly where it is most likely to run. Invoke-PowerCfg tolerates that.
if ($schemes -notmatch $ultimate) { Invoke-PowerCfg -duplicatescheme $ultimate }
$schemes = (powercfg /list) -join "`n"
$target = if ($schemes -match $ultimate) { $ultimate } else { $high }
Write-Host "Active power scheme: $(if ($target -eq $ultimate) { 'Ultimate Performance' } else { 'High Performance' })"
Invoke-PowerCfg /setactive $target

# Re-apply on the newly active scheme, since SCHEME_CURRENT changed under us.
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION $actionCode
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0
Invoke-PowerCfg /change monitor-timeout-ac $MonitorTimeout
Invoke-PowerCfg /change standby-timeout-ac $SleepTimeout
Invoke-PowerCfg /setactive SCHEME_CURRENT

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
