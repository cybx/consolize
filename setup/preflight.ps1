#Requires -RunAsAdministrator
<#
Checks everything that would ruin the first boot AFTER the shell is already
replaced, which is the worst moment to find out. Run it before
enable-shell-launcher.ps1 (which calls it for you).

The one that bites everyone: Steam with no saved login does not open in Big
Picture, it opens the small desktop login window. With no Explorer and only a
controller in your hand, that is a dead end.

    .\preflight.ps1 -UserName gamer
#>
param(
    [string]$UserName = 'gamer',
    [string]$ShellPath = 'C:\Program Files\Consolize\consolize.exe',
    [ValidateSet('steam', 'playnite', 'hydra', 'custom')] [string]$Frontend = 'steam',
    [ValidateSet('registry', 'shelllauncher')] [string]$Method = 'registry',
    # setup-console.ps1 and enable-shell-launcher.ps1 invoke this script in the
    # same PowerShell process. A bare exit here terminates those parent scripts
    # before they can enable the shell, so embedded callers opt into return.
    [switch]$NoExit
)
$ErrorActionPreference = 'Continue'

$script:failures = 0
$script:warnings = 0

function Write-Check {
    param([ValidateSet('PASS', 'WARN', 'FAIL')] [string]$Result, [string]$Name, [string]$Detail)
    $color = switch ($Result) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } }
    Write-Host ("  [{0}] {1}" -f $Result, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray }
    if ($Result -eq 'FAIL') { $script:failures++ }
    if ($Result -eq 'WARN') { $script:warnings++ }
}

# This script runs as SYSTEM from the finish task, so HKCU: is SYSTEM's own
# hive and every per-user check through it is vacuous. Read the target account's
# hive instead, mounting NTUSER.DAT when that user is not signed in.
function Get-UserHiveValue {
    param([string]$User, [string]$SubKey, [string]$Name)

    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $null
    }

    $hive = "Registry::HKEY_USERS\$sid"
    $mounted = $null
    if (-not (Test-Path $hive)) {
        $profileDir = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.SID -eq $sid } | Select-Object -First 1).LocalPath
        if (-not $profileDir) { return $null }
        $dat = Join-Path $profileDir 'NTUSER.DAT'
        if (-not (Test-Path $dat)) { return $null }

        $mounted = "consolize-$sid"
        & reg.exe load "HKU\$mounted" $dat *>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $hive = "Registry::HKEY_USERS\$mounted"
    }

    try {
        $key = Join-Path $hive $SubKey
        if (-not (Test-Path $key)) { return $null }
        return (Get-ItemProperty -Path $key -Name $Name -ErrorAction SilentlyContinue).$Name
    } finally {
        if ($mounted) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$mounted" *>$null
        }
    }
}

function Get-SteamPath {
    foreach ($dir in @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        (Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        'C:\Program Files (x86)\Steam'
    )) {
        if ($dir -and (Test-Path (Join-Path $dir 'steam.exe'))) { return $dir }
    }
    return $null
}

Write-Host ''
Write-Host 'consolize preflight' -ForegroundColor Cyan
Write-Host ''

# --- Windows edition ---------------------------------------------------------
# Only the Shell Launcher method needs a particular edition. The per-user
# registry shell, which is the default, works everywhere.
$caption = (Get-CimInstance Win32_OperatingSystem).Caption
if ($Method -eq 'shelllauncher') {
    if ($caption -match 'Enterprise|Education|IoT') {
        Write-Check PASS 'Windows edition supports Shell Launcher' $caption
    } else {
        Write-Check FAIL 'Windows edition has no Shell Launcher' "$caption. Needs Enterprise, Education or IoT Enterprise, or use -Method registry."
    }
} else {
    Write-Check PASS 'Shell method: per-user registry' "$caption (no edition requirement)"
}

# --- consolize installed -----------------------------------------------------
if (Test-Path $ShellPath) {
    Write-Check PASS 'consolize.exe installed' $ShellPath
} else {
    Write-Check FAIL 'consolize.exe missing' "Expected at $ShellPath. Run the installer one-liner or install.ps1."
}

