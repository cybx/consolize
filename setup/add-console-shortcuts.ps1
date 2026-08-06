<#
Puts "Desktop Mode" inside the frontend, and a way back on the desktop, so
switching between the two never needs a keyboard.

  In Steam Big Picture : a non-Steam shortcut named "Desktop Mode", navigable
                         with the controller like any other library entry
  On the Windows desktop: "Back to Console Mode.lnk"
  In the tray           : the session manager shows an icon while the desktop is
                         up (double-click returns to the console)

The three entries carry cover art drawn here and land in a collection of their
own, "Consolize", so they sit together instead of scattered among the games.

Steam keeps non-Steam shortcuts per Steam account in a binary VDF, and rewrites
that file from memory when it closes, so Steam has to be closed while we write.
The existing file is backed up next to itself first. The artwork is separate
files that Steam reads off disk, so that part needs nothing closed.

Runs as the console account (its own Steam profile), no admin needed.

  .\add-console-shortcuts.ps1
  .\add-console-shortcuts.ps1 -Force   # close Steam automatically
#>
param(
    [string]$ConsolizeExe = 'C:\Program Files\Consolize\consolize.exe',
    # The collection these end up in. Empty to leave them loose in the library.
    [string[]]$Collection = @('Consolize'),
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
    $entries = New-Object System.Collections.Generic.List[object]
    $maxIndex = -1
    $pos = 0
    $depth = 1   # the root map is open before the first byte
    $current = $null
    $inTags = $false

    while ($pos -lt $Bytes.Length) {
        $type = $Bytes[$pos]; $pos++

        if ($type -eq 8) {
            $depth--
            if ($depth -lt 0) { throw "a closing byte at $($pos - 1) with no map open" }
            if ($depth -eq 3) { $inTags = $false }
            if ($depth -eq 2 -and $current) {
                # the byte that just closed this entry is its last one
                $current.End = $pos - 1
                $entries.Add($current); $current = $null
            }
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
                    # the type byte, not the key: the entry's bytes start there,
                    # which is what lets one be copied over or dropped whole
                    $current = [pscustomobject]@{
                        Index = $key; Name = $null; AppId = $null
                        Exe = $null; Icon = $null; LaunchOptions = $null; Tags = @()
                        Start = $keyStart - 1; End = -1
                    }
                }
                if ($depth -eq 3 -and $key -eq 'tags') { $inTags = $true }
                $depth++
            }
            1 {
                $valStart = $pos
                while ($pos -lt $Bytes.Length -and $Bytes[$pos] -ne 0) { $pos++ }
                if ($pos -ge $Bytes.Length) { throw "the value of '$key' runs past the end of the file" }
                $value = [Text.Encoding]::UTF8.GetString($Bytes, $valStart, $pos - $valStart); $pos++
                if ($current -and $inTags -and $depth -eq 4) {
                    $current.Tags += $value
                } elseif ($depth -eq 3) {
                    if ($key -eq 'AppName') {
                        $names.Add($value)
                        if ($current) { $current.Name = $value }
                    } elseif ($current) {
                        switch ($key) {
                            'Exe'           { $current.Exe = $value }
                            'icon'          { $current.Icon = $value }
                            'LaunchOptions' { $current.LaunchOptions = $value }
                        }
                    }
                }
            }
            2 {
                if ($pos + 4 -gt $Bytes.Length) { throw "the value of '$key' runs past the end of the file" }
                if ($key -eq 'appid' -and $depth -eq 3 -and $current) {
                    $current.AppId = [BitConverter]::ToInt32($Bytes, $pos)
                }
                $pos += 4
            }
            default { throw "unknown field type 0x$('{0:X2}' -f $type) at byte $($pos - 1)" }
        }
    }

    if ($depth -ne 0) { throw "the file ends with $depth map(s) still open" }
    return [pscustomobject]@{ Names = $names; Entries = $entries; MaxIndex = $maxIndex }
}

