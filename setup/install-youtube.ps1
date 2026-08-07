#Requires -RunAsAdministrator
<#
YouTube on the television, driven by the controller.

The obvious route does not work. YouTube's TV interface lives at
youtube.com/tv and is a plain HTML5 app, but Google blocks browsers from it
unless they identify as a console or a TV, and the user agent trick that gets
around that gives you the interface without gamepad support: the arrow keys work
and the controller does nothing, which on a couch is the same as it not working.
The recipes for this that circulate are mostly from before Leanback was closed
off and no longer apply.

VacuumTube is the way through. It wraps that same official interface in Electron,
identifies as the YouTube TV app, and implements controller and touch input
itself. MIT licensed and actively maintained.

It is not on winget, so this takes the portable x64 build from its GitHub
release, verifies GitHub's SHA-256 digest and installs it machine-wide. Using
the portable build matters during provisioning: a per-user NSIS installer run
elevated would install into the administrator's profile, invisible to gamer.

  .\install-youtube.ps1                 # install and put it in the Steam library
  .\install-youtube.ps1 -NoShortcut     # install only
#>
param(
    # Split the same way the media centre is, and for the same reason. The
    # download and the machine-wide install belong in the elevated phase; the
    # settings and the library entry belong to the console account, because its
    # configuration lives in that account's profile. Run whole with 'all'.
    [ValidateSet('all', 'machine', 'user')] [string]$Phase = 'all',
    [switch]$NoShortcut,
    # Pin a version instead of taking the newest, for a machine that should not
    # change under its owner.
    [string]$Version = 'latest'
)
$ErrorActionPreference = 'Stop'

$repo = 'shy1132/VacuumTube'
$installDir = Join-Path ${env:ProgramFiles} 'VacuumTube'
$versionFile = Join-Path $installDir '.consolize-version'
$installed = @(Join-Path ${env:ProgramFiles} 'VacuumTube\VacuumTube.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $installed -and (Test-Path $installDir)) {
    $installed = Get-ChildItem $installDir -Filter 'VacuumTube.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

Write-Host 'Looking up the current VacuumTube release...' -ForegroundColor Cyan
$api = if ($Version -eq 'latest') { "https://api.github.com/repos/$repo/releases/latest" }
       else { "https://api.github.com/repos/$repo/releases/tags/$Version" }
$release = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'consolize' }
$asset = $release.assets | Where-Object { $_.name -eq 'VacuumTube-x64-Portable.zip' } | Select-Object -First 1
if (-not $asset) { throw "That release has no VacuumTube-x64-Portable.zip. See https://github.com/$repo/releases" }
$installedVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { $null }

if ($installed -and $installedVersion -eq $release.tag_name) {
    Write-Host "VacuumTube $installedVersion is already current: $installed"
} else {

    $archive = Join-Path $env:TEMP $asset.name
    Write-Host "  $($release.tag_name), $([math]::Round($asset.size / 1MB)) MB..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $archive -UseBasicParsing

    $assetDigest = [string]$asset.digest
    $digestMatch = [regex]::Match($assetDigest, '^sha256:([0-9a-fA-F]{64})$')
    if (-not $digestMatch.Success) {
        Remove-Item $archive -Force -ErrorAction SilentlyContinue
        throw 'GitHub did not provide a SHA-256 digest for the VacuumTube portable archive.'
    }
    $expectedHash = $digestMatch.Groups[1].Value.ToLowerInvariant()
    $actualHash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Remove-Item $archive -Force -ErrorAction SilentlyContinue
        throw "VacuumTube digest mismatch (expected $expectedHash, got $actualHash)."
    }
    Write-Host "  SHA-256 verified by GitHub: $actualHash"

    Write-Host "  extracting to $installDir..."
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    try { Expand-Archive $archive -DestinationPath $installDir -Force }
    finally { Remove-Item $archive -Force -ErrorAction SilentlyContinue }

    $installed = @(Join-Path ${env:ProgramFiles} 'VacuumTube\VacuumTube.exe') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $installed) {
        $installed = Get-ChildItem $installDir -Filter 'VacuumTube.exe' -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $installed) {
        Write-Warning 'Installed, but VacuumTube.exe is not where it was expected.'
        Write-Warning "The portable archive was extracted to $installDir but VacuumTube.exe was not found."
        return
    }
    Set-Content $versionFile $release.tag_name -Encoding ASCII
    Write-Host "  installed: $installed" -ForegroundColor Green
}

