<#
Puts "Desktop Mode" inside the frontend, and a way back on the desktop, so
switching between the two never needs a keyboard.

  In Steam Big Picture : a non-Steam shortcut named "Desktop Mode", navigable
                         with the controller like any other library entry
  On the Windows desktop: "Back to Console Mode.lnk"
  In the tray           : the session manager shows an icon while the desktop is
                         up (double-click returns to the console)

Steam keeps non-Steam shortcuts per Steam account in a binary VDF, and rewrites
that file from memory when it closes, so Steam has to be closed while we write.
The existing file is backed up next to itself first.

Runs as the console account (its own Steam profile), no admin needed.

  .\add-console-shortcuts.ps1
  .\add-console-shortcuts.ps1 -Force   # close Steam automatically
#>
param(
    [string]$ConsolizeExe = 'C:\Program Files\Consolize\consolize.exe',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConsolizeExe)) { throw "consolize.exe not found at $ConsolizeExe" }

# --- the way back: a desktop shortcut ---------------------------------------

$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$backLink = Join-Path $desktop 'Back to Console Mode.lnk'
$lnk = $shell.CreateShortcut($backLink)
$lnk.TargetPath = $ConsolizeExe
$lnk.Arguments = 'send console'
$lnk.Description = 'Close the desktop and return to the console frontend'
$lnk.IconLocation = "$ConsolizeExe,0"
$lnk.Save()
Write-Host "Desktop shortcut: $backLink"

# --- the way out: a non-Steam shortcut --------------------------------------

function Get-SteamPath {
    foreach ($dir in @(
        (Get-ItemProperty 'HKCU:\SOFTWARE\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath,
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        'C:\Program Files (x86)\Steam'
    )) {
        if (-not $dir) { continue }
        $dir = $dir -replace '/', '\'
        if (Test-Path (Join-Path $dir 'steam.exe')) { return $dir }
    }
    return $null
}

# Binary VDF: 0x00 opens a map, 0x01 marks a string field, 0x02 a 32-bit int,
# 0x08 closes a map. Keys and values are NUL terminated.
function Add-VdfString {
    param([System.IO.BinaryWriter]$W, [string]$Key, [string]$Value)
    $W.Write([byte]1)
    $W.Write([Text.Encoding]::UTF8.GetBytes($Key)); $W.Write([byte]0)
    $W.Write([Text.Encoding]::UTF8.GetBytes($Value)); $W.Write([byte]0)
}
function Add-VdfInt {
    param([System.IO.BinaryWriter]$W, [string]$Key, [int]$Value)
    $W.Write([byte]2)
    $W.Write([Text.Encoding]::UTF8.GetBytes($Key)); $W.Write([byte]0)
    $W.Write([BitConverter]::GetBytes($Value))
}

$steam = Get-SteamPath
if (-not $steam) {
    Write-Warning 'Steam not found, only the desktop shortcut was created.'
    return
}

$steamProc = Get-Process steam -ErrorAction SilentlyContinue
if ($steamProc) {
    if (-not $Force) {
        Write-Warning 'Steam is running and would overwrite this file when it closes.'
        $answer = Read-Host 'Close Steam now and continue? [Y/n]'
        if ($answer -match '^[nN]') { Write-Host 'Skipped the Steam shortcut.'; return }
    }
    Write-Host 'Closing Steam...'
    $steamProc | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}

$userDirs = @(Get-ChildItem (Join-Path $steam 'userdata') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '0' })
if (-not $userDirs) {
    Write-Warning 'No Steam user profile found (sign in to Steam first). Only the desktop shortcut was created.'
    return
}

