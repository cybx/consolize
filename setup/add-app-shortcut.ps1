<#
Puts any installed application in the Steam library, with cover art and in the
Consolize collection, reachable with a controller.

Steam can already do this: "Add a non-Steam game" in the library. What it needs
is a mouse and a file browser, and a machine that boots into Big Picture has
neither, so getting an app into the library means leaving the console to do it.
This is the same thing from one command.

The list lives in C:\ProgramData\Consolize\extra-shortcuts.json and is applied
by add-console-shortcuts.ps1, so it survives updates and is reapplied whenever
the entries are rewritten.

  .\add-app-shortcut.ps1 -Name 'RetroArch' -Exe 'C:\RetroArch\retroarch.exe'
  .\add-app-shortcut.ps1 -Name 'Moonlight' -Exe 'C:\Program Files\Moonlight\Moonlight.exe' -Arguments '--fullscreen'
  .\add-app-shortcut.ps1 -Name 'Kodi' -Exe '...' -Glyph E8B2   # a Segoe MDL2 code point
  .\add-app-shortcut.ps1 -List
  .\add-app-shortcut.ps1 -Name 'RetroArch' -Delete
#>
param(
    [string]$Name,
    [string]$Exe,
    [string]$Arguments,
    # A Segoe MDL2 Assets code point in hex, for the cover art. Optional: the
    # default is a generic application icon. Browse them at
    # https://learn.microsoft.com/windows/apps/design/style/segoe-ui-symbol-font
    [string]$Glyph,
    [switch]$Delete,
    [switch]$List,
    [switch]$NoApply
)
$ErrorActionPreference = 'Stop'

$stateDir = Join-Path $env:ProgramData 'Consolize'
$extrasFile = Join-Path $stateDir 'extra-shortcuts.json'

function Get-Extras {
    if (-not (Test-Path $extrasFile)) { return @() }
    try { return @(Get-Content $extrasFile -Raw | ConvertFrom-Json) }
    catch { Write-Warning "$extrasFile is not readable JSON, starting a new list."; return @() }
}

function Save-Extras {
    param($Items)
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    # An array of one would be written as a bare object by ConvertTo-Json, and
    # then reading it back gives an object where a list is expected.
    ,@($Items) | ConvertTo-Json -Depth 4 | Set-Content $extrasFile
}

$extras = Get-Extras

if ($List) {
    if (-not $extras.Count) { Write-Host 'No extra shortcuts yet.'; return }
    Write-Host ''
    foreach ($item in $extras) {
        $missing = if (Test-Path $item.exe) { '' } else { '   (the file is gone)' }
        Write-Host ("  {0,-24} {1}{2}" -f $item.name, $item.exe, $missing)
        if ($item.args) { Write-Host ("  {0,-24} args: {1}" -f '', $item.args) }
    }
    Write-Host ''
    Write-Host "Stored in $extrasFile"
    return
}

if (-not $Name) { throw 'Give it a -Name (or use -List).' }

if ($Delete) {
    $remaining = @($extras | Where-Object { $_.name -ne $Name })
    if ($remaining.Count -eq $extras.Count) { Write-Host "'$Name' was not in the list."; return }
    Save-Extras $remaining
    Write-Host "'$Name' removed from the list."
    Write-Host ''
    # Said plainly because it is surprising: the library entry does not go with
    # it. An entry that no longer matches anything this knows about cannot be
    # told apart from one the owner added by hand, and deleting somebody's
    # library entry on a guess is worse than leaving a stale one behind.
    Write-Host 'It is still in the Steam library. To take it out, remove every console' -ForegroundColor Yellow
    Write-Host 'entry and put them back:' -ForegroundColor Yellow
    Write-Host '  .\add-console-shortcuts.ps1 -Remove -Force' -ForegroundColor Yellow
    Write-Host '  .\add-console-shortcuts.ps1 -Force' -ForegroundColor Yellow
    return
}

if (-not $Exe) { throw 'Give it an -Exe (the program to launch).' }
$Exe = [IO.Path]::GetFullPath($Exe)
if (-not (Test-Path $Exe)) { throw "$Exe is not there. Install it first, then run this." }
if ($Glyph -and $Glyph -notmatch '^[0-9a-fA-F]{4}$') { throw "-Glyph is four hex digits, for example E8B2." }

$entry = [ordered]@{ name = $Name; exe = $Exe; args = $Arguments }
if ($Glyph) { $entry.glyph = $Glyph.ToUpper() }

$updated = @($extras | Where-Object { $_.name -ne $Name })
$replaced = $updated.Count -ne $extras.Count
$updated += [pscustomobject]$entry
Save-Extras $updated

Write-Host "$(if ($replaced) { 'Updated' } else { 'Added' }) '$Name' -> $Exe"

if ($NoApply) {
    Write-Host 'Not applied. Run add-console-shortcuts.ps1 -Force when you are ready.'
    return
}

Write-Host ''
& (Join-Path $PSScriptRoot 'add-console-shortcuts.ps1') -Force
