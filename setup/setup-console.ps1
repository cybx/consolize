#Requires -RunAsAdministrator
<#
Turns this machine into a console. Asks everything up front, then runs to the
end on its own, including across the reboot and the account switch it needs.

  .\setup-console.ps1              # interview, then unattended
  .\setup-console.ps1 -Unattended  # reuse the saved answers, ask nothing
  .\setup-console.ps1 -Finish      # internal: what the finish task calls
  .\setup-console.ps1 -Abort       # cancel a setup in progress, undo the tasks

How it gets from here to a booted console without you driving it:

  1. this script does every machine-wide part, using your answers
  2. it registers two tasks and signs out
  3. the console account logs in by itself (autologon) and a window finishes
     that account: per-user settings, then Steam, because Windows keeps the
     Steam login per user and no administrator can do it for another account
  4. when that account is ready, a SYSTEM task preflights, replaces the shell
     and reboots

The only click that cannot be automated is Tamper Protection, if you ask for
Defender to be fully disabled: Windows deliberately makes that UI-only. You are
still at the machine in step 1, so it happens there.
#>
param(
    [switch]$Unattended,
    [switch]$Finish,
    [switch]$Abort,
    [string]$UserName
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$stateDir = Join-Path $env:ProgramData 'Consolize'
$answersPath = Join-Path $stateDir 'answers.json'
$logDir = Join-Path $stateDir 'logs'
$readyMarker = Join-Path $stateDir 'account-ready'
$taskFirstLogon = 'ConsolizeFirstLogon'
$taskFinish = 'ConsolizeFinish'

New-Item -ItemType Directory -Force -Path $stateDir, $logDir | Out-Null

function Step { param([string]$Text) Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }

function Write-FinishLog {
    param([string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Add-Content (Join-Path $logDir 'finish.log') $line
    Write-Host $line
}

function Remove-ConsolizeTasks {
    foreach ($t in @($taskFirstLogon, $taskFinish)) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ======================================================= abort ===============

if ($Abort) {
    Remove-ConsolizeTasks
    Remove-Item $readyMarker -Force -ErrorAction SilentlyContinue
    Write-Host 'Setup in progress cancelled: scheduled tasks removed.'
    Write-Host 'Everything already applied stays applied. To undo pieces:'
    Write-Host '  .\clean-startup.ps1 -Restore    .\tune-defender.ps1 -Restore'
    Write-Host '  .\tune-performance.ps1 -Restore .\power-console.ps1 -Restore'
    Write-Host '  .\set-autologon.ps1 -UserName <user> -Remove'
    return
}

# ======================================================= finish =============
# Runs as SYSTEM, triggered when the console account logs in. Waits for that
# account to report itself ready, then replaces the shell and reboots.

if ($Finish) {
    $answers = Get-Content $answersPath -Raw | ConvertFrom-Json
    $user = $answers.UserName
    Write-FinishLog "finish task started, waiting for '$user' to be ready"

    $waited = 0
    while (-not (Test-Path $readyMarker) -and $waited -lt 3600) {
        Start-Sleep -Seconds 10
        $waited += 10
    }

    if (-not (Test-Path $readyMarker)) {
        Write-FinishLog 'timed out waiting for the account to be ready; leaving the shell alone'
        return
    }
    Write-FinishLog 'account reported ready, running preflight'

    $preflightOut = & (Join-Path $here 'preflight.ps1') -UserName $user 2>&1
    $preflightOut | ForEach-Object { Write-FinishLog "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-FinishLog 'preflight failed; NOT replacing the shell (this is the safe outcome)'
        Write-FinishLog "fix the issues above, then run: .\setup-console.ps1 -Finish"
        return
    }

    Write-FinishLog 'preflight passed, replacing the shell'
    & (Join-Path $here 'enable-shell-launcher.ps1') -UserName $user -SkipPreflight 2>&1 |
        ForEach-Object { Write-FinishLog "  $_" }

    Remove-ConsolizeTasks
    Remove-Item $readyMarker -Force -ErrorAction SilentlyContinue
    Write-FinishLog 'done, rebooting into console mode'
    shutdown.exe /r /t 20 /c 'consolize: rebooting into console mode'
    return
}

# ======================================================= interview ==========

Write-Host ''
Write-Host '  consolize' -ForegroundColor Cyan
Write-Host '  turns this PC into a couch gaming console'
Write-Host ''

if ($Unattended) {
    if (-not (Test-Path $answersPath)) { throw "No saved answers at $answersPath. Run without -Unattended once." }
    $a = Get-Content $answersPath -Raw | ConvertFrom-Json
    Write-Host 'Reusing saved answers.'
} else {
    function Ask-Yes {
        param([string]$Question, [bool]$Default = $true)
        $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
        while ($true) {
            $answer = Read-Host "  $Question $suffix"
            if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
            if ($answer -match '^[yYsS]') { return $true }
            if ($answer -match '^[nN]') { return $false }
        }
    }
    function Ask-Choice {
        param([string]$Question, [hashtable]$Options, [string]$Default)
        Write-Host "  $Question"
        foreach ($k in $Options.Keys) {
            $mark = if ($k -eq $Default) { '*' } else { ' ' }
            Write-Host ("    {0} {1,-10} {2}" -f $mark, $k, $Options[$k])
        }
        while ($true) {
            $answer = Read-Host "  choice (Enter for $Default)"
            if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
            if ($Options.Contains($answer)) { return $answer }
        }
    }

    Write-Host 'A few questions, then it runs to the end on its own.'
    Write-Host ''

    # --- accounts ---
    Write-Host 'ACCOUNTS' -ForegroundColor Yellow
    Write-Host "  This account ($env:USERNAME) keeps the normal Windows desktop and stays your"
    Write-Host '  way back in. A second account boots into the console.'
    if (-not $UserName) {
        $UserName = Read-Host '  console account name (Enter for "gamer")'
        if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = 'gamer' }
    }
    $userExists = [bool](Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)
    $userPassword = $null
    if (-not $userExists) {
        Write-Host "  '$UserName' does not exist yet and will be created."
        $userPassword = Read-Host "  password for $UserName (Enter for none)" -AsSecureString
    } else {
        Write-Host "  '$UserName' already exists."
    }

    Write-Host ''
    Write-Host 'LAUNCHERS' -ForegroundColor Yellow
    $launchers = @()
    if (Ask-Yes 'Install Steam (Big Picture, the controller-first default)?' $true) { $launchers += 'steam' }
    if (Ask-Yes 'Install Playnite (one library for Steam, Epic, GOG, emulators)?' $false) { $launchers += 'playnite' }
    if (Ask-Yes 'Install Hydra (mouse-first, works as a companion app)?' $false) { $launchers += 'hydra' }
    if (-not $launchers) { $launchers = @('steam'); Write-Host '  nothing chosen, keeping Steam: the console needs a frontend.' }

    $controllerFirst = @($launchers | Where-Object { $_ -in @('steam', 'playnite') })
    if (-not $controllerFirst) { $controllerFirst = @('steam'); $launchers += 'steam' }
    $bootInto = if ($controllerFirst.Count -eq 1) { $controllerFirst[0] } else {
        Ask-Choice 'Which one should the console boot into?' `
            (@{ steam = 'Steam Big Picture'; playnite = 'Playnite Fullscreen' }) $controllerFirst[0]
    }

    Write-Host ''
    Write-Host 'SOFTWARE' -ForegroundColor Yellow
    $updates = Ask-Choice 'Windows updates now?' `
        (@{ all = 'everything (usual answer on IoT LTSC: no feature updates exist here)'
            security = 'security and critical only'
            skip = 'skip for now' }) 'all'
    $wantMedia = Ask-Yes 'Install VLC and mpv (play anything on the TV, no codec pack)?' $true
    $wantTools = Ask-Yes 'Install Git and 7-Zip?' $true
    $wantTorrent = Ask-Yes 'Install qBittorrent and create a torrent folder layout?' $false

    Write-Host ''
    Write-Host 'SYSTEM' -ForegroundColor Yellow
    $defender = Ask-Choice 'Microsoft Defender?' `
        (@{ tune = 'keep it, exclude game folders, scan only when idle'
            disable = 'turn it off entirely (needs one manual Tamper Protection click)' }) 'tune'
    $aggressive = Ask-Yes 'Strip background services (Search indexing, SysMain, telemetry)?' $true
    $restMode = Ask-Choice 'Power button behavior?' `
        (@{ Sleep = 'sleep: resume in ~2s, a USB receiver can wake it'
            Hibernate = 'hibernate: ~15s, survives power loss, only the case button wakes it' }) 'Sleep'
    $autologon = Ask-Yes "Log '$UserName' in automatically at boot (a console does not ask who you are)?" $true

    $a = [pscustomobject]@{
        UserName    = $UserName
        Launchers   = $launchers
        BootInto    = $bootInto
        Updates     = $updates
        Media       = $wantMedia
        Tools       = $wantTools
        Torrent     = $wantTorrent
        Defender    = $defender
        Aggressive  = $aggressive
        RestMode    = $restMode
        Autologon   = $autologon
    }

    Write-Host ''
    Write-Host 'PLAN' -ForegroundColor Yellow
    Write-Host "  console account : $UserName$(if (-not $userExists) { ' (will be created)' })"
    Write-Host "  launchers       : $($launchers -join ', ')  ->  boots into $bootInto"
    Write-Host "  updates         : $updates"
    Write-Host "  defender        : $defender"
    Write-Host "  services        : $(if ($aggressive) { 'trimmed' } else { 'untouched' })"
    Write-Host "  power button    : $restMode"
    Write-Host "  autologon       : $(if ($autologon) { 'yes' } else { 'no' })"
    Write-Host ''
    Write-Host '  After this, the machine signs out, logs into the console account by itself,'
    Write-Host '  walks you through the Steam sign-in, then replaces the shell and reboots.'
    Write-Host ''
    if (-not (Ask-Yes 'Go?' $true)) { Write-Host 'Nothing changed.'; return }

    $a | ConvertTo-Json -Depth 5 | Set-Content $answersPath -Encoding UTF8

    # the password never goes to disk: create the account now, while we have it
    if (-not $userExists) {
        $params = @{ Name = $UserName; FullName = 'Console'; Description = 'consolize console account' }
        if ($userPassword -and $userPassword.Length -gt 0) { $params['Password'] = $userPassword }
        else { $params['NoPassword'] = $true; $params['PasswordNeverExpires'] = $true }
        New-LocalUser @params | Out-Null
        Add-LocalGroupMember -Group 'Users' -Member $UserName -ErrorAction SilentlyContinue
        Write-Host "Console account '$UserName' created."
    }
}

$UserName = $a.UserName

# ======================================================= execute ============

$transcript = Join-Path $logDir 'setup.log'
try { Start-Transcript -Path $transcript -Append | Out-Null } catch { }

$otherAdmins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.ObjectClass -eq 'User' -and $_.Name -notlike "*\$UserName" }
if (-not $otherAdmins) {
    Write-Warning 'No second administrator account exists. That is the way back in if the console misbehaves.'
}

Step 'Windows updates, drivers, runtimes and apps'
$selection = @('gpu', 'runtimes', 'frontends')
if ($a.Updates -ne 'skip') { $selection = @('updates') + $selection }
if ($a.Media) { $selection += 'media' }
if ($a.Tools) { $selection += 'tools' }
if ($a.Torrent) { $selection += 'torrent' }

& (Join-Path $here 'bootstrap-gaming.ps1') `
    -NonInteractive `
    -Items $selection `
    -UpdateScope $(if ($a.Updates -eq 'security') { 'security' } else { 'all' }) `
    -Launchers $a.Launchers `
    -BootInto $a.BootInto

Step 'Quiet layer'
& (Join-Path $here 'quiet-machine.ps1')

Step 'Defender'
if ($a.Defender -eq 'disable') { & (Join-Path $here 'tune-defender.ps1') -Disable -Yes:$false }
else { & (Join-Path $here 'tune-defender.ps1') }

Step 'Performance'
if ($a.Aggressive) { & (Join-Path $here 'tune-performance.ps1') -Aggressive }
else { & (Join-Path $here 'tune-performance.ps1') }

Step 'Power: rest mode'
& (Join-Path $here 'power-console.ps1') -RestMode $a.RestMode

Step 'Emptying Windows startup'
& (Join-Path $here 'clean-startup.ps1') -All

if ($a.Autologon) {
    Step 'Autologon'
    Write-Host "  Enter $UserName's password so the console can log in by itself."
    Write-Host '  It is stored as an LSA secret, never as plaintext.'
    & (Join-Path $here 'set-autologon.ps1') -UserName $UserName
}

# --- the two tasks that carry the rest without you ---------------------------
Step 'Scheduling the rest'
Remove-ConsolizeTasks

# The console account runs as a limited user and has to write the "ready"
# marker here; ProgramData does not grant that by inheritance.
icacls $stateDir /grant "${UserName}:(OI)(CI)M" /T | Out-Null
Write-Host "  $UserName can write to $stateDir"

$firstLogonScript = Join-Path $here 'first-logon.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$firstLogonScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskFirstLogon -Action $action -Trigger $trigger -Principal $principal `
    -Description 'consolize: finish the console account on its first logon' | Out-Null
Write-Host "  $taskFirstLogon registered (runs as $UserName)"

$selfPath = Join-Path $here 'setup-console.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`" -Finish"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries
Register-ScheduledTask -TaskName $taskFinish -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'consolize: replace the shell once the console account is ready' | Out-Null
Write-Host "  $taskFinish registered (runs as SYSTEM, waits for the account)"

try { Stop-Transcript | Out-Null } catch { }

# --- hand off to the machine itself ------------------------------------------
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Green
Write-Host ' Machine setup done. The rest happens by itself.' -ForegroundColor Green
Write-Host '====================================================='
Write-Host ''
Write-Host " Rebooting now. The machine logs into '$UserName' on its own, opens a window"
Write-Host ' to finish that account (Steam sign-in included), then replaces the shell and'
Write-Host ' reboots once more into console mode.'
Write-Host ''
Write-Host ' A reboot rather than a sign-out on purpose: automatic logon is only reliable'
Write-Host ' at boot, and this whole handoff depends on it.'
Write-Host ''
Write-Host " Logs: $logDir"
Write-Host " Changed your mind? Log back in here and run: .\setup-console.ps1 -Abort"
Write-Host ''

if (-not $a.Autologon) {
    Write-Host " Autologon is off, so pick '$UserName' at the logon screen." -ForegroundColor Yellow
    Write-Host ''
}

for ($i = 20; $i -gt 0; $i--) {
    Write-Host -NoNewline "`r Rebooting in $i seconds... (Ctrl+C to stay)   "
    Start-Sleep -Seconds 1
}
Write-Host ''
shutdown.exe /r /t 5 /c 'consolize: continuing setup on the console account'
