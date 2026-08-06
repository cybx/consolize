#Requires -RunAsAdministrator
<#
Empties Windows startup (F2). A console boots into the game, not into six
updaters, a cloud sync client and three tray icons fighting for the first
seconds of every session.

Covers every place Windows actually starts things from:
  - Run / RunOnce, machine and user, 64 and 32 bit
  - the Startup folders, user and all-users
  - scheduled tasks triggered at logon or boot (third-party only; anything
    under \Microsoft\ is left alone, that is Windows itself)

Everything is backed up first and fully reversible.

  .\clean-startup.ps1 -List             # just show what starts with Windows
  .\clean-startup.ps1                   # pick what to remove, item by item
  .\clean-startup.ps1 -All              # remove everything found, no prompts
  .\clean-startup.ps1 -Keep 'Synergy'   # ...except entries matching a pattern
  .\clean-startup.ps1 -Restore          # put it all back

Steam is a special case: consolize launches it as the shell, so a leftover
Steam autostart entry means two Steams racing at logon. It is always removed.
#>
param(
    [switch]$List,
    [switch]$All,
    [string[]]$Keep,
    [switch]$Restore,
    # HKCU and the personal Startup folder always resolve to the user RUNNING
    # this script. During provisioning that is the administrator, not the
    # console account, so sweeping them would empty the wrong person's startup.
    [switch]$MachineOnly
)
$ErrorActionPreference = 'Stop'

$backupPath = 'C:\ProgramData\consolize\startup-backup.json'

$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
if (-not $MachineOnly) {
    $runKeys += 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $runKeys += 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
}

function Get-StartupItems {
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($key in $runKeys) {
        if (-not (Test-Path $key)) { continue }
        $props = Get-ItemProperty $key
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $items.Add([pscustomobject]@{
                Type = 'Registry'; Location = $key; Name = $p.Name; Value = [string]$p.Value
            })
        }
    }

    $folders = @([Environment]::GetFolderPath('CommonStartup'))
    if (-not $MachineOnly) { $folders += [Environment]::GetFolderPath('Startup') }
    foreach ($folder in $folders) {
        if (-not $folder -or -not (Test-Path $folder)) { continue }
        foreach ($f in Get-ChildItem $folder -File -ErrorAction SilentlyContinue) {
            if ($f.Name -eq 'desktop.ini') { continue }
            $items.Add([pscustomobject]@{
                Type = 'Shortcut'; Location = $folder; Name = $f.Name; Value = $f.FullName
            })
        }
    }

    foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }   # Windows' own plumbing
        if ($t.State -eq 'Disabled') { continue }
        # A logon task is user-facing even when its definition is stored
        # machine-wide. During phase 1, -MachineOnly must not disable the
        # administrator's VPN/password-manager/updater tasks. The console
        # account's HKCU startup is cleaned later in its own session.
        $triggerTypes = if ($MachineOnly) { @('MSFT_TaskBootTrigger') }
                        else { @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger') }
        $trigger = $t.Triggers | Where-Object { $_.CimClass.CimClassName -in $triggerTypes }
        if (-not $trigger) { continue }
        $items.Add([pscustomobject]@{
            Type = 'ScheduledTask'; Location = $t.TaskPath; Name = $t.TaskName
            Value = ($t.Actions | ForEach-Object { $_.Execute }) -join '; '
        })
    }

    return $items
}

# ---------------------------------------------------------------- restore ---

