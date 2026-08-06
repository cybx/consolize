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

It is not on winget, so this takes the signed installer from its GitHub release.

  .\install-youtube.ps1                 # install and put it in the Steam library
  .\install-youtube.ps1 -NoShortcut     # install only
#>
param(
    [switch]$NoShortcut,
    # Pin a version instead of taking the newest, for a machine that should not
    # change under its owner.
    [string]$Version = 'latest'
)
$ErrorActionPreference = 'Stop'

$repo = 'shy1132/VacuumTube'
$installed = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\VacuumTube\VacuumTube.exe'),
    (Join-Path ${env:ProgramFiles} 'VacuumTube\VacuumTube.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($installed) {
    Write-Host "VacuumTube is already here: $installed"
} else {
    Write-Host 'Looking up the current VacuumTube release...' -ForegroundColor Cyan
    $api = if ($Version -eq 'latest') { "https://api.github.com/repos/$repo/releases/latest" }
           else { "https://api.github.com/repos/$repo/releases/tags/$Version" }

    $release = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'consolize' }
    $asset = $release.assets | Where-Object { $_.name -eq 'VacuumTube-Setup.exe' } | Select-Object -First 1
    if (-not $asset) { throw "That release has no VacuumTube-Setup.exe. See https://github.com/$repo/releases" }

    $setup = Join-Path $env:TEMP $asset.name
    Write-Host "  $($release.tag_name), $([math]::Round($asset.size / 1MB)) MB..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $setup -UseBasicParsing

    # electron-builder's NSIS installer. /S is silent; without it this stops on
    # a dialog nobody is in front of.
    Write-Host '  installing...'
    Start-Process $setup -ArgumentList '/S' -Wait

    Remove-Item $setup -Force -ErrorAction SilentlyContinue

    $installed = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\VacuumTube\VacuumTube.exe'),
        (Join-Path ${env:ProgramFiles} 'VacuumTube\VacuumTube.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $installed) {
        Write-Warning 'Installed, but VacuumTube.exe is not where it was expected.'
        Write-Warning 'It installs per user, so if this ran as an administrator it went into that'
        Write-Warning 'profile. Run this again while signed in as the console account.'
        return
    }
    Write-Host "  installed: $installed" -ForegroundColor Green
}

if ($NoShortcut) { return }

# In the library rather than only on the desktop, because on this machine the
# library is the only thing a controller can reach.
$shortcut = Join-Path $PSScriptRoot 'add-app-shortcut.ps1'
if (-not (Test-Path $shortcut)) { Write-Warning "add-app-shortcut.ps1 is not here, skipping the Steam entry."; return }

Write-Host ''
& $shortcut -Name 'YouTube' -Exe $installed -Glyph 'E714'

Write-Host ''
Write-Host 'Sign in from the couch: open YouTube, go to Settings, and use "Link with TV code".' -ForegroundColor Cyan
Write-Host 'Typing a password on a television is the part nobody plans for.'
