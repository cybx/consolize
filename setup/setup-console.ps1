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
    [string]$UserName,
    # NetFx3 pulls ~250 MB from Windows Update and can take 15 minutes; handy
    # when resuming a run that already spent that time, or on a slow link.
    [switch]$SkipNetFx3,
    # How the shell gets replaced. registry keeps desktop mode working, which is
    # why it is the default; see enable-shell-launcher.ps1 for the trade.
    [ValidateSet('registry', 'shelllauncher')] [string]$ShellMethod = 'registry'
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$stateDir = Join-Path $env:ProgramData 'Consolize'
$answersPath = Join-Path $stateDir 'answers.json'
$logDir = Join-Path $stateDir 'logs'
# The only place the console account is allowed to write. Keeping it separate
# from the scripts and answers.json is what stops a writable file from turning
# into SYSTEM execution at the next logon.
$sharedDir = Join-Path $stateDir 'shared'
$readyMarker = Join-Path $sharedDir 'account-ready'
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
    try {
        $answers = Get-Content $answersPath -Raw | ConvertFrom-Json
    } catch {
        Write-FinishLog "cannot read $answersPath : $($_.Exception.Message)"
        return
    }
    $user = $answers.UserName
    Write-FinishLog "finish task started, waiting for '$user' to be ready"

    # A marker naming a different account is left over from an earlier run and
    # must not be taken as "this account finished phase 2".
    if (Test-Path $readyMarker) {
        $markerUser = (Get-Content $readyMarker -Raw -ErrorAction SilentlyContinue).Trim()
        if ($markerUser -and $markerUser -ne $user) {
            Write-FinishLog "discarding a ready marker left by '$markerUser'"
            Remove-Item $readyMarker -Force -ErrorAction SilentlyContinue
        }
    }

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

    # *>&1, not 2>&1: preflight reports through Write-Host, which is stream 6.
    # With 2>&1 the log recorded "fix the issues above" and no issues.
    $frontend = if ($answers.BootInto) { $answers.BootInto } else { 'steam' }
    $finishMethod = if ($answers.ShellMethod) { $answers.ShellMethod } else { 'registry' }
    $preflightOut = & (Join-Path $here 'preflight.ps1') -UserName $user -Frontend $frontend -Method $finishMethod *>&1
    $preflightOut | ForEach-Object { Write-FinishLog "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-FinishLog 'preflight failed; NOT replacing the shell (this is the safe outcome)'
        Write-FinishLog 'fix the issues above, then run: setup-console.ps1 -Finish'
        return
    }

    Write-FinishLog 'preflight passed, replacing the shell'
    try {
        & (Join-Path $here 'enable-shell-launcher.ps1') -UserName $user -Method $finishMethod -SkipPreflight *>&1 |
            ForEach-Object { Write-FinishLog "  $_" }

        # Only now: everything before this point can fail, and a hidden logon
        # screen would turn any such failure into a black screen with no way in.
        & (Join-Path $here 'boot-silent.ps1') -IncludeLogon *>&1 |
            ForEach-Object { Write-FinishLog "  $_" }
    } catch {
        Write-FinishLog "FAILED to replace the shell: $($_.Exception.Message)"
        Write-FinishLog 'the machine still boots to the desktop; tasks left in place to retry'
        return
    }

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
        Write-Host '  You type this password once: the console signs in by itself afterwards,'
        Write-Host '  from an LSA secret, never from anything written to disk in the clear.'

        # Never leave it blank. An account with no password makes Windows stop at
        # the logon screen asking to set one, and automatic logon never fires.
        $asked = 0
        while ($true) {
            $userPassword = Read-Host "  password for $UserName" -AsSecureString
            if ($userPassword.Length -gt 0) { break }

            if ($asked -eq 0) {
                Write-Host ''
                Write-Host '  An empty password does not work here: Windows stops at the logon' -ForegroundColor Yellow
                Write-Host '  screen demanding one, and the console never logs itself in.' -ForegroundColor Yellow
                Write-Host "  Type a password, or press Enter again to use '$UserName'." -ForegroundColor Yellow
                $asked++
                continue
            }

            $userPassword = ConvertTo-SecureString $UserName -AsPlainText -Force
            Write-Host ''
            Write-Host "  Using '$UserName' as the password." -ForegroundColor Yellow
            Write-Host '  Worth knowing: it is as weak as it looks, so anyone at the keyboard can'
            Write-Host '  sign in. Fine for a console on your TV, not for a machine on a desk'
            Write-Host '  someone else uses. Change it any time with:'
            Write-Host "    Set-LocalUser -Name $UserName -Password (Read-Host -AsSecureString)"
            Write-Host "    .\set-autologon.ps1 -UserName $UserName"
            break
        }
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
        ShellMethod = $ShellMethod
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

    # kept in memory only; the password must never reach answers.json
    $script:newUserPassword = $userPassword
}

