#Requires -RunAsAdministrator
<#
Installs the game launchers you want and picks which one consolize boots into.

  steam     Steam Big Picture. The controller-first default: full gamepad
            navigation, per-game controller layouts, in-home streaming.
  playnite  Playnite Fullscreen. Also fully controller navigable, and it
            aggregates Steam, Epic, GOG, emulators and more in one library.
  hydra     Hydra. Installs fine and can be launched from either frontend, but
            its UI is mouse-first, so it works better as a companion app than
            as the shell itself.

  .\install-frontend.ps1                      # ask what to install and what to boot into
  .\install-frontend.ps1 -Install all         # everything, no prompts
  .\install-frontend.ps1 -Install steam,hydra -BootInto steam
  .\install-frontend.ps1 -BootInto playnite -ForUser gamer   # only change the boot frontend
#>
param(
    [ValidateSet('steam', 'playnite', 'hydra', 'all')] [string[]]$Install,
    [ValidateSet('steam', 'playnite', 'hydra')] [string]$BootInto,
    [string]$ForUser
)
$ErrorActionPreference = 'Stop'

$catalog = [ordered]@{
    steam    = @{ Label = 'Steam (Big Picture)';        WingetId = 'Valve.Steam';          ControllerFirst = $true }
    playnite = @{ Label = 'Playnite (Fullscreen)';      WingetId = 'Playnite.Playnite';    ControllerFirst = $true }
    hydra    = @{ Label = 'Hydra';                      WingetId = 'HydraLauncher.Hydra';  ControllerFirst = $false }
}

function Get-ConfigPath {
    if ($ForUser) {
        $profileDir = (Get-CimInstance Win32_UserProfile |
            Where-Object { $_.LocalPath -like "*\$ForUser" } | Select-Object -First 1).LocalPath
        if (-not $profileDir) { $profileDir = Join-Path $env:SystemDrive "Users\$ForUser" }
        return Join-Path $profileDir 'AppData\Local\Consolize\config.json'
    }
    return Join-Path $env:LOCALAPPDATA 'Consolize\config.json'
}

function Install-Frontend {
    param([string]$Key)
    $item = $catalog[$Key]

    if ($Key -eq 'steam') {
        # Steam has its own script: CDN fallback when winget fails, signature
        # check, autostart removal and the saved-login verification.
        & (Join-Path $PSScriptRoot 'install-steam.ps1')
        return
    }

    Write-Host ">> $($item.Label)..." -ForegroundColor Cyan
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning "winget not available, skipping $($item.Label). Run bootstrap-gaming.ps1 first, it bootstraps winget."
        return
    }
    winget install --id $item.WingetId -e --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$($item.Label): winget exited with $LASTEXITCODE (it may already be installed)."
    }
}

# ------------------------------------------------------------------ choose ---

if (-not $Install -and -not $BootInto) {
    Write-Host ''
    Write-Host 'Which launchers should this console have?' -ForegroundColor Cyan
    foreach ($k in $catalog.Keys) {
        $note = if ($catalog[$k].ControllerFirst) { 'controller navigable' } else { 'mouse-first UI' }
        Write-Host ("  [{0,-8}] {1} ({2})" -f $k, $catalog[$k].Label, $note)
    }
    Write-Host '  [all     ] everything'
    $answer = Read-Host 'Choice (comma separated, Enter for steam)'
    if ([string]::IsNullOrWhiteSpace($answer)) { $Install = @('steam') }
    elseif ($answer -match '^\s*(all|a)\s*$') { $Install = @('all') }
    else { $Install = @($answer -split '[,\s]+' | Where-Object { $catalog.Contains($_) }) }
}

if ($Install -contains 'all') { $Install = @($catalog.Keys) }

foreach ($key in $Install) { Install-Frontend $key }

# --------------------------------------------------------------- boot into ---

if (-not $BootInto) {
    $candidates = @($Install | Where-Object { $catalog[$_].ControllerFirst })
    if ($candidates.Count -eq 1) {
        $BootInto = $candidates[0]
    } elseif ($candidates.Count -gt 1) {
        Write-Host ''
        Write-Host "Which one should the console boot into? ($($candidates -join ' / '))"
        $answer = Read-Host "Choice (Enter for $($candidates[0]))"
        $BootInto = if ([string]::IsNullOrWhiteSpace($answer)) { $candidates[0] }
                    elseif ($catalog.Contains($answer)) { $answer }
                    else { $candidates[0] }
    } elseif ($Install) {
        Write-Host ''
        Write-Warning @'
None of the launchers you installed is controller navigable, so booting straight
into one would strand a gamepad-only user. Install Steam or Playnite to be the
shell frontend, and launch the others from inside it.
'@
    }
}

if ($BootInto) {
    $configPath = Get-ConfigPath
    New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null

    $config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $config | Add-Member -NotePropertyName Frontend -NotePropertyValue $BootInto -Force
    $config | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8

    Write-Host ''
    Write-Host "Boot frontend set to '$BootInto' ($configPath)" -ForegroundColor Green
    if ($ForUser) { Write-Host "  (written into $ForUser's profile)" }
    else { Write-Host "  Note: this is the current user's config. Use -ForUser gamer to set it for the console account." }
}

Write-Host ''
Write-Host 'Tip: add the other launchers as non-Steam shortcuts (or Playnite entries) so'
Write-Host 'you can reach them from the couch without leaving the frontend.'
