#Requires -RunAsAdministrator
<#
Configures Windows Shell Launcher v2 so that Consolize replaces explorer.exe
as the shell for ONE specific user (the gamer account).

Requirements:
  - Windows 11 Enterprise, Education or IoT Enterprise (LTSC included).
    Home/Pro do not ship Shell Launcher.
  - Consolize installed (run install.ps1 first).

SAFETY:
  - The DEFAULT shell for every other user stays explorer.exe.
  - Keep a second admin account with the default shell so you can always log
    in and undo this (or undo it over SSH with disable-shell-launcher.ps1).
  - Test on a VM checkpoint first (see testlab/New-TestVm.ps1).
#>
param(
    [Parameter(Mandatory)] [string]$UserName,
    [string]$ShellPath = 'C:\Program Files\Consolize\consolize.exe',
    [ValidateSet('RestartShell', 'RestartDevice', 'ShutdownDevice', 'DoNothing')]
    [string]$OnShellExit = 'RestartShell',
    [switch]$SkipPreflight
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ShellPath)) { throw "Shell not found at $ShellPath. Run install.ps1 first." }

# Catch the first-boot traps (no saved Steam login, Steam autostarting on its
# own, no way back in) while a desktop is still there to fix them from.
if (-not $SkipPreflight) {
    $preflight = Join-Path $PSScriptRoot 'preflight.ps1'
    if (Test-Path $preflight) {
        & $preflight -UserName $UserName -ShellPath $ShellPath
        if ($LASTEXITCODE -ne 0) {
            throw 'Preflight found blocking issues (above). Fix them, or re-run with -SkipPreflight if you know what you are doing.'
        }
    }
}

Write-Host 'Enabling the Shell Launcher optional feature (no restart)...'
dism /online /enable-feature /featurename:Client-EmbeddedShellLauncher /all /norestart | Out-Null
# 3010 is ERROR_SUCCESS_REBOOT_REQUIRED, the normal companion of /norestart, and
# provisioning guarantees it: boot-silent.ps1 enables three Device Lockdown
# features and NetFx3 the same way. Treating it as failure blamed the Windows
# edition and left the machine looping forever.
$rebootPending = $LASTEXITCODE -eq 3010
if ($LASTEXITCODE -ne 0 -and -not $rebootPending) {
    throw "Could not enable Client-EmbeddedShellLauncher (DISM exit $LASTEXITCODE). Is this an Enterprise/Education/IoT Enterprise edition?"
}
if ($rebootPending) { Write-Host '  enabled, servicing wants a restart (expected during provisioning)' }

$actionMap = @{ RestartShell = 0; RestartDevice = 1; ShutdownDevice = 2; DoNothing = 3 }
$action = [uint32]$actionMap[$OnShellExit]
$sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$ns = 'root\standardcimv2\embedded'

Write-Host "Setting custom shell for '$UserName' ($sid): $ShellPath (on exit: $OnShellExit)"
$null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting -MethodName SetCustomShell -Arguments @{
    Sid = $sid
    Shell = $ShellPath
    DefaultAction = $action
}

# Everyone else keeps the normal desktop; restart it if it ever exits.
$null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting -MethodName SetDefaultShell -Arguments @{
    Shell = 'explorer.exe'
    DefaultAction = [uint32]0
}

$null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting -MethodName SetEnabled -Arguments @{ Enabled = $true }

$enabled = (Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting -MethodName IsEnabled).Enabled
Write-Host "Shell Launcher enabled: $enabled"
Write-Host "Log '$UserName' out and back in (or reboot) to boot into Consolize."
