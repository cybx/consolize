#Requires -RunAsAdministrator
<#
Gets a machine back to a normal, visible Windows when a setup went wrong.

Written to be usable when you can barely see anything: it undoes, in one go, the
changes that can hide the screen or take the desktop away, and says what it did.
Everything else consolize changes (Defender, performance, startup) is left
alone: those have their own -Restore and none of them stop you signing in.

Reachable even from a black screen. Ctrl+Shift+Esc opens Task Manager over any
shell, then File > Run new task, tick "Create this task with administrative
privileges", and run:

    powershell -ExecutionPolicy Bypass -File "C:\Program Files\Consolize\setup\rescue.ps1"

  .\rescue.ps1              # give the screen and the desktop back
  .\rescue.ps1 -KeepShell   # same, but leave the custom shell in place
#>
param(
    [string]$UserName,
    [switch]$KeepShell
)
# Continue, not Stop: a rescue script must get through all of its steps even if
# one of them fails.
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
Write-Host ''
Write-Host '  consolize rescue' -ForegroundColor Cyan
Write-Host ''

# --- 1. make the logon screen visible again ---------------------------------
Write-Host '==> Logon screen visible again' -ForegroundColor Cyan
$logonUI = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
$embeddedLogon = 'HKLM:\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon'
$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

foreach ($item in @(
    @{ Path = $embeddedLogon; Name = 'BrandingNeutral' },
    @{ Path = $embeddedLogon; Name = 'HideAutoLogonUI' },
    @{ Path = $embeddedLogon; Name = 'AnimationDisabled' },
    @{ Path = $logonUI;       Name = 'BrandingNeutral' },
    @{ Path = $logonUI;       Name = 'AnimationDisabled' },
    @{ Path = $policies;      Name = 'DisableStatusMessages' }
)) {
    if (Test-Path $item.Path) {
        Remove-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction SilentlyContinue
    }
}
Write-Host '  the sign-in screen and its status messages are back'

# --- 2. put the desktop back -------------------------------------------------
if ($KeepShell) {
    Write-Host ''
    Write-Host '==> Custom shell left in place (-KeepShell)' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host '==> Desktop back' -ForegroundColor Cyan
    $disable = Join-Path $here 'disable-shell-launcher.ps1'

    $targets = @()
    if ($UserName) {
        $targets += $UserName
    } else {
        # whoever the setup was aiming at, then every enabled local account
        $answers = Join-Path $env:ProgramData 'Consolize\answers.json'
        if (Test-Path $answers) {
            try { $targets += (Get-Content $answers -Raw | ConvertFrom-Json).UserName } catch { }
        }
        $targets += (Get-LocalUser -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled } | Select-Object -ExpandProperty Name)
    }

    $done = @{}
    foreach ($target in ($targets | Where-Object { $_ })) {
        if ($done.ContainsKey($target)) { continue }
        $done[$target] = $true
        if (Test-Path $disable) { & $disable -UserName $target 2>&1 | Out-Null }
    }
    if ($done.Count -gt 0) {
        Write-Host "  custom shell removed for: $(($done.Keys | Sort-Object) -join ', ')"
        Write-Host '  (everyone gets explorer.exe again at the next sign-in)'
    }
}

# --- 3. stop the setup from carrying on --------------------------------------
Write-Host ''
Write-Host '==> Scheduled setup steps cancelled' -ForegroundColor Cyan
foreach ($task in @('ConsolizeFirstLogon', 'ConsolizeFinish')) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
Remove-Item (Join-Path $env:ProgramData 'Consolize\shared\account-ready') -Force -ErrorAction SilentlyContinue
Write-Host '  nothing will try to replace the shell again on its own'

# --- 4. boot messages, so the next failure is visible ------------------------
Write-Host ''
Write-Host '==> Boot messages visible again' -ForegroundColor Cyan
bcdedit.exe /set '{globalsettings}' bootuxdisabled off 2>&1 | Out-Null
bcdedit.exe /deletevalue '{current}' quietboot 2>&1 | Out-Null
bcdedit.exe /deletevalue '{current}' noerrordisplay 2>&1 | Out-Null
bcdedit.exe /deletevalue '{current}' bootstatuspolicy 2>&1 | Out-Null
Write-Host '  the Windows logo and boot errors are shown again'

# --- 5. and a desktop right now, not just after a reboot ---------------------
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
    Start-Process explorer.exe
    Write-Host ''
    Write-Host 'Started Explorer, so you have a desktop right now.'
}

Write-Host ''
Write-Host 'Done. Reboot and you get an ordinary, visible Windows.' -ForegroundColor Green
Write-Host 'Autologon is left as it was; turn it off with:' -ForegroundColor DarkGray
Write-Host '  .\set-autologon.ps1 -UserName <user> -Remove' -ForegroundColor DarkGray
