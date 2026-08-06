#Requires -RunAsAdministrator
<#
Makes consolize the shell for ONE account, leaving every other account with the
normal Windows desktop.

Two mechanisms, and the choice matters more than it looks:

  -Method registry   (default)
      Sets Winlogon's per-user Shell value in that account's hive. Winlogon
      starts consolize instead of explorer.exe for that user only.
      Desktop mode works: with no shell registered, launching explorer.exe
      later makes it take over as the shell, taskbar and desktop included.
      Works on every Windows edition, Home and Pro included.

  -Method shelllauncher
      The Shell Launcher feature (WESL_UserSetting), which Enterprise,
      Education and IoT Enterprise have. It restarts the shell for you on exit,
      with configurable actions per return code.
      BUT: Microsoft states that under Shell Launcher, launching explorer.exe
      from the custom shell does NOT restore the desktop, it only opens a File
      Explorer window, because the system suppresses the shell components.
      Reaching the desktop then means switching the shell back and signing out.
      https://learn.microsoft.com/en-us/answers/questions/5576492/

Which is why registry is the default here: consolize is its own watchdog and
never exits on purpose, so Shell Launcher's restart is worth less to it than
desktop mode is.

SAFETY
  - Every other account keeps explorer.exe.
  - Keep a second administrator account. That is the way back in.
  - rescue.ps1 undoes all of this, and can be reached from Task Manager, which
    opens over any shell with Ctrl+Shift+Esc.

  .\enable-shell-launcher.ps1 -UserName gamer
  .\enable-shell-launcher.ps1 -UserName gamer -Method shelllauncher
#>
param(
    [Parameter(Mandatory)] [string]$UserName,
    [ValidateSet('registry', 'shelllauncher')] [string]$Method = 'registry',
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
        & $preflight -UserName $UserName -ShellPath $ShellPath -Method $Method -NoExit
        if ($LASTEXITCODE -ne 0) {
            throw 'Preflight found blocking issues (above). Fix them, or re-run with -SkipPreflight if you know what you are doing.'
        }
    }
}

$sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate(
    [System.Security.Principal.SecurityIdentifier]).Value

# ============================================================ registry =======

if ($Method -eq 'registry') {
    # The value lives in the target account's own hive, which is only on disk
    # until that account signs in for the first time.
    $hive = "Registry::HKEY_USERS\$sid"
    $mounted = $null

    if (-not (Test-Path $hive)) {
        $profileDir = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.SID -eq $sid } | Select-Object -First 1).LocalPath
        if (-not $profileDir -or -not (Test-Path (Join-Path $profileDir 'NTUSER.DAT'))) {
            throw @"
'$UserName' has no profile yet, so its per-user shell cannot be set.
A profile appears the first time an account signs in. Sign in as $UserName
once, sign out, and run this again. (Or use -Method shelllauncher, which
stores the setting outside the user's hive, at the cost of desktop mode.)
"@
        }
        $mounted = "consolize-$sid"
        & reg.exe load "HKU\$mounted" (Join-Path $profileDir 'NTUSER.DAT') *>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not load $UserName's registry hive (is that account signed in?)." }
        $hive = "Registry::HKEY_USERS\$mounted"
    }

    try {
        $key = Join-Path $hive 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        $previousShell = (Get-ItemProperty -Path $key -Name Shell -ErrorAction SilentlyContinue).Shell
        $shellStateDir = Join-Path $env:ProgramData 'Consolize'
        $shellState = Join-Path $shellStateDir "shell-before-$sid.json"
        if (-not (Test-Path $shellState)) {
            New-Item -ItemType Directory -Force -Path $shellStateDir | Out-Null
            & icacls.exe $shellStateDir /inheritance:r /grant:r `
                '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not protect $shellStateDir" }
            [pscustomobject]@{
                HadShell = [bool]($previousShell -and $previousShell -notmatch '(?i)(?:^|[\\/])consolize\.exe(?:\s|$|")')
                PreviousShell = if ($previousShell -and $previousShell -notmatch '(?i)(?:^|[\\/])consolize\.exe(?:\s|$|")') { $previousShell } else { $null }
            } | ConvertTo-Json | Set-Content $shellState -Encoding UTF8
        }
        New-ItemProperty -Path $key -Name 'Shell' -Value $ShellPath -PropertyType String -Force | Out-Null
        Write-Host "Shell for '$UserName' set to $ShellPath"
        Write-Host '  (per-user: every other account still gets explorer.exe)'
    } finally {
        if ($mounted) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$mounted" *>$null
        }
    }

    # Winlogon restarts the shell process if it exits. On by default, but say so
    # out loud: it is what stands between a crash and an empty session.
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    New-ItemProperty -Path $wl -Name 'AutoRestartShell' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host '  AutoRestartShell on: Winlogon brings the shell back if it ever exits'

    Write-Host ''
    Write-Host "Done. Sign '$UserName' out and in (or reboot) to boot into consolize." -ForegroundColor Green
    Write-Host "Undo with: .\disable-shell-launcher.ps1 -UserName $UserName" -ForegroundColor DarkGray
    return
}

# ======================================================= shell launcher =====

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
Write-Warning 'Desktop mode will not work under Shell Launcher: launching explorer.exe'
Write-Warning 'there opens a File Explorer window rather than the desktop. Reaching the'
Write-Warning 'desktop means switching the shell back and signing out.'
Write-Host "Log '$UserName' out and back in (or reboot) to boot into consolize."
