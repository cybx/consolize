#Requires -RunAsAdministrator
<#
Turns the console into a media centre as well: your own library and the
streaming services, both reachable from the Steam library with a controller.

Two kinds of thing, and they behave differently, which is worth knowing before
choosing:

  Native players (Kodi, Jellyfin, Plex, Stremio) are real applications. Kodi in
  particular reads a gamepad natively, so it is the one that feels like a
  console. They are the ones worth installing.

  Streaming services (Netflix, Prime Video, Disney+) have no native Windows
  application any more. Netflix's "app" in the Store has been an Edge web app
  since 2024, so on LTSC, which has no Store, nothing is lost by opening the
  site in Edge directly. That is what this does.

Edge and not Chrome, deliberately: Netflix serves 1080p and 4K only to browsers
that can use PlayReady, which on Windows means Edge (Chrome gained it recently
on Windows 11, Firefox is still capped at 720p). A console wired to a television
getting 720p because of the browser would be a strange way to lose.

The honest catch: a web app does not read a gamepad. Inside Steam, the Desktop
layout gives the right stick as a mouse, which is what makes these usable from
the sofa. The native players do not need that.

  .\install-htpc.ps1                                   # asks
  .\install-htpc.ps1 -Apps kodi,jellyfin -Services netflix,primevideo
  .\install-htpc.ps1 -Apps kodi -NonInteractive
#>
param(
    [ValidateSet('kodi', 'jellyfin', 'plex', 'stremio')] [string[]]$Apps,
    [ValidateSet('netflix', 'primevideo', 'disney', 'max', 'globoplay', 'crunchyroll')] [string[]]$Services,
    [switch]$NonInteractive,
    [switch]$NoShortcut
)
$ErrorActionPreference = 'Continue'

$players = [ordered]@{
    kodi     = @{ Id = 'XBMCFoundation.Kodi'; Label = 'Kodi (the one that reads a gamepad natively)'
                  Exe = @('%ProgramFiles%\Kodi\kodi.exe'); Glyph = 'E8B2'; Recommended = $true }
    jellyfin = @{ Id = 'Jellyfin.JellyfinMediaPlayer'; Label = 'Jellyfin Media Player (your own server)'
                  Exe = @('%ProgramFiles%\Jellyfin Media Player\JellyfinMediaPlayer.exe'); Glyph = 'E714'; Recommended = $true }
    plex     = @{ Id = 'Plex.PlexHTPC'; Label = 'Plex HTPC'
                  Exe = @('%ProgramFiles%\Plex\Plex HTPC\Plex HTPC.exe', '%LOCALAPPDATA%\Programs\Plex HTPC\Plex HTPC.exe')
                  Glyph = 'E714'; Recommended = $false }
    stremio  = @{ Id = 'Stremio.Stremio'; Label = 'Stremio'
                  Exe = @('%ProgramFiles%\Stremio\stremio.exe', '%LOCALAPPDATA%\Programs\Stremio\stremio.exe')
                  Glyph = 'E714'; Recommended = $false }
}

$sites = [ordered]@{
    netflix     = @{ Label = 'Netflix';     Url = 'https://www.netflix.com/browse' }
    primevideo  = @{ Label = 'Prime Video'; Url = 'https://www.primevideo.com' }
    disney      = @{ Label = 'Disney+';     Url = 'https://www.disneyplus.com' }
    max         = @{ Label = 'Max';         Url = 'https://play.max.com' }
    globoplay   = @{ Label = 'Globoplay';   Url = 'https://globoplay.globo.com' }
    crunchyroll = @{ Label = 'Crunchyroll'; Url = 'https://www.crunchyroll.com' }
}

function Resolve-Exe {
    param([string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        $path = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path $path) { return $path }
    }
    return $null
}

# --- what to install ---------------------------------------------------------

