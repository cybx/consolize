#Requires -RunAsAdministrator
<#
Installs the newest Windows portable build of SteaMidra and adds it to Steam as
a non-Steam application. The release is resolved at run time, so this script
does not need changing for every upstream version.

  .\install-steamidra.ps1
  .\install-steamidra.ps1 -NoShortcut
  .\install-steamidra.ps1 -Version v6.6.0
#>
param(
    [switch]$NoShortcut,
    [string]$Version = 'latest'
)
$ErrorActionPreference = 'Stop'

$repo = 'Midrags/SFF'
$installDir = Join-Path ${env:ProgramFiles} 'SteaMidra'
$versionFile = Join-Path $installDir '.consolize-version'
$artwork = Join-Path $installDir 'SFF.png'
$api = if ($Version -eq 'latest') { "https://api.github.com/repos/$repo/releases/latest" }
       else { "https://api.github.com/repos/$repo/releases/tags/$Version" }

Write-Host 'Looking up the current SteaMidra release...' -ForegroundColor Cyan
$release = Invoke-RestMethod $api -UseBasicParsing -Headers @{ 'User-Agent' = 'consolize' }
$asset = $release.assets | Where-Object { $_.name -match '^SteaMidra-.*-windows\.zip$' } |
    Select-Object -First 1
if (-not $asset) {
    throw "Release $($release.tag_name) has no SteaMidra Windows ZIP. See https://github.com/$repo/releases"
}

$installed = Get-ChildItem $installDir -Filter 'SteaMidra_GUI.exe' -File -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
$installedVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { $null }

if ($installed -and $installedVersion -eq $release.tag_name) {
    Write-Host "SteaMidra $installedVersion is already current: $($installed.FullName)"
} else {
    $sevenZip = @(
        (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        (Join-Path ${env:ProgramFiles} '7-Zip\7z.exe'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe' })
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $sevenZip) {
        throw '7-Zip is required. Select "tools" in bootstrap-gaming.ps1 or install 7zip.7zip with winget.'
    }

    $download = Join-Path $env:TEMP $asset.name
    Write-Host "  downloading $($release.tag_name), $([math]::Round($asset.size / 1MB)) MB..."
    try {
        Invoke-WebRequest $asset.browser_download_url -OutFile $download -UseBasicParsing
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null

        Write-Host "  extracting with 7-Zip to $installDir..."
        & $sevenZip x $download "-o$installDir" -aoa -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip exited with code $LASTEXITCODE." }

        $installed = Get-ChildItem $installDir -Filter 'SteaMidra_GUI.exe' -File -Recurse |
            Select-Object -First 1
        if (-not $installed) { throw 'The archive did not contain SteaMidra_GUI.exe.' }

        Set-Content $versionFile $release.tag_name -Encoding ASCII
        Write-Host "  installed: $($installed.FullName)" -ForegroundColor Green
    } finally {
        Remove-Item $download -Force -ErrorAction SilentlyContinue
    }
}

# Keep the library art tied to the same upstream tag as the application. SFF.png
# is the official image tracked in the SteaMidra repository.
try {
    $artUrl = "https://raw.githubusercontent.com/$repo/$($release.tag_name)/SFF.png"
    Invoke-WebRequest $artUrl -OutFile $artwork -UseBasicParsing
} catch {
    Write-Warning "Could not download the official SteaMidra artwork: $($_.Exception.Message)"
}

if ($NoShortcut) { return }

$shortcut = Join-Path $PSScriptRoot 'add-app-shortcut.ps1'
if (-not (Test-Path $shortcut)) {
    Write-Warning 'add-app-shortcut.ps1 is not here, skipping the Steam entry.'
    return
}

Write-Host ''
$shortcutArgs = @{ Name = 'SteaMidra'; Exe = $installed.FullName; Glyph = 'E7FC' }
if (Test-Path $artwork -PathType Leaf) { $shortcutArgs['Artwork'] = $artwork }
& $shortcut @shortcutArgs
