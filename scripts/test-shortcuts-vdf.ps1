<#
Tests add-console-shortcuts.ps1 against a throwaway Steam tree.

Worth having because the failure mode here is silent: a shortcuts.vdf can hold
every byte of a shortcut and still be a file Steam ignores, so "the name is in
the file" proves nothing. Every case below therefore parses the result with a
second parser, written from the format description rather than from the code
under test, and asks what Steam would actually load.

The real script is used, with only Steam discovery and the kill of a running
Steam patched out, so the Steam on this machine is never touched.

  pwsh -File scripts/test-shortcuts-vdf.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ("consolize-vdf-test-{0}-{1}" -f $PID, [guid]::NewGuid().ToString('N'))
$fakeSteam = Join-Path $root 'Steam'
New-Item -ItemType Directory -Force -Path (Join-Path $fakeSteam 'userdata\7777777\config') | Out-Null
$fakeDesktop = Join-Path $root 'Desktop'
New-Item -ItemType Directory -Force -Path $fakeDesktop | Out-Null
$fakeState = Join-Path $root 'ProgramData\Consolize'
New-Item -ItemType Directory -Force -Path $fakeState | Out-Null
Set-Content (Join-Path $fakeSteam 'steam.exe') 'stub'
$exe = Join-Path $root 'consolize.exe'
New-Item -ItemType Directory -Force -Path $root | Out-Null
Set-Content $exe 'stub'

# real script, with only the Steam-discovery swapped for the fake tree
$src = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'setup\add-console-shortcuts.ps1') -Raw
$patched = $src -replace '(?s)function Get-SteamPath \{.*?\n\}', "function Get-SteamPath { return `$env:FAKE_STEAM }"
if ($patched -eq $src) { throw 'patch of Get-SteamPath did not apply' }
# The production script also writes a desktop shortcut. Keep that inside the
# throwaway tree: a test must never overwrite or delete the developer's real
# "Back to Console Mode.lnk".
$before = $patched
$patched = $patched -replace '\$desktop = \[Environment\]::GetFolderPath\(''Desktop''\)', '$desktop = $env:FAKE_DESKTOP'
if ($patched -eq $before) { throw 'patch of the Desktop path did not apply' }
$before = $patched
$patched = $patched -replace '\$extrasFile = Join-Path \$env:ProgramData ''Consolize\\shared\\extra-shortcuts\.json''', '$extrasFile = Join-Path $env:FAKE_STATE ''shared\extra-shortcuts.json'''
if ($patched -eq $before) { throw 'patch of the extra-shortcuts path did not apply' }
$before = $patched
$patched = $patched -replace '\$legacyExtrasFile = Join-Path \$env:ProgramData ''Consolize\\extra-shortcuts\.json''', '$legacyExtrasFile = Join-Path $env:FAKE_STATE ''legacy-extra-shortcuts.json'''
if ($patched -eq $before) { throw 'patch of the legacy extra-shortcuts path did not apply' }
# never touch the Steam running on this machine
$before = $patched
$patched = $patched -replace '\$steamProc = Get-Process steam[^\r\n]*', '$steamProc = $null'
if ($patched -eq $before) { throw 'patch of the Steam process check did not apply' }
# and never read the developer's real Consolize config: the machine running the
# tests may boot into another frontend, and the suite must not notice
$before = $patched
$patched = $patched -replace '(?s)function Get-ConfiguredFrontend \{.*?\n\}', "function Get-ConfiguredFrontend { if (`$env:FAKE_FRONTEND) { return `$env:FAKE_FRONTEND } return 'steam' }"
if ($patched -eq $before) { throw 'patch of Get-ConfiguredFrontend did not apply' }
$script = Join-Path $root 'under-test.ps1'
Set-Content $script $patched
$env:FAKE_STEAM = $fakeSteam
$env:FAKE_DESKTOP = $fakeDesktop
$env:FAKE_STATE = $fakeState
$vdf = Join-Path $fakeSteam 'userdata\7777777\config\shortcuts.vdf'

