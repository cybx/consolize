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
