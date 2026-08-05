#Requires -RunAsAdministrator
<#
Gaming bootstrap (F0). Installs everything a fresh Windows needs to run games
well. Interactive by default: shows the plan with recommended picks (*) and
lets the installer choose. Non-interactive: -Preset recommended | all | minimal.

Items:
  updates   Windows/security updates now (PSWindowsUpdate + Microsoft Update)
  gpu       The right vendor app for the detected GPU, which then installs and
            keeps the driver updated:
              NVIDIA -> NVIDIA App (fallback GeForce Experience)
              AMD    -> Adrenalin auto-detect
              Intel  -> Driver & Support Assistant
  vcredist  Visual C++ 2015-2022 redistributables x64 + x86 (most games)
  directx   DirectX End-User Runtime (legacy d3dx9/xaudio for older titles)
  steam     Steam
  playnite  Playnite (only if you plan the Playnite frontend)

Written for Windows PowerShell 5.1 (a fresh install has no pwsh 7).
Note: on IoT LTSC winget/App Installer may be missing; the script tells you
where to get it (https://aka.ms/getwinget) instead of guessing.
#>
param(
    [ValidateSet('recommended', 'all', 'minimal')]
    [string]$Preset
)
$ErrorActionPreference = 'Stop'

function Test-Winget {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Install-FirstAvailable {
    param([string[]]$Ids, [string]$Label)
    Write-Host ">> $Label..." -ForegroundColor Cyan
    foreach ($id in $Ids) {
        winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { return }
        Write-Warning "$Label ($id): winget exited with $LASTEXITCODE, trying next candidate (or it is already installed)."
    }
}

$gpus = (Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join '; '
$gpuVendor = $null
if ($gpus -match 'NVIDIA') { $gpuVendor = 'NVIDIA' }
elseif ($gpus -match 'AMD|Radeon') { $gpuVendor = 'AMD' }
elseif ($gpus -match 'Intel') { $gpuVendor = 'Intel' }
$gpuLabel = if ($gpuVendor) { $gpuVendor } else { 'none detected' }

$items = [ordered]@{
    updates  = @{ Label = 'Windows/security updates now';                Recommended = $true }
    gpu      = @{ Label = "GPU driver app (detected: $gpuLabel)";        Recommended = [bool]$gpuVendor }
    vcredist = @{ Label = 'Visual C++ 2015-2022 x64+x86';                Recommended = $true }
    directx  = @{ Label = 'DirectX End-User Runtime (older titles)';     Recommended = $true }
    steam    = @{ Label = 'Steam';                                       Recommended = $true }
    playnite = @{ Label = 'Playnite';                                    Recommended = $false }
}
$recommendedKeys = @($items.Keys | Where-Object { $items[$_].Recommended })

$selected = $null
switch ($Preset) {
    'all'         { $selected = @($items.Keys) }
    'minimal'     { $selected = @('vcredist', 'steam') }
    'recommended' { $selected = $recommendedKeys }
}

if (-not $selected) {
    Write-Host "GPU(s) found: $gpus"
    Write-Host ''
    Write-Host 'What should be installed? [Enter/R] = recommended (*), "all", or a comma list of keys:'
    foreach ($k in $items.Keys) {
        $mark = if ($items[$k].Recommended) { '*' } else { ' ' }
        Write-Host ("  [{0,-8}] {1} {2}" -f $k, $mark, $items[$k].Label)
    }
    $answer = Read-Host 'Choice'
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[rR]$') { $selected = $recommendedKeys }
    elseif ($answer -match '^(all|a)$') { $selected = @($items.Keys) }
    else { $selected = @($answer -split '[,\s]+' | Where-Object { $items.Contains($_) }) }
}

if (-not $selected -or $selected.Count -eq 0) { Write-Host 'Nothing selected, bye.'; return }
Write-Host ''
Write-Host ("Installing: " + ($selected -join ', ')) -ForegroundColor Green

$needsWinget = @($selected | Where-Object { $_ -ne 'updates' }).Count -gt 0
if ($needsWinget -and -not (Test-Winget)) {
    throw 'winget not found. On IoT LTSC install "App Installer" first: https://aka.ms/getwinget, then re-run.'
}

foreach ($key in $selected) {
    switch ($key) {
        'vcredist' {
            Install-FirstAvailable @('Microsoft.VCRedist.2015+.x64') 'Visual C++ x64'
            Install-FirstAvailable @('Microsoft.VCRedist.2015+.x86') 'Visual C++ x86'
        }
        'directx'  { Install-FirstAvailable @('Microsoft.DirectX') 'DirectX End-User Runtime' }
        'steam'    { Install-FirstAvailable @('Valve.Steam') 'Steam' }
        'playnite' { Install-FirstAvailable @('Playnite.Playnite') 'Playnite' }
        'gpu' {
            switch ($gpuVendor) {
                'NVIDIA' { Install-FirstAvailable @('Nvidia.App', 'Nvidia.GeForceExperience') 'NVIDIA App' }
                'AMD'    { Install-FirstAvailable @('AMD.AutoDetect') 'AMD Adrenalin auto-detect'
                           Write-Host 'If winget has no AMD package, grab it at https://www.amd.com/en/support' }
                'Intel'  { Install-FirstAvailable @('Intel.IntelDriverAndSupportAssistant') 'Intel Driver & Support Assistant' }
                default  { Write-Warning 'No supported GPU detected, skipping driver step.' }
            }
        }
        'updates' {
            Write-Host '>> Windows updates (PSWindowsUpdate)...' -ForegroundColor Cyan
            if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
                Install-Module PSWindowsUpdate -Force -Scope AllUsers
            }
            Import-Module PSWindowsUpdate
            try { Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
            Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot
            Write-Host 'Updates done (a reboot may be pending).'
        }
    }
}

Write-Host ''
Write-Host 'Bootstrap finished. Suggested order from here:'
Write-Host '  .\quiet-machine.ps1  ->  .\set-autologon.ps1 -UserName gamer  ->  .\install.ps1  ->  .\enable-shell-launcher.ps1 -UserName gamer'
Write-Host '  (and inside the gamer session, once: .\quiet-user.ps1)'