if ($Phase -eq 'machine') {
    Write-Host '  installed machine-wide; its settings and library entry are finished'
    Write-Host '  inside the console account, where its configuration actually lives.'
    return
}

# --- make it open like an appliance, not like a program ---------------------
# VacuumTube launches windowed with a title bar, which on a television reads as
# a program someone left open rather than as YouTube. The settings that fix
# that live in its own config, reachable in the app with R3, but nobody should
# have to find them on first run. Its defaults are in src/config.js upstream,
# and unknown keys are ignored, so writing only what we care about is safe.
$configDir = Join-Path $env:APPDATA 'VacuumTube'
$configFile = Join-Path $configDir 'config.json'

$wanted = [ordered]@{
    fullscreen             = $true   # and it remembers, so every launch is fullscreen
    no_window_decorations  = $true   # no title bar over the video
    controller_support     = $true   # the whole reason this app was chosen
    pause_on_blur          = $true   # chord back to the console and the video stops
}

try {
    # Electron writes this file out when it closes, from what it holds in
    # memory, so anything set underneath a running VacuumTube is discarded at
    # exit. Exactly the trap Steam sets with shortcuts.vdf, and the reason the
    # window kept opening at desktop size after the setting had been written.
    $running = Get-Process VacuumTube -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host '  closing VacuumTube first, it rewrites its settings when it exits...'
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $config = [ordered]@{}
    if (Test-Path $configFile) {
        # Merge, never replace: this file also holds the volume, the ad block
        # and SponsorBlock choices, and a SponsorBlock id that identifies this
        # install. Overwriting it would silently reset all of that.
        (Get-Content $configFile -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $config[$_.Name] = $_.Value }
    }
    foreach ($key in $wanted.Keys) { $config[$key] = $wanted[$key] }

    ConvertTo-Json -InputObject $config -Depth 6 | Set-Content $configFile -Encoding UTF8
    Write-Host "  set to open fullscreen, without a title bar, pausing when it loses focus"
} catch {
    Write-Warning "  could not preset VacuumTube's settings: $($_.Exception.Message)"
    Write-Warning '  turn on Fullscreen inside the app: press R3 on the controller.'
}

if ($NoShortcut) { return }

# In the library rather than only on the desktop, because on this machine the
# library is the only thing a controller can reach.
$shortcut = Join-Path $PSScriptRoot 'add-app-shortcut.ps1'
if (-not (Test-Path $shortcut)) { Write-Warning "add-app-shortcut.ps1 is not here, skipping the Steam entry."; return }

Write-Host ''
# Steam's icon field is a Windows icon path, and it draws nothing for an entry
# whose icon it cannot read. Handing it the .exe leaves the choice to Steam and
# it came out blank, so the icon is extracted into a real .ico beside the
# binary and pointed at directly. Same fix the streaming entries needed.
$iconArgs = @{}
try {
    Add-Type -AssemblyName System.Drawing
    $extracted = [System.Drawing.Icon]::ExtractAssociatedIcon($installed)
    if ($extracted) {
        $iconFile = Join-Path (Join-Path $env:LOCALAPPDATA 'Consolize\icons') 'youtube.ico'
        New-Item -ItemType Directory -Force -Path (Split-Path $iconFile) | Out-Null
        $stream = [IO.File]::Open($iconFile, 'Create')
        try { $extracted.Save($stream) } finally { $stream.Dispose() }
        $extracted.Dispose()
        $iconArgs.Icon = $iconFile
        Write-Host "  icon: $iconFile"
    }
} catch { Write-Warning "  could not extract its icon: $($_.Exception.Message)" }

& $shortcut -Name 'YouTube' -Exe $installed -Glyph 'E714' @iconArgs

Write-Host ''
Write-Host 'Sign in from the couch: open YouTube, go to Settings, and use "Link with TV code".' -ForegroundColor Cyan
Write-Host 'Typing a password on a television is the part nobody plans for.'
Write-Host ''
Write-Host 'To get out of it: hold Start + Back for a second.' -ForegroundColor Cyan
Write-Host 'That opens Quick Settings over whatever is on screen, and its Power page'
Write-Host 'goes back to the console. Steam''s overlay does not hook this kind of app,'
Write-Host 'so the guide button will not do it. R3 opens VacuumTube''s own settings.'
