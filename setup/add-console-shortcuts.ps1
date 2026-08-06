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
#
# The part that is easy to get wrong, and that this got wrong: the file has a
# root map that is never named and never opened, it is just implicitly open from
# byte 0. So a well formed file ends with TWO closing bytes, not one: the first
# closes the "shortcuts" map, the second closes that implicit root. Write only
# one and Steam reads a truncated document; strip only one when appending and
# the new entries land after "shortcuts" already closed, in the root, where
# Steam never looks for them. Either way the library comes up without them,
# which is exactly what happened.
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

$userDirs = @(Get-ChildItem (Join-Path $steam 'userdata') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '0' })
if (-not $userDirs) {
    Write-Warning 'No Steam user profile found (sign in to Steam first). Only the desktop shortcut was created.'
    return
}

# Walks the whole document instead of scanning for byte patterns. A scan cannot
# tell an entry that is inside the shortcuts map from one that is sitting
# outside it, and that difference is the whole bug: the names were in the file,
# Steam just never saw them. Throws on anything malformed, so a file this does
# not fully understand is left alone rather than guessed at.
#
# Returns the names of the entries Steam will actually load, and the highest
# index in use, which is where the next entry goes.
function Read-ShortcutsVdf {
    param([byte[]]$Bytes)

    $names = New-Object System.Collections.Generic.List[string]
    $maxIndex = -1
    $pos = 0
    $depth = 1   # the root map is open before the first byte

    while ($pos -lt $Bytes.Length) {
        $type = $Bytes[$pos]; $pos++

        if ($type -eq 8) {
            $depth--
            if ($depth -lt 0) { throw "a closing byte at $($pos - 1) with no map open" }
            if ($depth -eq 0 -and $pos -ne $Bytes.Length) {
                throw "the document closes at byte $pos but the file is $($Bytes.Length) bytes"
            }
            continue
        }

        $keyStart = $pos
        while ($pos -lt $Bytes.Length -and $Bytes[$pos] -ne 0) { $pos++ }
        if ($pos -ge $Bytes.Length) { throw 'a key runs past the end of the file' }
        $key = [Text.Encoding]::UTF8.GetString($Bytes, $keyStart, $pos - $keyStart); $pos++

        switch ($type) {
            0 {
                # depth 2 is the shortcuts map, so its keys are the entry indexes
                if ($depth -eq 2) {
                    $parsed = 0
                    if ([int]::TryParse($key, [ref]$parsed) -and $parsed -gt $maxIndex) { $maxIndex = $parsed }
                }
                $depth++
            }
            1 {
                $valStart = $pos
                while ($pos -lt $Bytes.Length -and $Bytes[$pos] -ne 0) { $pos++ }
                if ($pos -ge $Bytes.Length) { throw "the value of '$key' runs past the end of the file" }
                $value = [Text.Encoding]::UTF8.GetString($Bytes, $valStart, $pos - $valStart); $pos++
                if ($key -eq 'AppName' -and $depth -eq 3) { $names.Add($value) }
            }
            2 {
                if ($pos + 4 -gt $Bytes.Length) { throw "the value of '$key' runs past the end of the file" }
                $pos += 4
            }
            default { throw "unknown field type 0x$('{0:X2}' -f $type) at byte $($pos - 1)" }
        }
    }

    if ($depth -ne 0) { throw "the file ends with $depth map(s) still open" }
    return [pscustomobject]@{ Names = $names; MaxIndex = $maxIndex }
}

# Steam's id for a non-Steam shortcut: CRC-32 of Exe+AppName with the top bit
# set. Steam derives one itself when the field is absent, but writing it keeps
# the id stable across rewrites, and artwork and steam://rungameid links are
# keyed on it.
function Get-ShortcutAppId {
    param([string]$Exe, [string]$AppName)
    # The L suffixes are not decoration. PowerShell reads an eight digit hex
    # literal as a 32 bit pattern, so a bare 0xFFFFFFFF is Int32 -1 and a bare
    # 0x80000000 is Int32 -2147483648. Without the suffix this starts at -1,
    # every shift is arithmetic on a negative number, and the result is not a
    # CRC at all. Checked against the standard vector: "123456789" -> 0xCBF43926.
    $bytes = [Text.Encoding]::UTF8.GetBytes($Exe + $AppName)
    $crc = 0xFFFFFFFFL
    foreach ($b in $bytes) {
        $crc = $crc -bxor [int64]$b
        for ($i = 0; $i -lt 8; $i++) {
            if ($crc -band 1) { $crc = (($crc -shr 1) -bxor 0xEDB88320L) -band 0xFFFFFFFFL }
            else             { $crc =  ($crc -shr 1) -band 0xFFFFFFFFL }
        }
    }
    $crc = (($crc -bxor 0xFFFFFFFFL) -bor 0x80000000L) -band 0xFFFFFFFFL
    return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$crc), 0)
}

# Decide before closing anything. This runs again on every update, and on a
# machine that is already set up, killing Steam only to find there was nothing
# to do would throw the player out of whatever they were in the middle of.
$needsWork = $false
foreach ($userDir in $userDirs) {
    $vdf = Join-Path $userDir.FullName 'config\shortcuts.vdf'
    if (-not (Test-Path $vdf)) { $needsWork = $true; break }
    try {
        $parsed = Read-ShortcutsVdf -Bytes ([IO.File]::ReadAllBytes($vdf))
        if ($parsed.Names -notcontains 'Desktop Mode') { $needsWork = $true; break }
    } catch { $needsWork = $true; break }
}