# an independent parser, written from the format description rather than from
# the code under test, so a shared misunderstanding cannot pass both
function Parse-Vdf {
    param([byte[]]$B)
    $p = 0; $depth = 1; $out = @(); $cur = $null; $inTags = $false
    while ($p -lt $B.Length) {
        $t = $B[$p]; $p++
        if ($t -eq 8) {
            $depth--
            if ($depth -eq 3) { $inTags = $false }
            if ($depth -eq 2 -and $cur) { $out += ,$cur; $cur = $null }
            if ($depth -lt 0) { throw "underflow at $p" }
            if ($depth -eq 0 -and $p -ne $B.Length) { throw "root closed at $p of $($B.Length)" }
            continue
        }
        $s = $p; while ($B[$p] -ne 0) { $p++ }
        $k = [Text.Encoding]::UTF8.GetString($B, $s, $p - $s); $p++
        if ($t -eq 0) {
            if ($depth -eq 2) { $cur = @{ Index = $k; Tags = @() } }
            if ($depth -eq 3 -and $k -eq 'tags') { $inTags = $true }
            $depth++
        }
        elseif ($t -eq 1) { $s = $p; while ($B[$p] -ne 0) { $p++ }
            $v = [Text.Encoding]::UTF8.GetString($B, $s, $p - $s); $p++
            if ($cur -and $depth -eq 4 -and $inTags) { $cur.Tags += $v }
            elseif ($cur -and $depth -eq 3) { $cur[$k] = $v } }
        elseif ($t -eq 2) { if ($cur -and $depth -eq 3) { $cur[$k] = [BitConverter]::ToInt32($B, $p) }; $p += 4 }
        else { throw "bad type $t at $($p-1)" }
    }
    if ($depth -ne 0) { throw "$depth map(s) still open at EOF" }
    # the comma matters: PowerShell unrolls a one element array on return, and a
    # single entry would come back as the hashtable itself, whose .Count is its
    # number of keys. Two checks "failed" on a result that was correct.
    return , $out
}

