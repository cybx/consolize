#Requires -RunAsAdministrator
<#
Installs qBittorrent and lays out a torrent folder structure, so downloads have
a home from day one instead of piling into the user's Downloads folder.

Default layout (on the roomiest fixed drive that is not the system drive, if
there is one):

    <drive>\Torrents\incomplete    in progress
    <drive>\Torrents\complete      finished
    <drive>\Torrents\watch         drop a .torrent here to start it

qBittorrent's save paths are pre-configured to match, but only when it has no
config yet: an existing qBittorrent.ini is never overwritten.

  .\install-torrent.ps1
  .\install-torrent.ps1 -TorrentPath 'D:\Downloads\Torrents'
  .\install-torrent.ps1 -FoldersOnly        # no install, just the folders
#>
param(
    [string]$TorrentPath,
    [switch]$FoldersOnly,
    [string]$ForUser
)
$ErrorActionPreference = 'Stop'

function Get-BestDrive {
    $system = $env:SystemDrive
    $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object { $_.FreeSpace -gt 20GB } |
        Sort-Object FreeSpace -Descending
    $nonSystem = $drives | Where-Object { $_.DeviceID -ne $system } | Select-Object -First 1
    if ($nonSystem) { return $nonSystem.DeviceID }
    return $system
}

if (-not $TorrentPath) { $TorrentPath = Join-Path (Get-BestDrive) 'Torrents' }

$folders = @{
    Incomplete = Join-Path $TorrentPath 'incomplete'
    Complete   = Join-Path $TorrentPath 'complete'
    Watch      = Join-Path $TorrentPath 'watch'
}

Write-Host "Torrent folder: $TorrentPath"
foreach ($name in $folders.Keys | Sort-Object) {
    New-Item -ItemType Directory -Force -Path $folders[$name] | Out-Null
    Write-Host "  $($folders[$name])"
}

# Phase 2 reads this protected machine state and writes qBittorrent.ini from
# inside the real console profile. Never pre-create C:\Users\<name>: doing so
# before Windows creates the profile can force it into a suffixed directory.
$torrentState = Join-Path $env:ProgramData 'Consolize\torrent-path.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $torrentState) | Out-Null
& icacls.exe (Split-Path $torrentState) /inheritance:r /grant:r `
    '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not protect $(Split-Path $torrentState)" }
Set-Content $torrentState $TorrentPath -Encoding UTF8

if ($FoldersOnly) { return }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warning 'winget not available. Run bootstrap-gaming.ps1 first (it bootstraps winget), or install qBittorrent from https://www.qbittorrent.org/download'
    return
}

Write-Host ''
Write-Host '>> qBittorrent...' -ForegroundColor Cyan
& winget list --source winget --accept-source-agreements *>$null
winget install --id qBittorrent.qBittorrent --source winget -e --silent `
    --accept-package-agreements --accept-source-agreements
if ($LASTEXITCODE -ne 0) { Write-Warning "winget exited with $LASTEXITCODE (qBittorrent may already be installed)." }

# --- point qBittorrent at the folders, without clobbering an existing setup ---

$appData = if ($ForUser) {
    $profileDir = (Get-CimInstance Win32_UserProfile |
        Where-Object { $_.LocalPath -like "*\$ForUser" } | Select-Object -First 1).LocalPath
    if (-not $profileDir) {
        Write-Warning "$ForUser has no Windows profile yet. The folders and app are ready; phase 2 will configure qBittorrent after its first sign-in."
        return
    }
    Join-Path $profileDir 'AppData\Roaming'
} else {
    $env:APPDATA
}

$iniPath = Join-Path $appData 'qBittorrent\qBittorrent.ini'
if (Test-Path $iniPath) {
    Write-Host ''
    Write-Host "qBittorrent already has a config ($iniPath), leaving it alone."
    Write-Host "Set the save paths yourself in Options > Downloads if you want them under $TorrentPath."
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $iniPath) | Out-Null
    # qBittorrent stores paths with forward slashes
    $complete = $folders.Complete -replace '\\', '/'
    $incomplete = $folders.Incomplete -replace '\\', '/'
    $watch = $folders.Watch -replace '\\', '/'
    @"
[BitTorrent]
Session\DefaultSavePath=$complete
Session\TempPath=$incomplete
Session\TempPathEnabled=true

[Preferences]
Downloads\SavePath=$complete
Downloads\TempPath=$incomplete
Downloads\TempPathEnabled=true
Downloads\ScanDirsV2=@Variant(\0\0\0\x1c\0\0\0\x1)
General\ExitConfirm=false
"@ | Set-Content $iniPath -Encoding UTF8
    Write-Host ''
    Write-Host "qBittorrent configured to save into $($folders.Complete)" -ForegroundColor Green
    Write-Host "  in progress: $($folders.Incomplete)"
    Write-Host "  watch folder: add it in Options > Downloads > Monitored folders: $watch"
}