# Steam's id for a non-Steam shortcut, per Valve's own documentation: CRC-32 of
# AppName + Exe + a trailing NUL, encoded Windows-1252, with the top bit set.
#
# Three details that all look like noise and are not. The order is name then
# exe, not the other way round. The NUL is part of the input. And the encoding
# is Windows-1252, not UTF-8, which only diverges once a name carries an accent,
# which is exactly when a Brazilian machine would find out.
#
# Steam invents an id when the field is absent, and an invented id is a
# different number every rewrite, so artwork filed under the old one stops being
# found. Writing it is what keeps the artwork attached.
function Get-ShortcutAppId {
    param([string]$Exe, [string]$AppName)
    # The L suffixes are not decoration. PowerShell reads an eight digit hex
    # literal as a 32 bit pattern, so a bare 0xFFFFFFFF is Int32 -1 and a bare
    # 0x80000000 is Int32 -2147483648. Without the suffix this starts at -1,
    # every shift is arithmetic on a negative number, and the result is not a
    # CRC at all. Checked against the standard vector: "123456789" -> 0xCBF43926.
    $bytes = [Text.Encoding]::GetEncoding(1252).GetBytes($AppName + $Exe + "`0")
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

$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$updateScript = Join-Path $PSScriptRoot 'update-console.ps1'

$iconFile = Join-Path (Split-Path $ConsolizeExe) 'consolize.ico'
if (-not (Test-Path $iconFile)) { $iconFile = $ConsolizeExe }

# Glyphs come from Segoe MDL2 Assets, which ships with Windows 10 and 11, so
# the artwork needs no files of its own and cannot arrive half installed.
$entries = @(
    @{ Name = 'Quick Settings'; Exe = $ConsolizeExe; Args = 'panel'
       Glyph = [char]0xE713; Accent = @(96, 190, 255) }
    @{ Name = 'Desktop Mode';   Exe = $ConsolizeExe; Args = 'send desktop'
       Glyph = [char]0xE7F4; Accent = @(150, 220, 140) }
    @{ Name = 'Update consolize'; Exe = $powershell
       Args = "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`""
       Glyph = [char]0xE777; Accent = @(232, 180, 100) }
)

# Steam looks for artwork in config\grid, named after the shortcut's appid in
# its unsigned form. The appid stored in the file is a signed 32 bit integer and
# ours are all negative, so the two never look alike: -1680150366 on one side,
# 2614816930 on the other. Get that wrong and the files sit there being ignored.
#
#   <appid>p.png      600x900   the portrait capsule, the one the library grid shows
#   <appid>.png       920x430   the landscape capsule, used in lists and Big Picture
#   <appid>_hero.png  1920x620  the banner across the top of the game's page
#   <appid>_logo.png            drawn over the hero, so it has to be transparent
function Write-ShortcutArtwork {
    param([string]$GridDir, [int]$AppId, [string]$Name, [char]$Glyph, [int[]]$Accent)

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($AppId), 0)
    $accentColor = [System.Drawing.Color]::FromArgb($Accent[0], $Accent[1], $Accent[2])

    function New-Art {
        param([int]$W, [int]$H, [string]$Path, [bool]$Transparent, [double]$GlyphScale)
        $bmp = New-Object System.Drawing.Bitmap($W, $H)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = 'AntiAlias'
            $g.TextRenderingHint = 'ClearTypeGridFit'
            $g.InterpolationMode = 'HighQualityBicubic'

            if (-not $Transparent) {
                $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
                $top = [System.Drawing.Color]::FromArgb(20, 24, 34)
                $bottom = [System.Drawing.Color]::FromArgb(9, 11, 16)
                $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $top, $bottom, 90)
                $g.FillRectangle($bg, $rect); $bg.Dispose()

                # a wash of the accent behind the glyph, so the three entries are
                # told apart at a glance in a grid of cover art
                $glow = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb(26, $accentColor.R, $accentColor.G, $accentColor.B))
                $r = [int]($H * 0.55)
                $g.FillEllipse($glow, [int]($W / 2 - $r), [int]($H * 0.30 - $r), $r * 2, $r * 2)
                $glow.Dispose()
            }

            $centre = New-Object System.Drawing.StringFormat
            $centre.Alignment = 'Center'; $centre.LineAlignment = 'Center'

            if (-not $Transparent) {
                $glyphFont = New-Object System.Drawing.Font('Segoe MDL2 Assets', [single]($H * $GlyphScale), 'Regular', 'Pixel')
                $glyphBrush = New-Object System.Drawing.SolidBrush($accentColor)
                $g.DrawString([string]$Glyph, $glyphFont, $glyphBrush,
                    (New-Object System.Drawing.RectangleF(0, [single]($H * 0.06), $W, [single]($H * 0.46))), $centre)
                $glyphFont.Dispose(); $glyphBrush.Dispose()
            }

            # The logo is drawn over the hero rather than beside it, so with no
            # background to sit on its text moves up to fill the space the glyph
            # would have taken.
            $nameTop = if ($Transparent) { 0.20 } else { 0.58 }
            $markTop = if ($Transparent) { 0.58 } else { 0.82 }

            $nameFont = New-Object System.Drawing.Font('Segoe UI', [single]($H * 0.075), 'Regular', 'Pixel')
            $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(238, 243, 252))
            $g.DrawString($Name, $nameFont, $white,
                (New-Object System.Drawing.RectangleF(
                    [single]($W * 0.05), [single]($H * $nameTop),
                    [single]($W * 0.90), [single]($H * 0.30))), $centre)
            $nameFont.Dispose(); $white.Dispose()

            $markFont = New-Object System.Drawing.Font('Segoe UI', [single]($H * 0.040), 'Regular', 'Pixel')
            $muted = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb(190, $accentColor.R, $accentColor.G, $accentColor.B))
            $g.DrawString('consolize', $markFont, $muted,
                (New-Object System.Drawing.RectangleF(
                    0, [single]($H * $markTop), $W, [single]($H * 0.14))), $centre)
            $markFont.Dispose(); $muted.Dispose()
            $centre.Dispose()

            $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $g.Dispose(); $bmp.Dispose() }
    }

    New-Art 600  900  (Join-Path $GridDir "${unsigned}p.png")     $false 0.30
    New-Art 920  430  (Join-Path $GridDir "$unsigned.png")        $false 0.34
    New-Art 1920 620  (Join-Path $GridDir "${unsigned}_hero.png") $false 0.30
    New-Art 1280 360  (Join-Path $GridDir "${unsigned}_logo.png") $true  0
}