# --- frontend present --------------------------------------------------------
switch ($Frontend) {
    'steam' {
        $steam = Get-SteamPath
        if ($steam) {
            Write-Check PASS 'Steam installed' $steam
        } else {
            Write-Check FAIL 'Steam not installed' 'Run bootstrap-gaming.ps1, or winget install Valve.Steam'
        }

        # --- Steam saved login: the classic first-boot trap -------------------
        if ($steam) {
            $vdf = Join-Path $steam 'config\loginusers.vdf'
            if (Test-Path $vdf) {
                $raw = Get-Content $vdf -Raw
                # Same predicate as first-logon.ps1: the QR sign-in never shows
                # the "remember me" checkbox and writes AutoLogin instead, so
                # demanding RememberPassword alone failed the exact sign-in this
                # project recommends.
                $remembered = $raw -match '"(RememberPassword|AutoLogin)"\s+"1"'
                $account = ([regex]::Match($raw, '"AccountName"\s+"([^"]+)"')).Groups[1].Value

                # loginusers.vdf is machine-wide, so it says nothing about THIS
                # account: the installing admin's own sign-in would pass it.
                # The autologin account is per user, and that is what decides
                # whether Big Picture comes up signed in.
                $autoLogin = Get-UserHiveValue -User $UserName -SubKey 'SOFTWARE\Valve\Steam' -Name 'AutoLoginUser'

                if ($remembered -and $autoLogin) {
                    Write-Check PASS 'Steam has a saved login' "account: $account (signed in as $UserName)"
                } elseif ($remembered -and -not $autoLogin) {
                    Write-Check FAIL "Steam is signed in, but not on '$UserName'" @"
Windows keeps the Steam login per user, and the console account has no
AutoLoginUser. Sign in to Steam while logged in as $UserName, not from this
account, or the first boot lands on a login window a controller cannot fill in.
"@
                } else {
                    Write-Check FAIL 'Steam login is not saved' @'
Big Picture will not open; you get the desktop login window with no Explorer
behind it. Fix: open Steam in this session, log in with "Remember me" ticked,
confirm Big Picture opens, then re-run.
'@
                }
            } else {
                Write-Check FAIL 'Steam was never logged in' @'
No config\loginusers.vdf yet. Open Steam once, log in with "Remember me"
ticked and clear any Steam Guard code, then re-run. Otherwise the first boot
lands on a login window that a controller cannot fill in.
'@
            }
        }
    }
    'playnite' {
        # Playnite installs per user by default, so it has to exist in the
        # CONSOLE account's profile, not in the profile running this check.
        $profileDir = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -like "*\$UserName" } | Select-Object -First 1).LocalPath
        $candidates = @()
        if ($profileDir) { $candidates += (Join-Path $profileDir 'AppData\Local\Playnite\Playnite.FullscreenApp.exe') }
        $candidates += (Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe')
        $candidates += 'C:\Program Files\Playnite\Playnite.FullscreenApp.exe'

        $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($found -and $profileDir -and $found -like "$profileDir*") {
            Write-Check PASS 'Playnite installed for the console account' $found
        } elseif ($found) {
            Write-Check FAIL "Playnite is installed, but not for '$UserName'" @"
Found at $found. Playnite installs per user, so the console account cannot see
it and the frontend would never start. Install it while signed in as $UserName.
"@
        } else {
            Write-Check FAIL 'Playnite not installed' 'winget install Playnite.Playnite'
        }
    }
    'hydra' {
        # Hydra installs per user, like Playnite, so it has to exist in the
        # console account's profile rather than the one running this check.
        $profileDir = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -like "*\$UserName" } | Select-Object -First 1).LocalPath
        $found = $null
        if ($profileDir) {
            $candidate = Join-Path $profileDir 'AppData\Local\Programs\Hydra\Hydra.exe'
            if (Test-Path $candidate) { $found = $candidate }
        }
        if ($found) {
            Write-Check PASS 'Hydra installed for the console account' $found
            Write-Check WARN 'Hydra is mouse-first' 'It is not gamepad navigable, so it works better launched from Steam or Playnite than as the shell frontend itself.'
        } else {
            Write-Check FAIL "Hydra not installed for '$UserName'" 'It installs per user: install it while signed in as that account.'
        }
    }
    'custom' { Write-Check WARN 'Custom frontend' 'Check CustomCommand in %LOCALAPPDATA%\Consolize\config.json yourself.' }
}