function Build-SteamFile {
    param([string[]]$Names, [int[]]$Indexes, [string[]]$Exes)
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $w.Write([byte]0); $w.Write([Text.Encoding]::UTF8.GetBytes('shortcuts')); $w.Write([byte]0)
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $key = if ($Indexes) { "$($Indexes[$i])" } else { "$i" }
        $w.Write([byte]0); $w.Write([Text.Encoding]::UTF8.GetBytes($key)); $w.Write([byte]0)
        $w.Write([byte]2); $w.Write([Text.Encoding]::UTF8.GetBytes('appid')); $w.Write([byte]0); $w.Write([int]-1234)
        $w.Write([byte]1); $w.Write([Text.Encoding]::UTF8.GetBytes('AppName')); $w.Write([byte]0)
        $w.Write([Text.Encoding]::UTF8.GetBytes($Names[$i])); $w.Write([byte]0)
        $target = if ($Exes) { $Exes[$i] } else { 'C:\g\g.exe' }
        $w.Write([byte]1); $w.Write([Text.Encoding]::UTF8.GetBytes('Exe')); $w.Write([byte]0)
        $w.Write([Text.Encoding]::UTF8.GetBytes("`"$target`"")); $w.Write([byte]0)
        $w.Write([byte]0); $w.Write([Text.Encoding]::UTF8.GetBytes('tags')); $w.Write([byte]0); $w.Write([byte]8)
        $w.Write([byte]8)
    }
    $w.Write([byte]8); $w.Write([byte]8)
    $w.Flush(); $b = $ms.ToArray(); $w.Dispose(); $ms.Dispose(); return $b
}

$fail = 0
function Check($label, $ok, $detail) {
    if ($ok) { Write-Host "  PASS  $label" -ForegroundColor Green }
    else { Write-Host "  FAIL  $label -- $detail" -ForegroundColor Red; $script:fail++ }
}

Write-Host "`n1. Steam's own empty file is 13 bytes and ends 08 08"
$empty = Build-SteamFile @()
Check 'empty file shape' ($empty.Length -eq 13 -and $empty[11] -eq 8 -and $empty[12] -eq 8) "len=$($empty.Length)"

Write-Host "`n2. fresh machine, no shortcuts.vdf at all"
Remove-Item $vdf -Force -ErrorAction SilentlyContinue
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check 'file parses as a whole document' $true ''
Check '3 entries' ($got.Count -eq 3) "got $($got.Count)"
Check 'Desktop Mode present' ($got.AppName -contains 'Desktop Mode') "$($got.AppName -join ', ')"
Check 'every entry has an appid' (($got | Where-Object { $_.appid }).Count -eq 3) 'missing appid'
Check 'appids are distinct' ((($got.appid | Select-Object -Unique).Count) -eq 3) "$($got.appid -join ', ')"
Check 'appids have the top bit set' (($got.appid | Where-Object { $_ -lt 0 }).Count -eq 3) "$($got.appid -join ', ')"

Write-Host "`n2b. the artwork and the collection"
# Asserted, not merely attempted: the script warns and carries on when drawing
# fails, which is right at run time and useless in a test. A run where every
# image failed still printed "artwork written".
$grid = Join-Path $fakeSteam 'userdata\7777777\config\grid'
Add-Type -AssemblyName System.Drawing
foreach ($e in $got) {
    $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.appid), 0)
    foreach ($suffix in @('p.png', '.png', '_hero.png', '_logo.png')) {
        $img = Join-Path $grid "$u$suffix"
        if (-not (Test-Path $img)) { Check "$($e.AppName) $suffix exists" $false 'missing'; continue }
        try {
            $bitmap = [System.Drawing.Image]::FromFile($img)
            $size = "$($bitmap.Width)x$($bitmap.Height)"; $bitmap.Dispose()
            Check "$($e.AppName) $suffix is a real image ($size)" $true ''
        } catch { Check "$($e.AppName) $suffix is a real image" $false $_.Exception.Message }
    }
}
Check 'artwork is named after the unsigned appid' (
    (Get-ChildItem $grid -Filter '*.png').Count -eq 12) "$((Get-ChildItem $grid -Filter '*.png').Count) files"
Check 'every entry is tagged Consolize' (
    ($got | Where-Object { $_.Tags -contains 'Consolize' }).Count -eq 3) "$(($got | ForEach-Object { $_.Tags -join '/' }) -join ' | ')"

Write-Host "`n3. a library that already has games, appended to"
[IO.File]::WriteAllBytes($vdf, (Build-SteamFile @('Cyberpunk', 'Elden Ring')))
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check '5 entries' ($got.Count -eq 5) "got $($got.Count)"
Check 'existing games survived' (($got.AppName -contains 'Cyberpunk') -and ($got.AppName -contains 'Elden Ring')) "$($got.AppName -join ', ')"
Check 'ours were added' ($got.AppName -contains 'Desktop Mode') "$($got.AppName -join ', ')"
Check 'indexes are unique' ((($got.Index | Select-Object -Unique).Count) -eq 5) "$($got.Index -join ', ')"
Check 'backup was taken' (Test-Path "$vdf.consolize-backup") 'no backup'

Write-Host "`n4. running twice does not duplicate"
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check 'still 5 entries' ($got.Count -eq 5) "got $($got.Count)"

Write-Host "`n5. non-contiguous indexes (0, 1, 5) do not collide"
[IO.File]::WriteAllBytes($vdf, (Build-SteamFile -Names @('A', 'B', 'C') -Indexes @(0, 1, 5)))
Remove-Item "$vdf.consolize-backup" -Force -ErrorAction SilentlyContinue
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check '6 entries' ($got.Count -eq 6) "got $($got.Count)"
Check 'no index collision' ((($got.Index | Select-Object -Unique).Count) -eq 6) "$($got.Index -join ', ')"

Write-Host "`n6. a file left unterminated by the old buggy version is repaired"
$b = Build-SteamFile @('Cyberpunk')
$broken = New-Object byte[] ($b.Length - 1)     # one closing byte short, as before
[Array]::Copy($b, $broken, $b.Length - 1)
[IO.File]::WriteAllBytes($vdf, $broken)
Remove-Item "$vdf.consolize-backup" -Force -ErrorAction SilentlyContinue
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check 'repaired and complete' ($got.Count -eq 4) "got $($got.Count)"
Check 'the game survived the repair' ($got.AppName -contains 'Cyberpunk') "$($got.AppName -join ', ')"

Write-Host "`n7. a file this does not understand is left untouched"
$garbage = [byte[]](0, 5, 99, 0, 3, 200, 77)
[IO.File]::WriteAllBytes($vdf, $garbage)
& $script -ConsolizeExe $exe -Force -WarningAction SilentlyContinue | Out-Null
$after = [IO.File]::ReadAllBytes($vdf)
Check 'bytes unchanged' (-not (Compare-Object $garbage $after)) 'the file was modified'

Write-Host "`n8. our own entries with a stale appid are replaced, not duplicated"
# The id changed once already, when the formula was corrected. When it does, the
# artwork is filed under a number nothing looks up, so the entry has to be
# rewritten rather than recognised by name and left alone.
[IO.File]::WriteAllBytes($vdf, (Build-SteamFile @('Cyberpunk', 'Desktop Mode', 'Quick Settings', 'Update consolize')))
Remove-Item "$vdf.consolize-backup" -Force -ErrorAction SilentlyContinue
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
$desktop = @($got | Where-Object { $_.AppName -eq 'Desktop Mode' })
Check '4 entries, not 7' ($got.Count -eq 4) "got $($got.Count): $($got.AppName -join ', ')"
Check 'the game survived' ($got.AppName -contains 'Cyberpunk') "$($got.AppName -join ', ')"
Check 'exactly one Desktop Mode' ($desktop.Count -eq 1) "got $($desktop.Count)"
Check 'the stale appid is gone' ($desktop[0].appid -ne -1234) "still $($desktop[0].appid)"
Check 'the replacement is tagged' ($desktop[0].Tags -contains 'Consolize') "$($desktop[0].Tags -join '/')"
$img = Join-Path $grid ("{0}p.png" -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$desktop[0].appid), 0))
Check 'artwork matches the new appid' (Test-Path $img) "no $([IO.Path]::GetFileName($img))"

