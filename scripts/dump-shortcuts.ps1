<#
Prints what Steam actually has, for when the library disagrees with what this
project believes it wrote. Reads only, changes nothing, needs no admin.

  irm https://raw.githubusercontent.com/cybx/consolize/main/scripts/dump-shortcuts.ps1 | iex
#>
$ErrorActionPreference = 'Continue'

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

$steam = Get-SteamPath
Write-Host ''
Write-Host "Steam:        $steam"
Write-Host "running as:   $env:USERNAME"
Write-Host "steam.exe up: $([bool](Get-Process steam -ErrorAction SilentlyContinue))"
if (-not $steam) { Write-Warning 'Steam not found.'; return }

$userDirs = @(Get-ChildItem (Join-Path $steam 'userdata') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '0' })
Write-Host "profiles:     $($userDirs.Count) ($($userDirs.Name -join ', '))"

foreach ($userDir in $userDirs) {
    $vdf = Join-Path $userDir.FullName 'config\shortcuts.vdf'
    Write-Host ''
    Write-Host "=== $($userDir.Name) ===" -ForegroundColor Cyan
    if (-not (Test-Path $vdf)) { Write-Host '  no shortcuts.vdf'; continue }

    $b = [IO.File]::ReadAllBytes($vdf)
    Write-Host ("  {0} bytes, ends {1:X2} {2:X2}, written {3}" -f $b.Length,
        $b[$b.Length - 2], $b[$b.Length - 1], (Get-Item $vdf).LastWriteTime)

    $pos = 0; $depth = 1; $out = @(); $cur = $null; $inTags = $false
    try {
        while ($pos -lt $b.Length) {
            $type = $b[$pos]; $pos++
            if ($type -eq 8) {
                $depth--
                if ($depth -eq 3) { $inTags = $false }
                if ($depth -eq 2 -and $cur) { $out += , $cur; $cur = $null }
                if ($depth -eq 0 -and $pos -ne $b.Length) { throw "root closed at $pos of $($b.Length)" }
                continue
            }
            $s = $pos; while ($pos -lt $b.Length -and $b[$pos] -ne 0) { $pos++ }
            $key = [Text.Encoding]::UTF8.GetString($b, $s, $pos - $s); $pos++
            if ($type -eq 0) {
                if ($depth -eq 2) { $cur = [ordered]@{ Index = $key; Tags = @() } }
                if ($depth -eq 3 -and $key -eq 'tags') { $inTags = $true }
                $depth++
            } elseif ($type -eq 1) {
                $s = $pos; while ($pos -lt $b.Length -and $b[$pos] -ne 0) { $pos++ }
                $val = [Text.Encoding]::UTF8.GetString($b, $s, $pos - $s); $pos++
                if ($cur -and $inTags -and $depth -eq 4) { $cur.Tags += $val }
                elseif ($cur -and $depth -eq 3) { $cur[$key] = $val }
            } elseif ($type -eq 2) {
                if ($cur -and $depth -eq 3) { $cur[$key] = [BitConverter]::ToInt32($b, $pos) }
                $pos += 4
            } else { throw "unknown type 0x$('{0:X2}' -f $type) at $($pos - 1)" }
        }
        if ($depth -ne 0) { throw "$depth map(s) still open at EOF" }
    } catch {
        Write-Warning "  parse stopped: $($_.Exception.Message)"
    }

    Write-Host "  $($out.Count) entr$(if ($out.Count -eq 1) { 'y' } else { 'ies' })"
    $grid = Join-Path $userDir.FullName 'config\grid'
    foreach ($e in $out) {
        $id = if ($null -ne $e.appid) { [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.appid), 0) } else { $null }
        Write-Host ''
        Write-Host ("  [{0}] {1}" -f $e.Index, $e.AppName) -ForegroundColor Yellow
        Write-Host ("      name bytes  : {0}" -f (($e.AppName.ToCharArray() | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ' '))
        Write-Host ("      appid       : {0}  unsigned {1}" -f $e.appid, $id)
        Write-Host ("      Exe         : {0}" -f $e.Exe)
        Write-Host ("      exists      : {0}" -f (Test-Path ($e.Exe -replace '^"|"$', '')))
        Write-Host ("      icon        : {0}" -f $e.icon)
        Write-Host ("      icon exists : {0}" -f (Test-Path ($e.icon -replace '^"|"$', '')))
        Write-Host ("      Launch      : {0}" -f $e.LaunchOptions)
        Write-Host ("      tags        : {0}" -f ($e.Tags -join ', '))
        if ($id) {
            $have = @('p.png', '.png', '_hero.png', '_logo.png') |
                Where-Object { Test-Path (Join-Path $grid "$id$_") }
            Write-Host ("      artwork     : {0}" -f $(if ($have) { $have -join ' ' } else { 'none' }))
        }
    }

    if (Test-Path $grid) {
        $orphans = Get-ChildItem $grid -Filter '*.png' -ErrorAction SilentlyContinue
        Write-Host ''
        Write-Host "  grid folder: $($orphans.Count) file(s)"
    }
}