# --- a way out of the frontend ----------------------------------------------
# The last check to be added and arguably the one that matters most. Everything
# above can pass on a machine that boots into Big Picture with no Desktop Mode
# entry in the library, and that machine has no way to reach Windows with a
# controller: the tray icon only exists once the desktop is already up. This
# used to be approved and shipped.
if ($Frontend -eq 'steam') {
    $steamRoot = Get-UserHiveValue -User $UserName -SubKey 'SOFTWARE\Valve\Steam' -Name 'SteamPath'
    if ($steamRoot) { $steamRoot = $steamRoot -replace '/', '\' }
    if (-not $steamRoot -or -not (Test-Path $steamRoot)) { $steamRoot = 'C:\Program Files (x86)\Steam' }

    $found = @()
    foreach ($profile in @(Get-ChildItem (Join-Path $steamRoot 'userdata') -Directory -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -ne '0' })) {
        $vdf = Join-Path $profile.FullName 'config\shortcuts.vdf'
        if (-not (Test-Path $vdf)) { continue }

        # Only the names, and only the ones Steam will actually load: a name can
        # sit in a file whose shortcuts map already closed, where Steam never
        # looks for it, and reading the bytes flat would call that present.
        $bytes = [IO.File]::ReadAllBytes($vdf)
        $pos = 0; $depth = 1
        try {
            while ($pos -lt $bytes.Length) {
                $type = $bytes[$pos]; $pos++
                if ($type -eq 8) { $depth--; continue }
                $start = $pos
                while ($pos -lt $bytes.Length -and $bytes[$pos] -ne 0) { $pos++ }
                $key = [Text.Encoding]::UTF8.GetString($bytes, $start, $pos - $start); $pos++
                if ($type -eq 0) { $depth++ }
                elseif ($type -eq 1) {
                    $start = $pos
                    while ($pos -lt $bytes.Length -and $bytes[$pos] -ne 0) { $pos++ }
                    if ($key -eq 'AppName' -and $depth -eq 3) {
                        $found += [Text.Encoding]::UTF8.GetString($bytes, $start, $pos - $start)
                    }
                    $pos++
                }
                elseif ($type -eq 2) { $pos += 4 }
                else { break }
            }
        } catch { }
    }

    if ($found -contains 'Desktop Mode') {
        Write-Check PASS 'Desktop Mode is in the Steam library' 'the console has a way back to Windows'
    } else {
        Write-Check FAIL 'No Desktop Mode entry in the Steam library' @'
This machine would boot into Big Picture with no way to reach Windows using
only a controller. Fix:
  .\add-console-shortcuts.ps1 -Force
and if the library already has strays from an earlier run:
  .\add-console-shortcuts.ps1 -Remove -Force
  .\add-console-shortcuts.ps1 -Force
'@
    }
} elseif ($Frontend -in @('playnite', 'hydra')) {
    # The Steam check reads shortcuts.vdf; these keep their libraries in
    # databases this script does not parse, so the way out cannot be verified
    # from here, only insisted upon.
    Write-Check WARN "The way out of $Frontend cannot be verified" @"
Add an entry to $Frontend's own library that runs:
  "C:\Program Files\Consolize\consolize.exe" send desktop
Without one, the desktop is only reachable through the Quick Settings chord
(hold Start+Back, Power page) or Ctrl+Shift+Esc with a keyboard.
"@
}

# --- nothing else fighting for the logon ------------------------------------
# Any frontend, not only Steam: a Playnite or Hydra autostart entry races the
# one consolize launches just the same.
$autostart = @()
foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
    if (-not (Test-Path $key)) { continue }
    $props = Get-ItemProperty $key
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        if ($p.Name -match 'steam|playnite|hydra' -or
            [string]$p.Value -match 'steam\.exe|playnite[.\w]*\.exe|hydra\.exe') { $autostart += $p.Name }
    }
}
# the per-user Run key of the CONSOLE account, which is the one that matters and
# is not HKCU: from here
foreach ($name in @('Steam', 'Playnite', 'Hydra')) {
    $value = Get-UserHiveValue -User $UserName -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name $name
    if ($value) { $autostart += "$name (in $UserName's profile)" }
}
if ($autostart.Count -gt 0) {
    Write-Check FAIL 'A frontend autostarts on its own' "Entries: $($autostart -join ', '). Two frontends will race at logon. Fix: .\clean-startup.ps1"
} else {
    Write-Check PASS 'No frontend autostart entry' 'consolize owns launching the frontend'
}