# Artwork is written whether or not the entries need touching, and without
# closing Steam: these are plain files read off disk, not state Steam holds in
# memory. That way a machine set up before this existed picks it up on the next
# update instead of needing the shortcuts rewritten.
foreach ($userDir in $userDirs) {
    $gridDir = Join-Path $userDir.FullName 'config\grid'
    New-Item -ItemType Directory -Force -Path $gridDir | Out-Null
    foreach ($entry in $entries) {
        $appId = Get-ShortcutAppId -Exe "`"$($entry.Exe)`"" -AppName $entry.Name
        try {
            Write-ShortcutArtwork -GridDir $gridDir -AppId $appId -Name $entry.Name `
                -Glyph $entry.Glyph -Accent $entry.Accent
        } catch {
            Write-Warning "  could not draw the artwork for '$($entry.Name)': $($_.Exception.Message)"
        }
    }
    Write-Host "  $($userDir.Name): artwork written to config\grid"
}

# Decide before closing anything. This runs again on every update, and on a
# machine that is already set up, killing Steam only to find there was nothing
# to do would throw the player out of whatever they were in the middle of.
#
# "Present" is not enough, and neither is the appid on its own. Everything this
# writes can change between versions: where the binary lives, what arguments an
# entry passes, which icon it points at, which collection it joins. Comparing
# only the name would freeze the entry as first written and no fix would ever
# reach a machine that already ran this. So the whole record is compared.
$wanted = @{}
foreach ($entry in $entries) {
    $wanted[$entry.Name] = [pscustomobject]@{
        AppId = Get-ShortcutAppId -Exe "`"$($entry.Exe)`"" -AppName $entry.Name
        Exe = "`"$($entry.Exe)`""
        Icon = $iconFile
        LaunchOptions = $entry.Args
        Tags = $Collection
    }
}

function Test-EntryCurrent {
    param($Found, $Wanted)
    if (-not $Found) { return $false }
    if ($Found.AppId -ne $Wanted.AppId) { return $false }
    if ($Found.Exe -ne $Wanted.Exe) { return $false }
    if ($Found.Icon -ne $Wanted.Icon) { return $false }
    if ($Found.LaunchOptions -ne $Wanted.LaunchOptions) { return $false }
    if (@($Found.Tags).Count -ne @($Wanted.Tags).Count) { return $false }
    foreach ($tag in $Wanted.Tags) { if ($Found.Tags -notcontains $tag) { return $false } }
    return $true
}