Write-Host "`n9. a change to any field we write reaches a machine already set up"
# Not just the appid. The icon moved from the exe to an .ico beside it and the
# entries stayed as first written, because the freshness check only compared the
# name and the id. Everything written is compared now.
Copy-Item 'C:\Windows\System32\shell32.dll' (Join-Path $root 'consolize.ico') -Force
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
$desktop = @($got | Where-Object { $_.AppName -eq 'Desktop Mode' })
Check 'the icon now points at the .ico beside the exe' (
    $desktop[0].icon -eq (Join-Path $root 'consolize.ico')) "still $($desktop[0].icon)"
Check 'still 4 entries' ($got.Count -eq 4) "got $($got.Count)"
Remove-Item (Join-Path $root 'consolize.ico') -Force
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
$desktop = @($got | Where-Object { $_.AppName -eq 'Desktop Mode' })
Check 'and falls back to the exe when it is gone' ($desktop[0].icon -eq $exe) "got $($desktop[0].icon)"

Write-Host "`n10. a stray of ours under a name we no longer use is cleaned up"
# The library came back with two of everything. Recognising our entries only by
# their exact name cannot see a duplicate added by hand or left by a version
# that called it something else, so it sat there beside the real one. What
# cannot drift is where an entry points, so that is what identifies it now.
# the stray points at our exe, which is what makes it ours whatever it is called
[IO.File]::WriteAllBytes($vdf, (Build-SteamFile -Names @('Cyberpunk', 'Modo Desktop') `
    -Indexes @(0, 1) -Exes @('C:\g\g.exe', $exe)))
& $script -ConsolizeExe $exe -Force | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check 'the stray was recognised by its target and dropped' (
    $got.AppName -notcontains 'Modo Desktop') "$($got.AppName -join ', ')"
Check 'the real game was kept' ($got.AppName -contains 'Cyberpunk') "$($got.AppName -join ', ')"
Check '4 entries, not 5' ($got.Count -eq 4) "got $($got.Count)"

Write-Host "`n11. -Remove takes ours out and leaves the rest"
& $script -ConsolizeExe $exe -Force -Remove | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check 'only the game is left' ($got.Count -eq 1 -and $got[0].AppName -eq 'Cyberpunk') "$($got.AppName -join ', ')"
Check 'the artwork went with them' ((Get-ChildItem $grid -Filter '*.png').Count -eq 0) `
    "$((Get-ChildItem $grid -Filter '*.png').Count) file(s) left"
Check 'the desktop shortcut is gone' (
    -not (Test-Path (Join-Path $fakeDesktop 'Back to Console Mode.lnk'))) 'still there'
& $script -ConsolizeExe $exe -Force -Remove 2>&1 | Out-Null
$got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
Check 'removing twice is harmless' ($got.Count -eq 1) "got $($got.Count)"

Write-Host "`n12. artwork from a previous appid does not pile up"
& $script -ConsolizeExe $exe -Force | Out-Null
$before = (Get-ChildItem $grid -Filter '*.png').Count
$exe2 = Join-Path $root 'consolize-moved.exe'
Copy-Item $exe $exe2 -Force
& $script -ConsolizeExe $exe2 -Force | Out-Null
$after = (Get-ChildItem $grid -Filter '*.png').Count
Check 'the binary moved, the old images went too' ($after -eq $before) "$before before, $after after"
Check 'and the entries followed it' (
    (Parse-Vdf ([IO.File]::ReadAllBytes($vdf))).Count -eq 4) 'entry count changed'

Write-Host "`n13. an app the owner added gets an entry, artwork and the collection"
# Steam can add a non-Steam game itself, but that needs a mouse and a file
# browser, which is exactly what a machine booting into Big Picture does not
# have. The list is a file instead.
$extrasDir = $fakeState
$extrasFile = Join-Path $extrasDir 'shared\extra-shortcuts.json'
try {
    $someApp = Join-Path $root 'SomeApp.exe'
    $someArtwork = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\splash.png'
    Set-Content $someApp 'stub'
    New-Item -ItemType Directory -Force -Path (Split-Path $extrasFile) | Out-Null
    $addAppSource = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'setup\add-app-shortcut.ps1') -Raw
    $addAppPatched = $addAppSource -replace '\$stateDir = Join-Path \$env:ProgramData ''Consolize''', '$stateDir = $env:FAKE_STATE'
    if ($addAppPatched -eq $addAppSource) { throw 'patch of add-app-shortcut state path did not apply' }
    $addApp = Join-Path $root 'add-app-under-test.ps1'
    Set-Content $addApp $addAppPatched
    & $addApp -Name 'RetroArch' -Exe $someApp -Arguments '--fullscreen' `
        -Artwork $someArtwork -NoApply | Out-Null
    $savedExtras = @(Get-Content $extrasFile -Raw | ConvertFrom-Json)
    Check 'a one-item extras file is a JSON array in Windows PowerShell 5.1' `
        ($savedExtras.Count -eq 1 -and $savedExtras[0].name -eq 'RetroArch') `
        (Get-Content $extrasFile -Raw)

    $secondApp = Join-Path $root 'SecondApp.exe'
    Set-Content $secondApp 'stub'
    & $addApp -Name 'Second App' -Exe $secondApp -NoApply | Out-Null

    # Apply while both are present. In Windows PowerShell 5.1, wrapping the
    # ConvertFrom-Json call in @() turns its Object[] into a nested array and
    # add-console-shortcuts used to treat both apps as one malformed entry.
    & $script -ConsolizeExe $exe -Force -Remove *> $null
    & $script -ConsolizeExe $exe -Force | Out-Null
    $got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
    Check 'multiple extras stay separate in Windows PowerShell 5.1' (
        $got.AppName -contains 'RetroArch' -and $got.AppName -contains 'Second App') `
        ($got.AppName -join ', ')

    # Keep the remainder focused on the original extra. Remove the throwaway
    # library entries while both are still recognisable, then drop the record.
    & $script -ConsolizeExe $exe -Force -Remove *> $null
    & $addApp -Name 'Second App' -Delete | Out-Null
    & $script -ConsolizeExe $exe -Force | Out-Null
    $got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
    $extra = @($got | Where-Object { $_.AppName -eq 'RetroArch' })

    Check 'the added app is in the library' ($extra.Count -eq 1) "$($got.AppName -join ', ')"
    Check 'with its arguments' ($extra[0].LaunchOptions -eq '--fullscreen') "got '$($extra[0].LaunchOptions)'"
    Check 'in the Consolize collection' ($extra[0].Tags -contains 'Consolize') "$($extra[0].Tags -join '/')"
    # GitHub's runner exposes TEMP through its 8.3 alias (RUNNER~1), while
    # GetFullPath in add-app-shortcut expands it to runneradmin. They name the
    # same file; what matters here is that the extra uses its executable rather
    # than Consolize's icon.
    $ownIcon = [IO.Path]::GetFileName($extra[0].icon) -eq [IO.Path]::GetFileName($someApp) -and
               $extra[0].icon -ne $exe
    Check 'and its own icon, not ours' $ownIcon "got $($extra[0].icon)"
    $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$extra[0].appid), 0)
    Check 'artwork was drawn for it' (Test-Path (Join-Path $grid "${u}p.png")) "no ${u}p.png"

    # An entry naming a program that is not installed would launch nothing.
    ConvertTo-Json -InputObject @([pscustomobject]@{ name = 'Ghost'; exe = 'C:\nope\ghost.exe'; args = '' }) `
        -Depth 4 | Set-Content $extrasFile
    & $script -ConsolizeExe $exe -Force -WarningAction SilentlyContinue | Out-Null
    $got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
    Check 'an app that is not installed is skipped' ($got.AppName -notcontains 'Ghost') "$($got.AppName -join ', ')"
} finally {
    Remove-Item $extrasFile -Force -ErrorAction SilentlyContinue
}

Write-Host "`n14. the old ProgramData shortcut list migrates without losing apps"
$legacyExtras = Join-Path $extrasDir 'extra-shortcuts.json'
$legacyExe = Join-Path $root 'LegacyApp.exe'
Set-Content $legacyExe 'stub'
ConvertTo-Json -InputObject @([pscustomobject]@{
    name = 'Legacy App'; exe = $legacyExe; args = ''; glyph = ''; artwork = ''
}) -Depth 4 | Set-Content $legacyExtras
try {
    & $addApp -Name 'New App' -Exe $someApp -NoApply | Out-Null
    # No @(): PowerShell 5.1 already returns the JSON array as one Object[];
    # wrapping it would make an array whose only member is that array.
    $migrated = Get-Content $extrasFile -Raw | ConvertFrom-Json
    Check 'legacy and new entries are both in the protected shared list' `
        ($migrated.Count -eq 2 -and $migrated.name -contains 'Legacy App' -and $migrated.name -contains 'New App') `
        (($migrated | Select-Object -ExpandProperty name) -join ', ')
} finally {
    Remove-Item $extrasFile, $legacyExtras -Force -ErrorAction SilentlyContinue
}