# --- accounts ----------------------------------------------------------------
$targetUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($targetUser) {
    Write-Check PASS "User '$UserName' exists" ''

    # An account whose password was never set has no PasswordLastSet, and
    # Windows reads that as "must set a password at the next sign-in": it stops
    # at the logon screen and automatic logon never fires.
    if (-not $targetUser.PasswordLastSet) {
        Write-Check FAIL "'$UserName' would be asked to set a password" @"
Its password has never been set (PasswordLastSet is empty), so Windows stops at
the logon screen asking for one and autologon does not happen. Fix:
  Set-LocalUser -Name $UserName -Password (New-Object System.Security.SecureString)
  Set-LocalUser -Name $UserName -PasswordNeverExpires `$true
"@
    } elseif ($targetUser.PasswordExpires -and $targetUser.PasswordExpires -lt (Get-Date)) {
        Write-Check FAIL "'$UserName' has an expired password" @"
Windows will demand a new one at sign-in, which a controller cannot type. Fix:
  Set-LocalUser -Name $UserName -PasswordNeverExpires `$true
"@
    }
} else {
    Write-Check FAIL "User '$UserName' does not exist" 'Create it, or pass the right -UserName.'
}

# --- the screens that appear before the frontend ever starts -----------------
$privacyPolicy = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' `
    -Name DisablePrivacyExperience -ErrorAction SilentlyContinue).DisablePrivacyExperience
if ($privacyPolicy -eq 1) {
    Write-Check PASS 'Privacy settings screen suppressed' ''
} else {
    Write-Check FAIL 'Privacy settings screen would appear' @'
A new account's first sign-in lands on "choose privacy settings" full screen,
which needs a mouse and blocks the frontend. Fix: .\quiet-machine.ps1
'@
}

$administratorsGroup = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue
$admins = Get-LocalGroupMember -Group $administratorsGroup.Name -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "*\$UserName" -and $_.ObjectClass -eq 'User' }
if ($admins) {
    Write-Check PASS 'A second admin account exists' (($admins | ForEach-Object { $_.Name }) -join ', ')
} else {
    Write-Check WARN 'No second admin account' 'Your only way back in would be Ctrl+Shift+Esc > Run new task > explorer.exe. Create a spare admin.'
}

# --- autologon ---------------------------------------------------------------
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$auto = Get-ItemProperty $wl -ErrorAction SilentlyContinue
if ($auto.AutoAdminLogon -eq '1' -and $auto.DefaultUserName -eq $UserName) {
    Write-Check PASS 'Autologon configured' "user: $($auto.DefaultUserName)"
} elseif ($auto.AutoAdminLogon -eq '1' -and $auto.DefaultUserName) {
    # Pointing at the wrong account is worse than not being set at all: it looks
    # configured and the machine still stops at a logon screen.
    Write-Check FAIL "Autologon points at '$($auto.DefaultUserName)', not '$UserName'" @"
The console account is the one that has to log in by itself. Fix:
  .\set-autologon.ps1 -UserName $UserName
"@
} else {
    Write-Check WARN 'Autologon not configured' "The console will stop at the logon screen. Fix: .\set-autologon.ps1 -UserName $UserName"
}
if ($auto -and ($auto.PSObject.Properties.Name -contains 'DefaultPassword')) {
    Write-Check FAIL 'Password stored in cleartext' "DefaultPassword is a plaintext registry value. Fix: .\set-autologon.ps1 -UserName $UserName"
}

# --- verdict -----------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) blocking issue(s), $($script:warnings) warning(s). Fix the FAILs before replacing the shell." -ForegroundColor Red
    if ($NoExit) { $global:LASTEXITCODE = 1; return }
    exit 1
}
if ($script:warnings -gt 0) {
    Write-Host "Ready, with $($script:warnings) warning(s) above." -ForegroundColor Yellow
} else {
    Write-Host 'All clear. Safe to enable the shell.' -ForegroundColor Green
}
if ($NoExit) { $global:LASTEXITCODE = 0; return }
exit 0