$UserName = $a.UserName

# ======================================================= execute ============

$transcript = Join-Path $logDir 'setup.log'
try { Start-Transcript -Path $transcript -Append | Out-Null } catch { }

# A marker from an earlier attempt would let the finish task skip the wait and
# replace the shell for an account that never completed phase 2.
Remove-Item $readyMarker -Force -ErrorAction SilentlyContinue

# --- console account ---------------------------------------------------------
# Created here rather than during the interview, so a resumed run (-Unattended,
# which never sees the interview) still ends up with the account.
if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
    Step "Creating the console account '$UserName'"

    $password = $script:newUserPassword
    if (-not $password -and -not $Unattended) {
        $password = Read-Host "  password for $UserName (Enter to use '$UserName')" -AsSecureString
    }
    # Resumed unattended, or the prompt came back empty: fall back to the account
    # name rather than creating a passwordless account, which Windows treats as
    # "must set a password at the next sign-in" and which breaks autologon.
    if (-not $password -or $password.Length -eq 0) {
        $password = ConvertTo-SecureString $UserName -AsPlainText -Force
        Write-Host "  no password given, using '$UserName'"
    }

    # Always with a password. A passwordless account is one Windows stops and
    # demands a password for at sign-in, which kills autologon, and the fallback
    # above guarantees there is one to use.
    # FullName matches the account name on purpose: the logon screen shows the
    # display name, so a FullName of "Console" put a user called "Console" on
    # screen while every command and every doc says "gamer".
    New-LocalUser -Name $UserName -Password $password -FullName $UserName `
        -Description 'consolize console account' -PasswordNeverExpires | Out-Null

    Add-LocalGroupMember -Group 'Users' -Member $UserName -ErrorAction SilentlyContinue
    Write-Host "  '$UserName' created."
}

# An account with no PasswordLastSet is one Windows will stop and demand a
# password for, so autologon can never happen. Fix it by setting THE SAME
# password autologon will use: an empty one here would leave the account and the
# stored credential disagreeing, which shows up as "password incorrect" at every
# boot with no clue why.
$account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($account -and -not $account.PasswordLastSet) {
    $repair = $script:newUserPassword
    if (-not $repair -or $repair.Length -eq 0) { $repair = ConvertTo-SecureString $UserName -AsPlainText -Force }
    try {
        Set-LocalUser -Name $UserName -Password $repair -ErrorAction Stop
        $script:newUserPassword = $repair
        Write-Host "  '$UserName' had no password set; gave it the one autologon will use"
    } catch {
        Write-Warning "  could not set the password: $($_.Exception.Message)"
    }
}
try { Set-LocalUser -Name $UserName -PasswordNeverExpires $true -ErrorAction Stop } catch { }

# Earlier runs set the display name to "Console", which is what the logon screen
# shows; make it match the account name so the screen and the docs agree.
if ($account -and $account.FullName -eq 'Console') {
    try {
        Set-LocalUser -Name $UserName -FullName $UserName -ErrorAction Stop
        Write-Host "  display name corrected from 'Console' to '$UserName'"
    } catch { }
}

$otherAdmins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.ObjectClass -eq 'User' -and $_.Name -notlike "*\$UserName" }
if (-not $otherAdmins) {
    Write-Warning 'No second administrator account exists. That is the way back in if the console misbehaves.'
}

# --- everything that needs a human, before anything long ---------------------
# Turning Defender off requires flipping Tamper Protection by hand, because
# Windows allows no other way. Doing it here, rather than after half an hour of
# downloads, means the last question is asked in the first minute and you can
# walk away from the machine for good.
if ($a.Defender -eq 'disable') {
    Step 'Defender off (the one step that needs you)'
    & (Join-Path $here 'tune-defender.ps1') -Disable -Confirmed -SkipExclusions
}

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Green
Write-Host ' Nothing else will ask you anything.' -ForegroundColor Green
Write-Host '====================================================='
Write-Host ' From here it installs, configures and reboots on its own. Expect'
Write-Host ' anywhere from a few minutes to about an hour, mostly Windows updates.'
Write-Host " Progress is written to $logDir\setup.log as it goes."
Write-Host ''

Step 'Windows updates, drivers, runtimes and apps'
$selection = @('gpu', 'runtimes', 'frontends')
if ($a.Updates -ne 'skip') { $selection = @('updates') + $selection }
if ($a.Media) { $selection += 'media' }
if ($a.Tools) { $selection += 'tools' }
if ($a.Torrent) { $selection += 'torrent' }

& (Join-Path $here 'bootstrap-gaming.ps1') `
    -NonInteractive `
    -SkipNetFx3:$SkipNetFx3 `
    -Items $selection `
    -UpdateScope $(if ($a.Updates -eq 'security') { 'security' } else { 'all' }) `
    -Launchers $a.Launchers `
    -BootInto $a.BootInto

Step 'Quiet layer'
& (Join-Path $here 'quiet-machine.ps1')

Step 'Silent boot (no logo)'
# Without -IncludeLogon on purpose: the logon screen stays visible until the
# console is actually working, so a failure here never hides the way back in.
& (Join-Path $here 'boot-silent.ps1')

Step 'Defender exclusions'
# Always the tune pass here, never the disable: that already happened up front,
# and exclusions need the game folders, which only exist now.
& (Join-Path $here 'tune-defender.ps1')

Step 'Performance'
if ($a.Aggressive) { & (Join-Path $here 'tune-performance.ps1') -Aggressive }
else { & (Join-Path $here 'tune-performance.ps1') }

Step 'Power: rest mode'
& (Join-Path $here 'power-console.ps1') -RestMode $a.RestMode

Step 'Emptying Windows startup'
# -MachineOnly on purpose: HKCU here is the ADMINISTRATOR's, and silently
# emptying their OneDrive, password manager and VPN is not what anyone asked
# for. The console account's own startup is cleaned in its session, at phase 2.
& (Join-Path $here 'clean-startup.ps1') -All -MachineOnly

if ($a.Autologon) {
    Step 'Autologon'
    if ($script:newUserPassword -and $script:newUserPassword.Length -gt 0) {
        Write-Host '  Reusing the password you already typed; stored as an LSA secret.'
        & (Join-Path $here 'set-autologon.ps1') -UserName $UserName -Password $script:newUserPassword
    } else {
        Write-Host "  Enter $UserName's password so the console can log in by itself."
        Write-Host '  It is stored as an LSA secret, never as plaintext.'
        & (Join-Path $here 'set-autologon.ps1') -UserName $UserName
    }
}

# --- the two tasks that carry the rest without you ---------------------------
Step 'Scheduling the rest'
Remove-ConsolizeTasks

# ProgramData hands BUILTIN\Users Write on everything below it, and answers.json
# here is read by a SYSTEM task that acts on what it says. Drop inheritance and
# put it back as read-only for ordinary users.
icacls $stateDir /inheritance:r /grant 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'Users:(OI)(CI)RX' | Out-Null

# The console account still has to write the "ready" marker, so grant exactly
# one subfolder and nothing else.
New-Item -ItemType Directory -Force -Path $sharedDir | Out-Null
icacls $sharedDir /grant "${UserName}:(OI)(CI)M" | Out-Null
Write-Host "  $UserName can write to $sharedDir (and nothing else here)"

# Refuse to arm a SYSTEM task whose script a non-admin could rewrite.
$scriptAcl = (Get-Acl $here).Access | Where-Object {
    $_.FileSystemRights -match 'Write|Modify|FullControl' -and
    $_.AccessControlType -eq 'Allow' -and
    $_.IdentityReference -notmatch 'SYSTEM|Administrators|TrustedInstaller|CREATOR OWNER'
}
if ($scriptAcl) {
    throw @"
$here is writable by $($scriptAcl.IdentityReference -join ', '), and the finish
task would run it as SYSTEM at every logon. Refusing.

This is what an install under C:\ProgramData looks like: that tree grants
BUILTIN\Users Write. Reinstall to the safe location and resume:

  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cybx/consolize/main/get.ps1))) -UpdateOnly
  cd 'C:\Program Files\Consolize\setup'
  .\setup-console.ps1 -Unattended
"@
}

# Both tasks need the same battery policy. Without it a task inherits
# DisallowStartIfOnBatteries, so on a handheld or an unplugged laptop phase 2
# would simply never fire, with only a Task Scheduler event to show for it.
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$firstLogonScript = Join-Path $here 'first-logon.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$firstLogonScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskFirstLogon -Action $action -Trigger $trigger -Principal $principal `
    -Settings $taskSettings -Description 'consolize: finish the console account on its first logon' | Out-Null
Write-Host "  $taskFirstLogon registered (runs as $UserName)"

$selfPath = Join-Path $here 'setup-console.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`" -Finish"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskFinish -Action $action -Trigger $trigger -Principal $principal `
    -Settings $taskSettings -Description 'consolize: replace the shell once the console account is ready' | Out-Null
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