$needsWork = $false
foreach ($userDir in $userDirs) {
    $vdf = Join-Path $userDir.FullName 'config\shortcuts.vdf'
    if (-not (Test-Path $vdf)) { $needsWork = $true; break }
    try {
        $parsed = Read-ShortcutsVdf -Bytes ([IO.File]::ReadAllBytes($vdf))
        foreach ($name in $wanted.Keys) {
            $mine = $parsed.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not (Test-EntryCurrent -Found $mine -Wanted $wanted[$name])) { $needsWork = $true; break }
        }
        if ($needsWork) { break }
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

    # Steam creates this file on its own, so refusing whenever it existed meant
    # the entries were almost never written and the library came up without a
    # way to reach the desktop. What is kept is every entry that is not one of
    # ours, copied byte for byte: a library belongs to whoever built it, and
    # reserialising someone else's entries from my own parse would quietly drop
    # any field this does not know about.
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
        $current = @($existing.Entries | Where-Object {
            $wanted.ContainsKey($_.Name) -and (Test-EntryCurrent -Found $_ -Wanted $wanted[$_.Name])
        })
        if ($current.Count -eq $entries.Count) {
            Write-Host "  $($userDir.Name): already has the console entries, leaving it alone."
            continue
        }

        $backup = "$vdf.consolize-backup"
        if (-not (Test-Path $backup)) { Copy-Item $vdf $backup }

        $keep = @($existing.Entries | Where-Object { -not $wanted.ContainsKey($_.Name) })
        $stale = $existing.Entries.Count - $keep.Count

        # Indexes, not a count: a file with entries 0, 1 and 5 has three of them,
        # and starting at 3 would collide with 5.
        $firstIndex = $existing.MaxIndex + 1

        $note = "  $($userDir.Name): $($keep.Count) shortcut(s) of yours kept"
        if ($stale) { $note += ", $stale stale console entr$(if ($stale -eq 1) { 'y' } else { 'ies' }) replaced" }
        Write-Host "$note (backup: $(Split-Path $backup -Leaf))"
    }

    # Built in memory and checked before it replaces anything on disk. The file
    # being written here is someone's library.
    $stream = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($stream)
    try {
        $w.Write([byte]0)
        $w.Write([Text.Encoding]::UTF8.GetBytes('shortcuts')); $w.Write([byte]0)

        # Verbatim, index key included, so nothing of theirs is renumbered and
        # nothing of theirs is reinterpreted.
        foreach ($kept in $keep) {
            $w.Write($bytes, $kept.Start, $kept.End - $kept.Start + 1)
        }

        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            $index = $firstIndex + $i

            $w.Write([byte]0)
            $w.Write([Text.Encoding]::UTF8.GetBytes("$index")); $w.Write([byte]0)

            # Same call as the artwork uses, so the id in the file and the names
            # of the image files can never drift apart.
            Add-VdfInt $w 'appid' (Get-ShortcutAppId -Exe "`"$($entry.Exe)`"" -AppName $entry.Name)
            Add-VdfString $w 'AppName' $entry.Name
            Add-VdfString $w 'Exe' "`"$($entry.Exe)`""
            Add-VdfString $w 'StartDir' "`"$(Split-Path $entry.Exe)`""
            # Always our icon, even when the target is powershell.exe. The .ico
            # beside the binary is preferred over the binary itself: pointing at
            # an exe makes Steam extract whatever size the icon resource happens
            # to carry, and both the library and Big Picture draw it bigger than
            # that. Falls back to the exe when the file is not there.
            Add-VdfString $w 'icon' $iconFile
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

            # The tags map is what Steam reads as the shortcut's categories, and
            # a category is what the library shows as a collection. Keys are the
            # position in the list, values are the names. One tag, so the three
            # entries land together under "Consolize" instead of loose among the
            # games.
            $w.Write([byte]0)
            $w.Write([Text.Encoding]::UTF8.GetBytes('tags')); $w.Write([byte]0)
            for ($t = 0; $t -lt $Collection.Count; $t++) {
                Add-VdfString $w "$t" $Collection[$t]
            }
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
