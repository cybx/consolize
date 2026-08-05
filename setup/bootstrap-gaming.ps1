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
  defender  Defender: tune it (exclusions + idle-only scans) or disable it
            entirely, asked at run time. -Preset all disables it; any other
            preset only tunes. See tune-defender.ps1.

Written for Windows PowerShell 5.1 (a fresh install has no pwsh 7).
winget is bootstrapped automatically when missing (IoT LTSC ships without
it): first re-register the provisioned package if present, else the official
Repair-WinGetPackageManager cmdlet, else direct msixbundle download.
#>
param(
    [ValidateSet('recommended', 'all', 'minimal')]
    [string]$Preset
)
$ErrorActionPreference = 'Stop'

function Test-Winget {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Ensure-Winget {
    if (Test-Winget) { return }
    Write-Host '>> winget not found, bootstrapping it...' -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Route 1: App Installer is provisioned but not registered for this user
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
    } catch { }
    if (Test-Winget) { Write-Host 'winget registered from the provisioned package.'; return }

    # Route 2: official repair cmdlet (downloads latest winget + dependencies)
    try {
        if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
            Install-Module Microsoft.WinGet.Client -Force -Scope AllUsers
        }
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager -AllUsers -Latest -Force
    } catch {
        Write-Warning "WinGet module route failed ($($_.Exception.Message)), trying direct download..."

        # Route 3: msixbundle + dependencies straight from Microsoft.
        # If Add-AppxPackage ever complains about a newer dependency, bump the
        # Microsoft.UI.Xaml release URL below.
        $tmp = Join-Path $env:TEMP 'consolize-winget'
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            $vclibs = Join-Path $tmp 'vclibs.appx'
            $xaml = Join-Path $tmp 'uixaml.appx'
            $bundle = Join-Path $tmp 'winget.msixbundle'
            Invoke-WebRequest 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -OutFile $vclibs -UseBasicParsing
            Invoke-WebRequest 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx' -OutFile $xaml -UseBasicParsing
            Invoke-WebRequest 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing
            Add-AppxPackage -Path $bundle -DependencyPath $vclibs, $xaml
        } finally {
            $ProgressPreference = $oldProgress
        }
    }

    if (-not (Test-Winget)) {
        # freshly registered store apps sometimes need the WindowsApps shim path
        $shim = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path $shim) { Set-Alias -Name winget -Value $shim -Scope Script }
    }
    if (-not (Test-Winget)) {
        throw 'Could not install winget automatically. Install "App Installer" from https://aka.ms/getwinget and re-run.'
    }
    Write-Host 'winget ready.'
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
    defender = @{ Label = 'Defender: tune (default) or disable entirely, asked below'; Recommended = $true }
}
$recommendedKeys = @($items.Keys | Where-Object { $items[$_].Recommended })

$selected = $null
switch ($Preset) {
    'all'         { $selected = @($items.Keys) }
    'minimal'     { $selected = @('vcredist', 'steam', 'defender') }
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

# order matters: Defender exclusions need the game folders to already exist
$order = @('updates', 'gpu', 'vcredist', 'directx', 'steam', 'playnite', 'defender')
$selected = $order | Where-Object { $selected -contains $_ }
Write-Host ''
Write-Host ("Installing: " + ($selected -join ', ')) -ForegroundColor Green

$needsWinget = @($selected | Where-Object { $_ -ne 'updates' }).Count -gt 0
if ($needsWinget) { Ensure-Winget }

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
        'defender' {
            # runs last on purpose: exclusions need the game folders to exist
            $tuner = Join-Path $PSScriptRoot 'tune-defender.ps1'
            if ($Preset -eq 'all') {
                & $tuner -Disable
            } elseif ($Preset) {
                & $tuner
            } else {
                Write-Host ''
                Write-Host 'Defender: [T] tune it (keeps you protected, recommended) or [D] disable it entirely?'
                $d = Read-Host 'T/D'
                if ($d -match '^[dD]') { & $tuner -Disable } else { & $tuner }
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