if ($Restore) {
    if (-not (Test-Path $backupPath)) { throw "No backup found at $backupPath" }
    $backup = Get-Content $backupPath -Raw | ConvertFrom-Json
    Write-Host "Restoring $($backup.Count) startup entries..."

    foreach ($item in $backup) {
        try {
            switch ($item.Type) {
                'Registry' {
                    if (-not (Test-Path $item.Location)) { New-Item -Path $item.Location -Force | Out-Null }
                    New-ItemProperty -Path $item.Location -Name $item.Name -Value $item.Value -PropertyType String -Force | Out-Null
                }
                'Shortcut' {
                    $stash = Join-Path (Split-Path $backupPath) ('startup-files\' + $item.Name)
                    if (Test-Path $stash) { Move-Item $stash (Join-Path $item.Location $item.Name) -Force }
                }
                'ScheduledTask' {
                    Enable-ScheduledTask -TaskPath $item.Location -TaskName $item.Name -ErrorAction Stop | Out-Null
                }
            }
            Write-Host "  restored: $($item.Name)"
        } catch {
            Write-Warning "  $($item.Name): $($_.Exception.Message)"
        }
    }
    Write-Host 'Done. Reboot to see them back.'
    return
}

# ------------------------------------------------------------- inventory ---

$items = Get-StartupItems
if (-not $items -or $items.Count -eq 0) {
    Write-Host 'Nothing starts with Windows here. Already console-clean.'
    return
}

Write-Host ''
if ($MachineOnly) {
    Write-Host 'Scope: machine-wide entries only (all users).' -ForegroundColor DarkGray
} else {
    Write-Host "Scope: machine-wide plus the startup of the account running this ($env:USERNAME)." -ForegroundColor DarkGray
}
Write-Host "Starting with Windows right now ($($items.Count) entries):" -ForegroundColor Cyan
$i = 0
foreach ($item in $items) {
    $i++
    $val = if ($item.Value.Length -gt 70) { $item.Value.Substring(0, 67) + '...' } else { $item.Value }
    Write-Host ("  {0,2}. [{1,-13}] {2}" -f $i, $item.Type, $item.Name)
    Write-Host ("      {0}" -f $val) -ForegroundColor DarkGray
}

if ($List) { return }

# ---------------------------------------------------------------- select ---

$toRemove = New-Object System.Collections.Generic.List[object]

foreach ($item in $items) {
    # Steam must never autostart: consolize is what launches it
    if ($item.Name -match 'steam' -or $item.Value -match 'steam\.exe') {
        $toRemove.Add($item)
        continue
    }
    if ($Keep -and ($Keep | Where-Object { $item.Name -like "*$_*" -or $item.Value -like "*$_*" })) {
        Write-Host "keeping (matched -Keep): $($item.Name)"
        continue
    }
    if ($All) { $toRemove.Add($item); continue }

    $answer = Read-Host "Remove '$($item.Name)'? [Y/n]"
    if ($answer -notmatch '^[nN]') { $toRemove.Add($item) }
}

if ($toRemove.Count -eq 0) { Write-Host 'Nothing selected, nothing changed.'; return }

# ----------------------------------------------------------------- apply ---

New-Item -ItemType Directory -Force -Path (Split-Path $backupPath) | Out-Null
$stashDir = Join-Path (Split-Path $backupPath) 'startup-files'
New-Item -ItemType Directory -Force -Path $stashDir | Out-Null

# Merge with any previous backup so a second run does not lose the first.
# Deduplicated by hand rather than with Group-Object: in Windows PowerShell 5.1
# the shape "@(array) + @(List[object]) | Group-Object a,b,c" throws "Argument
# types do not match", while either collection alone groups fine.
# No @() around ConvertFrom-Json: in Windows PowerShell 5.1 it emits a JSON
# array as ONE object, so wrapping it produces a nested array, the dedup key
# becomes the joined values of every entry at once, and a second run duplicates
# everything it was supposed to merge. foreach handles an array, a single
# object and $null correctly on its own.
$existing = $null
if (Test-Path $backupPath) {
    try { $existing = Get-Content $backupPath -Raw | ConvertFrom-Json } catch { $existing = $null }
}

$merged = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($item in $existing) {
    if (-not $item) { continue }
    $key = "$($item.Type)|$($item.Location)|$($item.Name)"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $merged.Add($item)
}
foreach ($item in $toRemove) {
    $key = "$($item.Type)|$($item.Location)|$($item.Name)"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $merged.Add($item)
}
$merged | ConvertTo-Json -Depth 4 | Set-Content $backupPath -Encoding UTF8
Write-Host ''
Write-Host "Backup written to $backupPath"

foreach ($item in $toRemove) {
    try {
        switch ($item.Type) {
            'Registry'      { Remove-ItemProperty -Path $item.Location -Name $item.Name -Force }
            'Shortcut'      { Move-Item $item.Value (Join-Path $stashDir $item.Name) -Force }
            'ScheduledTask' { Disable-ScheduledTask -TaskPath $item.Location -TaskName $item.Name -ErrorAction Stop | Out-Null }
        }
        Write-Host "  removed: $($item.Name)"
    } catch {
        Write-Warning "  $($item.Name): $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host "$($toRemove.Count) entries removed. Undo anytime with: .\clean-startup.ps1 -Restore" -ForegroundColor Green