Write-Host "`n15. an added app can carry its own icon, not the launcher's"
# Six streaming services all launch msedge.exe. Without this the library shows
# six identical Edge logos, which was the single thing making the shelf read as
# a list of browser windows rather than a set of apps.
$browser = Join-Path $root 'browser.exe'; Set-Content $browser 'stub'
$ownIcon = Join-Path $root 'service-icon.png'
$blank = New-Object System.Drawing.Bitmap(64, 64)
$blank.Save($ownIcon, [System.Drawing.Imaging.ImageFormat]::Png); $blank.Dispose()
try {
    & $addApp -Name 'Netflix' -Exe $browser -Arguments '--app=x' -Icon $ownIcon -NoApply | Out-Null
    & $script -ConsolizeExe $exe -Force -Remove *> $null
    & $script -ConsolizeExe $exe -Force | Out-Null
    $entry = @((Parse-Vdf ([IO.File]::ReadAllBytes($vdf))) | Where-Object { $_.AppName -eq 'Netflix' })

    # By file name, not by full path. On a machine whose TEMP has an 8.3 short
    # name, as the CI runner's does (RUNNER~1 against runneradmin), the same
    # file arrives spelled two ways and a string comparison rejects the correct
    # answer. This passed locally for exactly that reason and failed on CI.
    Check 'the entry is there' ($entry.Count -eq 1) 'not found'
    Check 'its icon is its own, not the launcher' (
        [IO.Path]::GetFileName($entry[0].icon) -eq [IO.Path]::GetFileName($ownIcon)
    ) "got $($entry[0].icon)"
    # Not a "*consolize*" match: the whole test tree lives under a directory
    # with that word in it, so the pattern was true of the correct answer too.
    Check 'and not our own binary or icon' (
        [IO.Path]::GetFileName($entry[0].icon) -notin @('consolize.exe', 'consolize.ico')
    ) "got $($entry[0].icon)"

    # An icon deleted since must not be written, or Steam draws a blank where a
    # logo should be.
    Remove-Item $ownIcon -Force
    & $script -ConsolizeExe $exe -Force -Remove *> $null
    & $script -ConsolizeExe $exe -Force -WarningAction SilentlyContinue | Out-Null
    $entry = @((Parse-Vdf ([IO.File]::ReadAllBytes($vdf))) | Where-Object { $_.AppName -eq 'Netflix' })
    Check 'a missing icon file falls back to the target' (
        [IO.Path]::GetFileName($entry[0].icon) -eq [IO.Path]::GetFileName($browser)
    ) "got $($entry[0].icon)"
} finally {
    Remove-Item $extrasFile -Force -ErrorAction SilentlyContinue
}

