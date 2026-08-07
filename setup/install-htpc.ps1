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

# The icon a browser would use for a bookmark, fetched from the service's own
# site on this machine at install time. Nothing is shipped in this repository:
# these are other people's trademarks, and the point is only to tell six
# entries apart, which is exactly what a browser does with a favicon.
#
# Best available wins. Sites advertise several sizes and the markup varies, so
# this asks the page first, then the two conventional paths. A browser user
# agent because some of them answer 403 to anything else.
function Get-SiteIcon {
    param([string]$Url, [string]$OutFile)

    $uri = [Uri]$Url
    $base = "$($uri.Scheme)://$($uri.Host)"
    $agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $html = (Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = $agent }).Content
        $links = [regex]::Matches($html, '<link[^>]+rel="[^"]*icon[^"]*"[^>]*>')
        $found = foreach ($link in $links) {
            $href = [regex]::Match($link.Value, 'href="([^"]+)"').Groups[1].Value
            if (-not $href -or $href -like '*.svg') { continue }   # Steam does not read SVG
            $size = [regex]::Match($link.Value, 'sizes="(\d+)x\d+"').Groups[1].Value
            [pscustomobject]@{
                Url = if ($href -match '^https?://') { $href }
                      elseif ($href.StartsWith('//')) { "$($uri.Scheme):$href" }
                      else { "$base/$($href.TrimStart('/'))" }
                Size = if ($size) { [int]$size } else { 0 }
            }
        }
        foreach ($item in ($found | Sort-Object Size -Descending)) { $candidates.Add($item.Url) }
    } catch { }

    $candidates.Add("$base/apple-touch-icon.png")
    $candidates.Add("$base/favicon.ico")

    foreach ($candidate in $candidates) {
        try {
            $extension = if ($candidate -match '\.ico(\?|$)') { '.ico' } else { '.png' }
            $target = [IO.Path]::ChangeExtension($OutFile, $extension)
            Invoke-WebRequest $candidate -OutFile $target -UseBasicParsing -TimeoutSec 15 `
                -Headers @{ 'User-Agent' = $agent } -ErrorAction Stop
            # A 404 page saved as a file is not an icon
            if ((Get-Item $target).Length -gt 500) { return $target }
            Remove-Item $target -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    return $null
}

# Steam's shortcut icon field is a Windows icon path, and a .png put there is
# quietly not drawn: the entry simply has no symbol, which is what a library
# full of freshly fetched logos looked like. Sites publish PNG, so it has to be
# wrapped.
#
# The container is simple enough to write directly: a 6 byte header, one 16 byte
# directory entry, then the image. Windows Vista and later read a PNG stored
# inside an .ico as-is, so the pixels are copied rather than re-encoded, and 256
# pixel images record their size as 0 because the field is a single byte.
function ConvertTo-Icon {
    param([string]$ImagePath, [string]$OutFile)

    Add-Type -AssemblyName System.Drawing
    $source = [System.Drawing.Image]::FromFile($ImagePath)
    try {
        $side = [Math]::Min(256, [Math]::Max($source.Width, $source.Height))
        $square = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($square)
        try {
            $graphics.InterpolationMode = 'HighQualityBicubic'
            # Not $scale: that is the script's [double]$Scale parameter with a
            # different capital, and PowerShell would have quietly overwritten
            # the zoom factor for every streaming window with a ratio.
            $ratio = [Math]::Min($side / $source.Width, $side / $source.Height)
            $width = [single]($source.Width * $ratio)
            $height = [single]($source.Height * $ratio)
            $graphics.DrawImage($source, [single](($side - $width) / 2), [single](($side - $height) / 2), $width, $height)
        } finally { $graphics.Dispose() }

        $buffer = New-Object System.IO.MemoryStream
        $square.Save($buffer, [System.Drawing.Imaging.ImageFormat]::Png)
        $square.Dispose()
        $png = $buffer.ToArray()
        $buffer.Dispose()

        $stream = [IO.File]::Open($OutFile, 'Create')
        $writer = New-Object System.IO.BinaryWriter($stream)
        try {
            $writer.Write([uint16]0)            # reserved
            $writer.Write([uint16]1)            # type: icon
            $writer.Write([uint16]1)            # one image
            $writer.Write([byte]($side % 256))  # 256 is recorded as 0
            $writer.Write([byte]($side % 256))
            $writer.Write([byte]0)              # palette
            $writer.Write([byte]0)              # reserved
            $writer.Write([uint16]1)            # colour planes
            $writer.Write([uint16]32)           # bits per pixel
            $writer.Write([uint32]$png.Length)
            $writer.Write([uint32]22)           # the image starts after this header
            $writer.Write($png)
        } finally { $writer.Dispose(); $stream.Dispose() }
    } finally { $source.Dispose() }
    return $OutFile
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
        # A fresh Edge profile on a machine whose Windows account is a Microsoft
        # account opens a full screen "we are now syncing your browsing data"
        # dialog on first launch. It has one button and it needs a click, which
        # on a television with a controller is where the evening ends. There is
        # no command line switch for it; policy is the documented way.
        #
        # HKCU on purpose, not HKLM: this is the console account's Edge, and the
        # administrator account keeps a normal browser with sign-in and sync
        # working. A machine-wide policy would take those away from the account
        # you use to fix things.
        $edgePolicy = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
        if (-not (Test-Path $edgePolicy)) { New-Item -Path $edgePolicy -Force | Out-Null }
        $policies = [ordered]@{
            BrowserSignin              = 0   # no sign-in, which is what draws the sync dialog
            SyncDisabled               = 1
            HideFirstRunExperience     = 1   # no welcome tour
            AutoImportAtFirstRun       = 0   # no "we imported your favourites" panel
            ShowRecommendationsEnabled = 0   # no suggestion popups over a film
            # Startup boost keeps an Edge process alive after every window
            # closes. Harmless on a desktop, and on a console it is one more
            # thing running behind a game for no benefit.
            StartupBoostEnabled        = 0
            BackgroundModeEnabled      = 0
        }
        foreach ($name in $policies.Keys) {
            New-ItemProperty -Path $edgePolicy -Name $name -Value $policies[$name] -PropertyType DWord -Force | Out-Null
        }
        Write-Host ''
        Write-Host "Edge, for $env:USERNAME only: sign-in, sync, the welcome tour and suggestions off." -ForegroundColor Cyan

        foreach ($key in $Services) {
            $site = $sites[$key]
            Write-Host ''
            Write-Host ">> $($site.Label)..." -ForegroundColor Cyan
            # --app gives a window with no browser furniture, which is the whole
            # point on a television: no tabs, no address bar, no back button
            # sitting over the film.
            #
            # --user-data-dir is back, and it is not optional. Chromium is one
            # instance per profile: launch a second one against a profile that
            # is already open and it hands the request over and exits, which is
            # what Steam sees as the entry closing the moment it opens. Measured
            # rather than argued: the second process exits with code 0 in under
            # five seconds. Edge's startup boost keeps a background process
            # alive, so on the shared profile that happens every single time.
            #
            # This used to point at the console user's normal profile because
            # provisioning ran elevated under another account and would have
            # created state that account could not update. That reason is gone:
            # the services are set up in the user phase now, as the console
            # account itself, so the profile is created by and belongs to the
            # account that will use it. The cost is that each service keeps its
            # own sign-in, which on a console is closer to right anyway.
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
            #   --hide-scrollbars         the one thing that makes a web page
            #                             read as a web page from the sofa. No
            #                             television interface has a scrollbar,
            #                             and it is visible in every screenshot
            #                             until it is turned off.
            # No quotes around the URL or the profile path, deliberately.
            # These arguments are stored in Steam's LaunchOptions and Steam
            # parses that string itself before handing it to the process, so
            # embedded quotes are one more parser between the value written
            # here and the value Edge receives. A URL has no spaces and neither
            # does the profile path, so the quotes bought nothing and could only
            # cost. Reported as Netflix opening and closing immediately, which
            # is what Edge does when --app arrives malformed.
            #
            # $Scale is formatted invariantly: on a machine set to a language
            # that writes decimals with a comma, "1,5" is not a number Chromium
            # accepts.
            $scaleText = $Scale.ToString([Globalization.CultureInfo]::InvariantCulture)
            $profileDir = Join-Path $env:LOCALAPPDATA "Consolize\web\$key"
            New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
            $arguments = "--app=$($site.Url) --start-fullscreen" +
                         " --user-data-dir=$profileDir" +
                         " --no-first-run --no-default-browser-check" +
                         " --disable-session-crashed-bubble --noerrdialogs" +
                         " --hide-scrollbars" +
                         " --force-device-scale-factor=$scaleText"
            $iconDir = Join-Path $env:LOCALAPPDATA 'Consolize\icons'
            New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
            $icon = Get-SiteIcon -Url $site.Url -OutFile (Join-Path $iconDir "$key.png")
            if ($icon) { Write-Host "  icon: $(Split-Path $icon -Leaf)" }
            else { Write-Host '  no icon published by the site, using the generated one' }

            if ($canShortcut) {
                $splat = @{ Name = $site.Label; Exe = $edge; Arguments = $arguments; Glyph = 'E714'; NoApply = $true }
                if ($icon) {
                    # Artwork stays the original image, which the cover art
                    # composer reads directly. Only Steam's icon field needs
                    # the .ico wrapper.
                    $splat.Artwork = $icon
                    try { $splat.Icon = ConvertTo-Icon -ImagePath $icon -OutFile (Join-Path $iconDir "$key.ico") }
                    catch { Write-Warning "  could not build an .ico from it: $($_.Exception.Message)" }
                }
                & $shortcut @splat
            }
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
