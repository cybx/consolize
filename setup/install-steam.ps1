#Requires -RunAsAdministrator
<#
Makes sure Steam is installed and ready to be the console frontend. Idempotent:
if Steam is already there it just reports and exits.

Install routes, in order:
  1. winget (Valve.Steam)
  2. SteamSetup.exe straight from Valve's CDN, silent (/S)
The downloaded installer's Authenticode signature is verified to be Valve's
before it is executed. An unsigned or wrongly-signed file is never run.

After installing, Steam's own autostart entry is removed: consolize is what
launches the frontend, so leaving it means two Steams racing at logon.

  .\install-steam.ps1                  # ensure installed
  .\install-steam.ps1 -LaunchForLogin  # ...then open Steam so you can log in
  .\install-steam.ps1 -CheckLoginOnly  # only report whether a login is saved
#>
param(
    [switch]$LaunchForLogin,
    [switch]$CheckLoginOnly
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-SteamPath {
    foreach ($dir in @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        (Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        (Get-ItemProperty 'HKCU:\SOFTWARE\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath,
        'C:\Program Files (x86)\Steam'
    )) {
        if (-not $dir) { continue }
        $dir = $dir -replace '/', '\'
        if (Test-Path (Join-Path $dir 'steam.exe')) { return $dir }
    }
    return $null
}

function Test-SteamLogin {
    param([string]$SteamDir)
    $vdf = Join-Path $SteamDir 'config\loginusers.vdf'
    if (-not (Test-Path $vdf)) { return [pscustomobject]@{ Saved = $false; Account = $null } }
    $raw = Get-Content $vdf -Raw
    return [pscustomobject]@{
        Saved = [bool]($raw -match '"RememberPassword"\s+"1"')
        Account = ([regex]::Match($raw, '"AccountName"\s+"([^"]+)"')).Groups[1].Value
    }
}

function Remove-SteamAutostart {
    $removed = @()
    foreach ($key in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )) {
        if (-not (Test-Path $key)) { continue }
        $props = Get-ItemProperty $key
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ($p.Name -match 'steam' -or [string]$p.Value -match 'steam\.exe') {
                Remove-ItemProperty -Path $key -Name $p.Name -Force -ErrorAction SilentlyContinue
                $removed += $p.Name
            }
        }
    }
    if ($removed) { Write-Host "  Steam autostart removed ($($removed -join ', ')): consolize launches it instead" }
}

# ---------------------------------------------------------------- check only ---

$steam = Get-SteamPath

if ($CheckLoginOnly) {
    if (-not $steam) { Write-Host 'Steam is not installed.'; exit 1 }
    $login = Test-SteamLogin $steam
    if ($login.Saved) { Write-Host "Saved login found (account: $($login.Account))."; exit 0 }
    Write-Host 'Steam is installed but has no saved login.'
    exit 1
}

# ------------------------------------------------------------------- install ---

if ($steam) {
    Write-Host "Steam already installed: $steam"
} else {
    Write-Host 'Steam not found, installing...'

    $installed = $false

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host '  trying winget (Valve.Steam)...'
        # pinned to the community source: msstore would prompt for the region
        & winget list --source winget --accept-source-agreements *>$null
        winget install --id Valve.Steam --source winget -e --silent `
            --accept-package-agreements --accept-source-agreements
        Start-Sleep -Seconds 3
        if (Get-SteamPath) { $installed = $true; Write-Host '  installed via winget.' }
        else { Write-Warning "  winget did not produce a working install (exit $LASTEXITCODE)." }
    }

    if (-not $installed) {
        Write-Host '  downloading SteamSetup.exe from Valve...'
        $tmp = Join-Path $env:TEMP 'SteamSetup.exe'
        $urls = @(
            'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe',
            'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe',
            'https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe'
        )
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $downloaded = $false
        try {
            foreach ($url in $urls) {
                try {
                    Invoke-WebRequest $url -OutFile $tmp -UseBasicParsing
                    $downloaded = $true
                    Write-Host "  downloaded from $([uri]$url).Host"
                    break
                } catch {
                    Write-Warning "  $url failed: $($_.Exception.Message)"
                }
            }
        } finally {
            $ProgressPreference = $oldProgress
        }
        if (-not $downloaded) { throw 'Could not download SteamSetup.exe from any Valve CDN. Check the network.' }

        # never run an installer we cannot attribute to Valve
        $sig = Get-AuthenticodeSignature $tmp
        if ($sig.Status -ne 'Valid') {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            throw "SteamSetup.exe signature is not valid (status: $($sig.Status)). Refusing to run it."
        }
        if ($sig.SignerCertificate.Subject -notmatch 'Valve') {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            throw "SteamSetup.exe is signed by someone other than Valve ($($sig.SignerCertificate.Subject)). Refusing to run it."
        }
        Write-Host '  signature verified: Valve Corp.'

        Write-Host '  running silent install...'
        $proc = Start-Process $tmp -ArgumentList '/S' -PassThru -Wait
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue

        # the installer returns before the registry settles on some systems
        for ($i = 0; $i -lt 20 -and -not (Get-SteamPath); $i++) { Start-Sleep -Seconds 1 }
        if (-not (Get-SteamPath)) {
            throw "Silent install finished (exit $($proc.ExitCode)) but steam.exe was not found. Install it by hand from https://store.steampowered.com/about/"
        }
        Write-Host '  installed from Valve CDN.'
    }

    $steam = Get-SteamPath
    Write-Host "Steam installed: $steam"
}

Remove-SteamAutostart

# --------------------------------------------------------------------- login ---

$login = Test-SteamLogin $steam
if ($login.Saved) {
    Write-Host ''
    Write-Host "Saved login found (account: $($login.Account)). Big Picture will open unattended." -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host 'Steam has no saved login yet.' -ForegroundColor Yellow
Write-Host 'This matters: with no cached credentials, steam.exe -bigpicture opens the'
Write-Host 'small desktop login window instead of Big Picture. On a console with no'
Write-Host 'Explorer and only a controller, that is a dead end.'
Write-Host ''
Write-Host 'Log in once, with "Remember me" ticked. preflight.ps1 verifies it afterwards.'

if ($LaunchForLogin) {
    Write-Host ''
    Write-Host 'Opening Steam now...'
    Start-Process (Join-Path $steam 'steam.exe')
    Write-Host 'Waiting for a saved login (Ctrl+C to stop waiting)...'
    while (-not (Test-SteamLogin $steam).Saved) { Start-Sleep -Seconds 5 }
    $login = Test-SteamLogin $steam
    Write-Host "Saved login detected (account: $($login.Account))." -ForegroundColor Green

    # Steam re-adds its autostart entry when it runs
    Remove-SteamAutostart
    exit 0
}

exit 1