if (-not $Apps -and -not $Services -and -not $NonInteractive) {
    Write-Host ''
    Write-Host '  Media centre' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Players (real applications, gamepad friendly):'
    foreach ($key in $players.Keys) {
        $mark = if ($players[$key].Recommended) { '*' } else { ' ' }
        Write-Host ("    [{0,-9}] {1} {2}" -f $key, $mark, $players[$key].Label)
    }
    Write-Host ''
    Write-Host '  Services (open in Edge; need Steam''s Desktop layout for a pointer):'
    foreach ($key in $sites.Keys) { Write-Host ("    [{0,-11}] {1}" -f $key, $sites[$key].Label) }
    Write-Host ''
    $answer = Read-Host 'Players: comma list, Enter for the recommended (*), "none"'
    $Apps = if (-not $answer) { @($players.Keys | Where-Object { $players[$_].Recommended }) }
            elseif ($answer -eq 'none') { @() }
            else { @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $players.Contains($_) }) }

    $answer = Read-Host 'Services: comma list, Enter for none'
    $Services = if (-not $answer) { @() }
                else { @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $sites.Contains($_) }) }
}

if ($NonInteractive -and -not $Apps -and -not $Services) {
    $Apps = @($players.Keys | Where-Object { $players[$_].Recommended })
}

$shortcut = Join-Path $PSScriptRoot 'add-app-shortcut.ps1'
$canShortcut = (Test-Path $shortcut) -and -not $NoShortcut

# --- the players -------------------------------------------------------------

foreach ($key in $Apps) {
    $app = $players[$key]
    Write-Host ''
    Write-Host ">> $($app.Label)..." -ForegroundColor Cyan

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning '  winget not available. Run bootstrap-gaming.ps1 first, it bootstraps winget.'
        break
    }

    if (Resolve-Exe $app.Exe) {
        Write-Host '  already installed'
    } else {
        winget install --id $app.Id --source winget -e --silent `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Write-Warning "  winget exited with $LASTEXITCODE" }
    }

    $exe = Resolve-Exe $app.Exe
    if (-not $exe) {
        Write-Warning "  installed, but its executable is not where it was expected."
        Write-Warning "  Add it by hand once you know the path: .\add-app-shortcut.ps1 -Name '$key' -Exe '...'"
        continue
    }
    if ($canShortcut) { & $shortcut -Name $app.Label.Split('(')[0].Trim() -Exe $exe -Glyph $app.Glyph -NoApply }
}

# --- the services ------------------------------------------------------------

if ($Services) {
    $edge = Resolve-Exe @(
        '%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe',
        '%ProgramFiles%\Microsoft\Edge\Application\msedge.exe'
    )
    if (-not $edge) {
        Write-Warning 'Microsoft Edge was not found, so the streaming services were skipped.'
    } else {
        foreach ($key in $Services) {
            $site = $sites[$key]
            Write-Host ''
            Write-Host ">> $($site.Label)..." -ForegroundColor Cyan
            # --app gives a window with no browser furniture, which is the whole
            # point on a television: no tabs, no address bar, no back button
            # sitting over the film. A separate profile directory per service
            # keeps each one signed in on its own.
            $profileDir = Join-Path $env:LOCALAPPDATA "Consolize\web\$key"
            $arguments = "--app=`"$($site.Url)`" --start-fullscreen --user-data-dir=`"$profileDir`""
            if ($canShortcut) { & $shortcut -Name $site.Label -Exe $edge -Arguments $arguments -Glyph 'E714' -NoApply }
            else { Write-Host "  $edge $arguments" }
        }
    }
}

# --- one rewrite at the end --------------------------------------------------
# Each -NoApply above only recorded the entry. Applying once means Steam is
# closed once rather than once per app.
if ($canShortcut) {
    Write-Host ''
    & (Join-Path $PSScriptRoot 'add-console-shortcuts.ps1') -Force
}

if ($Services) {
    Write-Host ''
    Write-Host 'About the services, so it is not a surprise on the sofa:' -ForegroundColor Cyan
    Write-Host '  They are web apps, and a web app does not read a gamepad. In Steam, set'
    Write-Host '  Settings > Controller > Desktop layout to one with right-stick mouse, and'
    Write-Host '  bind a chord to the on-screen keyboard for signing in.'
    Write-Host '  Edge is used on purpose: Netflix only serves 1080p and 4K to browsers that'
    Write-Host '  can use PlayReady. Firefox would cap the television at 720p.'
}
