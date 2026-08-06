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
$root = Join-Path $env:TEMP 'consolize-vdf-test'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
$fakeSteam = Join-Path $root 'Steam'
New-Item -ItemType Directory -Force -Path (Join-Path $fakeSteam 'userdata\7777777\config') | Out-Null
Set-Content (Join-Path $fakeSteam 'steam.exe') 'stub'
$exe = Join-Path $root 'consolize.exe'
New-Item -ItemType Directory -Force -Path $root | Out-Null
Set-Content $exe 'stub'

# real script, with only the Steam-discovery swapped for the fake tree
$src = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'setup\add-console-shortcuts.ps1') -Raw
$patched = $src -replace '(?s)function Get-SteamPath \{.*?\n\}', "function Get-SteamPath { return `$env:FAKE_STEAM }"
if ($patched -eq $src) { throw 'patch of Get-SteamPath did not apply' }
# never touch the Steam running on this machine
$before = $patched
$patched = $patched -replace '\$steamProc = Get-Process steam[^\r\n]*', '$steamProc = $null'
if ($patched -eq $before) { throw 'patch of the Steam process check did not apply' }
$script = Join-Path $root 'under-test.ps1'
Set-Content $script $patched
$env:FAKE_STEAM = $fakeSteam
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
    return $out
}

function Build-SteamFile {
    param([string[]]$Names, [int[]]$Indexes)
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $w.Write([byte]0); $w.Write([Text.Encoding]::UTF8.GetBytes('shortcuts')); $w.Write([byte]0)
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $key = if ($Indexes) { "$($Indexes[$i])" } else { "$i" }
        $w.Write([byte]0); $w.Write([Text.Encoding]::UTF8.GetBytes($key)); $w.Write([byte]0)
        $w.Write([byte]2); $w.Write([Text.Encoding]::UTF8.GetBytes('appid')); $w.Write([byte]0); $w.Write([int]-1234)
        $w.Write([byte]1); $w.Write([Text.Encoding]::UTF8.GetBytes('AppName')); $w.Write([byte]0)
        $w.Write([Text.Encoding]::UTF8.GetBytes($Names[$i])); $w.Write([byte]0)
        $w.Write([byte]1); $w.Write([Text.Encoding]::UTF8.GetBytes('Exe')); $w.Write([byte]0)
        $w.Write([Text.Encoding]::UTF8.GetBytes('"C:\g\g.exe"')); $w.Write([byte]0)
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

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