if (-not $needsWork) {
    Write-Host 'The Steam library already has the console entries, nothing to do.'
    return
}

# Steam holds the shortcuts in memory and writes this file out when it closes,
# so anything written underneath a running Steam is discarded at exit. It has to
# be closed, and the file has to be read after it is, not before.
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

foreach ($userDir in $userDirs) {
    $configDir = Join-Path $userDir.FullName 'config'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $vdf = Join-Path $configDir 'shortcuts.vdf'

    # Appending, not replacing. Steam creates this file on its own, so refusing
    # whenever it existed meant the entries were almost never written, and the
    # library came up without a way to reach the desktop.
    $keep = $null
    $firstIndex = 0
    $backup = $null

    if (Test-Path $vdf) {
        $bytes = [IO.File]::ReadAllBytes($vdf)
        $existing = $null

        try {
            $existing = Read-ShortcutsVdf -Bytes $bytes
        } catch {
            # An earlier version of this script wrote one closing byte instead
            # of two, so its own output does not parse. Rather than tell people
            # to repair it by hand, recognise it: if adding the missing byte
            # makes the document whole, that is what happened, and the entries
            # it wrote were sitting outside the shortcuts map where Steam never
            # looked. Rewriting from here puts them where they belong.
            $repaired = New-Object byte[] ($bytes.Length + 1)
            [Array]::Copy($bytes, $repaired, $bytes.Length)
            $repaired[$bytes.Length] = 8
            try {
                $existing = Read-ShortcutsVdf -Bytes $repaired
                $bytes = $repaired
                Write-Host "  $($userDir.Name): repairing a shortcuts.vdf left unterminated by an older consolize."
            } catch {
                Write-Warning "  $($userDir.Name): shortcuts.vdf is not in the expected shape ($($_.Exception.Message)), leaving it alone."
                Write-Warning "  Add them from Big Picture instead: $ConsolizeExe   arguments: send desktop"
                continue
            }
        }

        # Ask the parsed entries, not the raw bytes. The names can be present in
        # a file where Steam cannot reach them, and a substring match would call
        # that done and skip the machine forever.
        if ($existing.Names -contains 'Desktop Mode') {
            Write-Host "  $($userDir.Name): already has the Desktop Mode entry, leaving it alone."
            continue
        }

        $backup = "$vdf.consolize-backup"
        if (-not (Test-Path $backup)) { Copy-Item $vdf $backup }

        # Indexes, not a count: a file with entries 0, 1 and 5 has three of them,
        # and starting at 3 would collide with 5.
        $firstIndex = $existing.MaxIndex + 1

        # Everything except the two closing bytes, so new entries go inside the
        # shortcuts map. Array.Copy, not $bytes[0..n]: range indexing yields
        # Object[], which BinaryWriter does not write as bytes, and the existing
        # shortcuts came out mangled.
        $keep = New-Object byte[] ($bytes.Length - 2)
        [Array]::Copy($bytes, $keep, $bytes.Length - 2)
        Write-Host "  $($userDir.Name): $($existing.Names.Count) shortcut(s) already there, adding to them (backup: $(Split-Path $backup -Leaf))"
    }

    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $updateScript = Join-Path $PSScriptRoot 'update-console.ps1'

    $entries = @(
        @{ Name = 'Quick Settings'; Exe = $ConsolizeExe; Args = 'panel' }
        @{ Name = 'Desktop Mode';   Exe = $ConsolizeExe; Args = 'send desktop' }
        @{ Name = 'Update consolize'; Exe = $powershell
           Args = "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`"" }
    )

    # Built in memory and checked before it replaces anything on disk. The file
    # being written here is someone's library.
    $stream = New-Object System.IO.MemoryStream
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

            Add-VdfInt $w 'appid' (Get-ShortcutAppId -Exe "`"$($entry.Exe)`"" -AppName $entry.Name)
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
        $w.Write([byte]8)   # close the implicit root map
        $w.Flush()
        $result = $stream.ToArray()
    } finally {
        $w.Dispose(); $stream.Dispose()
    }

    # Read back what was just built. This is the check that would have caught
    # the missing closing byte, and the only one that proves Steam can reach the
    # entries rather than merely that the bytes are in the file.
    try {
        $check = Read-ShortcutsVdf -Bytes $result
        foreach ($entry in $entries) {
            if ($check.Names -notcontains $entry.Name) { throw "'$($entry.Name)' did not survive the round trip" }
        }
    } catch {
        Write-Warning "  $($userDir.Name): built a shortcuts.vdf that does not read back ($($_.Exception.Message)). Nothing was written."
        continue
    }

    [IO.File]::WriteAllBytes($vdf, $result)
    Write-Host "  $($userDir.Name): $($check.Names.Count) shortcut(s) in the library, $($entries.Count) of them ours."
}

Write-Host ''
Write-Host 'Switching, from now on:' -ForegroundColor Green
Write-Host '  console -> desktop : "Desktop Mode" in the Steam library'
Write-Host '  desktop -> console : the tray icon (double-click) or the desktop shortcut'
Write-Host '  either way, a reboot always comes back to the console'
