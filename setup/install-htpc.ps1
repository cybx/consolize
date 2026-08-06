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
    # How much to enlarge the streaming sites. A web page is laid out to be read
    # from half a metre away; a television is watched from three. 1.0 leaves
    # them at desktop size.
    [ValidateRange(1.0, 3.0)] [double]$Scale = 1.5,
    [ValidateSet('all', 'machine', 'user')] [string]$Phase = 'all',
    [switch]$NonInteractive,
    [switch]$NoShortcut,
    [switch]$DeferApply
)
$ErrorActionPreference = 'Continue'

$players = [ordered]@{
    kodi     = @{ Id = 'XBMCFoundation.Kodi'; Label = 'Kodi (the one that reads a gamepad natively)'
                  Exe = @('%ProgramFiles%\Kodi\kodi.exe'); Glyph = 'E8B2'; Recommended = $true
                  InstallPhase = 'machine'; Scope = $null }
    jellyfin = @{ Id = 'Jellyfin.JellyfinMediaPlayer'; Label = 'Jellyfin Media Player (your own server)'
                  Exe = @('%ProgramFiles%\Jellyfin\Jellyfin Media Player\JellyfinMediaPlayer.exe',
                          '%ProgramFiles%\Jellyfin Media Player\JellyfinMediaPlayer.exe')
                  Glyph = 'E714'; Recommended = $true
                  InstallPhase = 'machine'; Scope = 'machine' }
    plex     = @{ Id = 'Plex.PlexHTPC'; Label = 'Plex HTPC'
                  Exe = @('%ProgramFiles%\Plex\Plex HTPC\Plex HTPC.exe')
                  Glyph = 'E714'; Recommended = $false; InstallPhase = 'machine'; Scope = 'machine' }
    stremio  = @{ Id = 'Stremio.Stremio'; Label = 'Stremio'
                  Exe = @('%LOCALAPPDATA%\Programs\LNV\Stremio-4\stremio.exe')
                  Glyph = 'E714'; Recommended = $false; InstallPhase = 'user'; Scope = 'user' }
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
$canShortcut = (Test-Path $shortcut) -and -not $NoShortcut -and $Phase -ne 'machine'
$wingetExe = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if (-not $wingetExe -and $Phase -ne 'machine') {
    # App Installer may be provisioned for Windows but not registered in this
    # newly-created console profile yet. Registration is per-user and does not
    # require turning a user-scope install into an administrator install.
    try {
        Add-AppxPackage -RegisterByFamilyName `
            -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
    } catch { }
    $wingetExe = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
}

# --- the players -------------------------------------------------------------

foreach ($key in $Apps) {
    $app = $players[$key]
    $installHere = $Phase -eq 'all' -or $Phase -eq $app.InstallPhase
    if (-not $installHere -and -not $canShortcut) { continue }
    Write-Host ''
    Write-Host ">> $($app.Label)..." -ForegroundColor Cyan

    $exe = Resolve-Exe $app.Exe
    if (-not $wingetExe -and -not $exe -and $installHere) {
        Write-Warning '  winget not available. Run bootstrap-gaming.ps1 first, it bootstraps winget.'
        continue
    }

    if ($exe) {
        Write-Host '  already installed'
    } elseif ($installHere) {
        $wingetArgs = @('install', '--id', $app.Id, '--source', 'winget', '-e', '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        if ($app.Scope) { $wingetArgs += @('--scope', $app.Scope) }
        & $wingetExe @wingetArgs
        if ($LASTEXITCODE -ne 0) { Write-Warning "  winget exited with $LASTEXITCODE" }
    } else {
        Write-Warning "  the machine-wide install did not produce $($app.Exe -join ' or ')"
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

if ($Services -and $Phase -ne 'machine') {
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
            # sitting over the film. Deliberately use the console user's normal
            # Edge profile: provisioning is elevated under another account,
            # and pinning --user-data-dir here would put logins in the wrong
            # profile or create state the console user cannot update.
            #
            # The rest are the traps, and every one of them is something that
            # would only show up with a controller in hand and no keyboard:
            #
            #   --no-first-run            a fresh profile otherwise opens Edge's
            #                             welcome and import flow on first
            #                             launch, full screen, mouse only. That
            #                             is a dead end on a television.
            #   --no-default-browser-check  same, one dialog later
            #   --disable-session-crashed-bubble  after a power cut, "restore
            #                             pages?" sits over the film waiting for
            #                             a click nobody can make
            #   --noerrdialogs            no modal error boxes on a TV
            #   --force-device-scale-factor  a web page laid out for a desk is
            #                             small from three metres. Netflix's own
            #                             TV interface is far larger than its
            #                             web one; this closes some of the gap.
            $arguments = "--app=`"$($site.Url)`" --start-fullscreen" +
                         " --no-first-run --no-default-browser-check" +
                         " --disable-session-crashed-bubble --noerrdialogs" +
                         " --force-device-scale-factor=$Scale"
            if ($canShortcut) { & $shortcut -Name $site.Label -Exe $edge -Arguments $arguments -Glyph 'E714' -NoApply }
            else { Write-Host "  $edge $arguments" }
        }
    }
}

# --- one rewrite at the end --------------------------------------------------
# Each -NoApply above only recorded the entry. Applying once means Steam is
# closed once rather than once per app.
if ($canShortcut -and -not $DeferApply) {
    Write-Host ''
    & (Join-Path $PSScriptRoot 'add-console-shortcuts.ps1') -Force
}

if ($Services -and $Phase -ne 'machine') {
    Write-Host ''
    Write-Host 'The streaming services need a controller layout, once.' -ForegroundColor Cyan
    Write-Host 'They are web pages, and a web page does not read a gamepad. That binding lives'
    Write-Host 'in your Steam cloud config, so it cannot be set from here.'
    Write-Host ''
    Write-Host '  Steam > Settings > Controller > Desktop layout, then:'
    Write-Host '    right stick   mouse            move the pointer'
    Write-Host '    right trigger left click       select'
    Write-Host '    d-pad         arrow keys       Netflix moves between rows with these'
    Write-Host '    A             Enter            play'
    Write-Host '    B             Escape           leave fullscreen, go back'
    Write-Host '    Y             F                fullscreen'
    Write-Host '    a chord       on-screen keyboard   for signing in'
    Write-Host ''
    Write-Host 'Two choices behind this, so they do not look arbitrary:' -ForegroundColor Cyan
    Write-Host '  Edge, because Netflix serves 1080p and 4K only to browsers that can use'
    Write-Host '  PlayReady. Firefox would cap the television at 720p.'
    Write-Host "  Enlarged to $Scale times, because these pages are laid out to be read from"
    Write-Host '  half a metre and a television is watched from three. Pass -Scale to change it.'
}