Write-Host "`n16. another frontend configured: Steam's library is left alone"
# The machine may boot into Playnite or Hydra; entries written into Steam would
# sit in a library the console never opens. The desktop link is still made (the
# way back is frontend-agnostic), Steam's file is not touched, -SteamAnyway
# overrides, and -Remove is never gated, because uninstall runs it.
$env:FAKE_FRONTEND = 'playnite'
try {
    [IO.File]::WriteAllBytes($vdf, (Build-SteamFile @('Cyberpunk')))
    Remove-Item (Join-Path $fakeDesktop 'Back to Console Mode.lnk') -Force -ErrorAction SilentlyContinue
    $bytesBefore = [IO.File]::ReadAllBytes($vdf)
    $said = & $script -ConsolizeExe $exe -Force *>&1 | Out-String
    $bytesAfter = [IO.File]::ReadAllBytes($vdf)
    Check 'shortcuts.vdf untouched' (-not (Compare-Object $bytesBefore $bytesAfter)) 'the file changed'
    Check 'the desktop link is still made' (
        Test-Path (Join-Path $fakeDesktop 'Back to Console Mode.lnk')) 'missing'
    Check 'and it says which frontend and why' ($said -match 'playnite') $said

    & $script -ConsolizeExe $exe -Force -SteamAnyway | Out-Null
    $got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
    Check '-SteamAnyway writes the entries' ($got.AppName -contains 'Desktop Mode') "$($got.AppName -join ', ')"

    & $script -ConsolizeExe $exe -Force -Remove | Out-Null
    $got = Parse-Vdf ([IO.File]::ReadAllBytes($vdf))
    Check '-Remove is never gated' ($got.Count -eq 1 -and $got[0].AppName -eq 'Cyberpunk') "$($got.AppName -join ', ')"
} finally {
    Remove-Item env:FAKE_FRONTEND -ErrorAction SilentlyContinue
}

Write-Host ''
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
