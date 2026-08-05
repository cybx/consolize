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
    [ValidateSet('steam', 'playnite', 'custom')] [string]$Frontend = 'steam'
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
$caption = (Get-CimInstance Win32_OperatingSystem).Caption
if ($caption -match 'Enterprise|Education|IoT') {
    Write-Check PASS 'Windows edition supports Shell Launcher' $caption
} else {
    Write-Check FAIL 'Windows edition has no Shell Launcher' "$caption. Needs Enterprise, Education or IoT Enterprise."
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
                $remembered = $raw -match '"RememberPassword"\s+"1"'
                $account = ([regex]::Match($raw, '"AccountName"\s+"([^"]+)"')).Groups[1].Value
                if ($remembered) {
                    Write-Check PASS 'Steam has a saved login' "account: $account"
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
ticked, then re-run. Otherwise the first boot lands on a login window that a
controller cannot fill in.
'@
            }

            # Steam Guard still prompts on a new machine even with remember-me
            $guard = Join-Path $steam 'config\config.vdf'
            if ((Test-Path $guard) -and ((Get-Content $guard -Raw) -notmatch 'SteamGuard|MachineID|Tokens')) {
                Write-Check WARN 'Steam Guard may prompt on first launch' 'Launch Steam once on this machine and clear the code before enabling the shell.'
            }
        }
    }
    'playnite' {
        $pn = Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe'
        if (Test-Path $pn) { Write-Check PASS 'Playnite installed' $pn }
        else { Write-Check FAIL 'Playnite not installed' 'winget install Playnite.Playnite' }
    }
    'custom' { Write-Check WARN 'Custom frontend' 'Check CustomCommand in %LOCALAPPDATA%\Consolize\config.json yourself.' }
}

# --- nothing else fighting for the logon ------------------------------------
$autostart = @()
foreach ($key in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)) {
    if (-not (Test-Path $key)) { continue }
    $props = Get-ItemProperty $key
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        if ($p.Name -match 'steam' -or [string]$p.Value -match 'steam\.exe') { $autostart += $p.Name }
    }
}
if ($autostart.Count -gt 0) {
    Write-Check FAIL 'Steam autostarts on its own' "Entries: $($autostart -join ', '). Two Steams will race at logon. Fix: .\clean-startup.ps1"
} else {
    Write-Check PASS 'No Steam autostart entry' 'consolize owns launching the frontend'
}

# --- accounts ----------------------------------------------------------------
$targetUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($targetUser) {
    Write-Check PASS "User '$UserName' exists" ''
} else {
    Write-Check FAIL "User '$UserName' does not exist" 'Create it, or pass the right -UserName.'
}

$admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "*\$UserName" -and $_.ObjectClass -eq 'User' }
if ($admins) {
    Write-Check PASS 'A second admin account exists' (($admins | ForEach-Object { $_.Name }) -join ', ')
} else {
    Write-Check WARN 'No second admin account' 'Your only way back in would be Ctrl+Shift+Esc > Run new task > explorer.exe. Create a spare admin.'
}

# --- autologon ---------------------------------------------------------------
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$auto = Get-ItemProperty $wl -ErrorAction SilentlyContinue
if ($auto.AutoAdminLogon -eq '1' -and $auto.DefaultUserName) {
    Write-Check PASS 'Autologon configured' "user: $($auto.DefaultUserName)"
} else {
    Write-Check WARN 'Autologon not configured' 'The console will stop at the logon screen. Fix: .\set-autologon.ps1 -UserName ' + $UserName
}
if ($auto.PSObject.Properties.Name -contains 'DefaultPassword') {
    Write-Check FAIL 'Password stored in cleartext' 'DefaultPassword is a plaintext registry value. Fix: .\set-autologon.ps1 -UserName ' + $UserName
}

# --- verdict -----------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) blocking issue(s), $($script:warnings) warning(s). Fix the FAILs before replacing the shell." -ForegroundColor Red
    exit 1
}
if ($script:warnings -gt 0) {
    Write-Host "Ready, with $($script:warnings) warning(s) above." -ForegroundColor Yellow
} else {
    Write-Host 'All clear. Safe to enable the shell.' -ForegroundColor Green
}
exit 0