# Counts entries already in the file. Every shortcut carries exactly one
# AppName field, so counting those counts entries, without parsing the rest.
function Get-VdfEntryCount {
    param([byte[]]$Bytes)
    $needle = @(1) + [Text.Encoding]::UTF8.GetBytes('AppName') + @(0)
    $count = 0
    for ($i = 0; $i -le $Bytes.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($Bytes[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) { $count++ }
    }
    return $count
}

foreach ($userDir in $userDirs) {
    $configDir = Join-Path $userDir.FullName 'config'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $vdf = Join-Path $configDir 'shortcuts.vdf'

    # Appending, not replacing. Steam creates this file on its own, so refusing
    # whenever it existed meant the entries were almost never written, and the
    # library came up without a way to reach the desktop.
    $keep = $null
    $firstIndex = 0

    if (Test-Path $vdf) {
        $bytes = [IO.File]::ReadAllBytes($vdf)

        if ([Text.Encoding]::UTF8.GetString($bytes) -match 'Desktop Mode') {
            Write-Host "  $($userDir.Name): already has the Desktop Mode entry, leaving it alone."
            continue
        }

        # A well-formed file ends with the byte that closes the shortcuts map.
        # Anything else is a shape this does not understand, and a library full
        # of someone's shortcuts is not worth guessing about.
        if ($bytes.Length -lt 12 -or $bytes[$bytes.Length - 1] -ne 8) {
            Write-Warning "  $($userDir.Name): shortcuts.vdf is not in the expected shape, leaving it alone."
            Write-Warning "  Add them from Big Picture instead: $ConsolizeExe   arguments: send desktop"
            continue
        }

        $backup = "$vdf.consolize-backup"
        if (-not (Test-Path $backup)) { Copy-Item $vdf $backup }

        $firstIndex = Get-VdfEntryCount -Bytes $bytes

        # Everything except the closing byte, so new entries go before it.
        # Array.Copy, not $bytes[0..n]: range indexing yields Object[], which
        # BinaryWriter does not write as bytes, and the existing shortcuts came
        # out mangled. Caught by round-tripping the result.
        $keep = New-Object byte[] ($bytes.Length - 1)
        [Array]::Copy($bytes, $keep, $bytes.Length - 1)
        Write-Host "  $($userDir.Name): $firstIndex shortcut(s) already there, adding to them (backup: $(Split-Path $backup -Leaf))"
    }

    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $updateScript = Join-Path $PSScriptRoot 'update-console.ps1'

    $entries = @(
        @{ Name = 'Quick Settings'; Exe = $ConsolizeExe; Args = 'panel' }
        @{ Name = 'Desktop Mode';   Exe = $ConsolizeExe; Args = 'send desktop' }
        @{ Name = 'Update consolize'; Exe = $powershell
           Args = "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`"" }
    )

    $stream = [IO.File]::Open($vdf, 'Create')
    $w = New-Object System.IO.BinaryWriter($stream)
    try {
        if ($keep) {
            # everything that was there, minus its closing byte
            $w.Write($keep)
        } else {
            $w.Write([byte]0)
            $w.Write([Text.Encoding]::UTF8.GetBytes('shortcuts')); $w.Write([byte]0)
        }

        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            $index = $firstIndex + $i

            $w.Write([byte]0)
            $w.Write([Text.Encoding]::UTF8.GetBytes("$index")); $w.Write([byte]0)

            Add-VdfString $w 'AppName' $entry.Name
            Add-VdfString $w 'Exe' "`"$($entry.Exe)`""
            Add-VdfString $w 'StartDir' "`"$(Split-Path $entry.Exe)`""
            # always our icon, even when the target is powershell.exe
            Add-VdfString $w 'icon' $ConsolizeExe
            Add-VdfString $w 'ShortcutPath' ''
            Add-VdfString $w 'LaunchOptions' $entry.Args
            Add-VdfInt $w 'IsHidden' 0
            Add-VdfInt $w 'AllowDesktopConfig' 1
            Add-VdfInt $w 'AllowOverlay' 1
            Add-VdfInt $w 'OpenVR' 0
            Add-VdfInt $w 'Devkit' 0
            Add-VdfString $w 'DevkitGameID' ''
            Add-VdfInt $w 'DevkitOverrideAppID' 0
            Add-VdfInt $w 'LastPlayTime' 0
            Add-VdfString $w 'FlatpakAppID' ''

            # empty tags map
            $w.Write([byte]0)
            $w.Write([Text.Encoding]::UTF8.GetBytes('tags')); $w.Write([byte]0)
            $w.Write([byte]8)

            $w.Write([byte]8)   # close this entry
        }

        $w.Write([byte]8)   # close shortcuts
    } finally {
        $w.Dispose(); $stream.Dispose()
    }
    Write-Host "  $($userDir.Name): 'Quick Settings' and 'Desktop Mode' added to the Steam library."
}

Write-Host ''
Write-Host 'Switching, from now on:' -ForegroundColor Green
Write-Host '  console -> desktop : "Desktop Mode" in the Steam library'
Write-Host '  desktop -> console : the tray icon (double-click) or the desktop shortcut'
Write-Host '  either way, a reboot always comes back to the console'
