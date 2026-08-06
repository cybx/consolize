#Requires -RunAsAdministrator
<#
Gaming bootstrap (F0). Takes a freshly installed Windows and leaves it ready to
play. Interactive by default: shows the plan with recommended picks (*) and lets
the installer choose. Non-interactive: -Preset recommended | all | minimal.

Items:
  updates    Windows updates now. Asks whether to install everything or only
             security and critical fixes. On IoT LTSC "everything" is the usual
             answer: it only ships quality updates anyway, no feature updates.
  gpu        The vendor app for the detected GPU, which then installs and keeps
             the driver updated:
               NVIDIA -> NVIDIA App (fallback GeForce Experience)
               AMD    -> Adrenalin auto-detect
               Intel  -> Driver & Support Assistant
  runtimes   Everything games link against that Windows does not ship:
               Visual C++ 2005, 2008, 2010, 2012, 2013 and 2015-2022, x64+x86
               DirectX End-User Runtime (d3dx9/10/11, XAudio2, XInput 1.3)
               .NET Framework 3.5 (old launchers) and .NET Desktop Runtime 8
               XNA Framework and OpenAL (older indies)
             Note: DirectX 11 and 12 themselves are part of Windows and come
             from Windows Update. There is no separate DX11/DX12 installer;
             what games actually miss are the helper libraries above.
  frontends  Steam, Playnite and/or Hydra, and which one the console boots into.
             Installed first on purpose: Steam then updates itself in the
             background while everything below is still downloading.
  media      VLC and mpv. Games ship their own video decoders, so codecs barely
             matter for playing; they matter when the console doubles as the
             living room media box. Windows has no HEVC or AV1 decoder out of
             the box and LTSC has no Store to buy the extensions from, so the
             fix is players that carry their own decoders. VLC plays everything
             without touching system codecs, which is also why codec packs
             (K-Lite and friends) are not worth their side effects here.
  tools      Git and 7-Zip
  steamidra  Latest SteaMidra portable build, also added to Steam
  torrent    qBittorrent plus a torrent folder layout
  defender   Defender: tune it or disable it entirely, asked at run time

Written for Windows PowerShell 5.1 (a fresh install has no pwsh 7).
winget is bootstrapped automatically when missing (IoT LTSC ships without it):
first re-register the provisioned package if present, else the official
Repair-WinGetPackageManager cmdlet, else direct msixbundle download.
#>
param(
    [ValidateSet('recommended', 'all', 'minimal')] [string]$Preset,
    [ValidateSet('all', 'security')] [string]$UpdateScope,
    [string]$ForUser,
    # Driven by setup-console.ps1, which already collected the answers:
    [string[]]$Items,
    [switch]$NonInteractive,
    [ValidateSet('steam', 'playnite', 'hydra', 'all')] [string[]]$Launchers,
    [ValidateSet('steam', 'playnite', 'hydra')] [string]$BootInto,
    # NetFx3 pulls ~250 MB from Windows Update and only matters to older
    # launchers, so it is the one runtime worth being able to leave out.
    [switch]$SkipNetFx3
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

# Every package this project installs comes from the community winget repo, so
# pin the source: the msstore source has an extra agreement (it sends the
# machine's 2 letter region) that --accept-source-agreements does not always
# cover, and the prompt stops an otherwise automatic install dead.
function Initialize-Winget {
    if ($script:WingetReady) { return }
    & winget list --source winget --accept-source-agreements *>$null
    $help = (& winget install --help 2>&1) -join ' '
    $script:WingetInteractiveFlag = if ($help -match 'disable-interactivity') { @('--disable-interactivity') } else { @() }
    $script:WingetReady = $true
}

function Install-FirstAvailable {
    param([string[]]$Ids, [string]$Label)
    Initialize-Winget
    Write-Host ">> $Label..." -ForegroundColor Cyan
    $common = @('--source', 'winget', '-e', '--silent',
                '--accept-package-agreements', '--accept-source-agreements') + $script:WingetInteractiveFlag
    foreach ($id in $Ids) {
        winget install --id $id @common
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

# NOT named $items: PowerShell variable names are case insensitive, so a local
# $items would BE the [string[]]$Items parameter, and assigning a dictionary to
# it silently coerces the whole thing into a one element string array.
$catalog = [ordered]@{
    updates   = @{ Label = 'Windows updates (asks: everything or security only)'; Recommended = $true }
    gpu       = @{ Label = "GPU driver app (detected: $gpuLabel)";                 Recommended = [bool]$gpuVendor }
    runtimes  = @{ Label = 'Game runtimes (VC++ 2005-2022, DirectX, .NET, XNA, OpenAL)'; Recommended = $true }
    frontends = @{ Label = 'Game launchers: Steam / Playnite / Hydra';             Recommended = $true }
    java      = @{ Label = 'Java (only for third-party Minecraft launchers and servers)'; Recommended = $false }
    media     = @{ Label = 'VLC and mpv (play anything on the TV, no codec pack)'; Recommended = $true }
    youtube   = @{ Label = 'YouTube on the TV, gamepad driven (VacuumTube)';       Recommended = $true }
    tools     = @{ Label = 'Git and 7-Zip';                                        Recommended = $true }
    steamidra = @{ Label = 'SteaMidra (latest release, added as a non-Steam app)'; Recommended = $true }
    torrent   = @{ Label = 'qBittorrent plus a torrent folder layout';             Recommended = $false }
    defender  = @{ Label = 'Defender: tune (default) or disable entirely';         Recommended = $true }
}
$recommendedKeys = @($catalog.Keys | Where-Object { $catalog[$_].Recommended })

$selected = $null
if ($Items) { $selected = @($Items | Where-Object { $catalog.Contains($_) }) }
switch ($Preset) {
    'all'         { $selected = @($catalog.Keys) }
    'minimal'     { $selected = @('runtimes', 'frontends', 'defender') }
    'recommended' { $selected = $recommendedKeys }
}

if (-not $selected -and $NonInteractive) { $selected = $recommendedKeys }

if (-not $selected) {
    Write-Host "GPU(s) found: $gpus"
    Write-Host ''
    Write-Host 'What should be installed? [Enter/R] = recommended (*), "all", or a comma list of keys:'
    foreach ($k in $catalog.Keys) {
        $mark = if ($catalog[$k].Recommended) { '*' } else { ' ' }
        Write-Host ("  [{0,-9}] {1} {2}" -f $k, $mark, $catalog[$k].Label)
    }
    $answer = Read-Host 'Choice'
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[rR]$') { $selected = $recommendedKeys }
    elseif ($answer -match '^(all|a)$') { $selected = @($catalog.Keys) }
    else { $selected = @($answer -split '[,\s]+' | Where-Object { $catalog.Contains($_) }) }
}

if (-not $selected -or $selected.Count -eq 0) { Write-Host 'Nothing selected, bye.'; return }

# Order matters, at both ends.
#
# frontends first: installing Steam takes seconds, and the client then spends
# minutes updating itself on first run. Starting that now means it downloads
# while Windows updates, drivers and runtimes install, rather than stalling the
# console account's session later, with someone watching a still screen.
#
# defender last: its exclusions cover the game folders, which do not exist until
# the installs above have run.
$order = @('frontends', 'updates', 'gpu', 'runtimes', 'java', 'media', 'youtube', 'tools', 'steamidra', 'torrent', 'defender')
$selected = $order | Where-Object { $selected -contains $_ }

Write-Host ''
Write-Host ("Installing: " + ($selected -join ', ')) -ForegroundColor Green

$needsWinget = @($selected | Where-Object { $_ -ne 'updates' }).Count -gt 0
if ($needsWinget) { Ensure-Winget }

foreach ($key in $selected) {
    switch ($key) {
        'runtimes' {
            # Every VC++ generation, because a 2011 game links against 2010 and
            # nothing newer satisfies it. x86 matters as much as x64: plenty of
            # shipped games are still 32 bit.
            foreach ($year in @('2005', '2008', '2010', '2012', '2013', '2015+')) {
                Install-FirstAvailable @("Microsoft.VCRedist.$year.x64") "Visual C++ $year x64"
                Install-FirstAvailable @("Microsoft.VCRedist.$year.x86") "Visual C++ $year x86"
            }

            # d3dx9/10/11, XAudio2, XInput 1.3, D3DCompiler_43. DirectX 11 and 12
            # themselves ship with Windows; this is the legacy helper layer only.
            Install-FirstAvailable @('Microsoft.DirectX') 'DirectX End-User Runtime'

            Install-FirstAvailable @('Microsoft.DotNet.DesktopRuntime.8') '.NET Desktop Runtime 8'
            Install-FirstAvailable @('Microsoft.XNARedist') 'XNA Framework Redistributable'
            Install-FirstAvailable @('CreativeTechnology.OpenAL') 'OpenAL'

            Write-Host '>> .NET Framework 3.5 (old launchers and tools)...' -ForegroundColor Cyan
            $netfx = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction SilentlyContinue
            if ($SkipNetFx3) {
                Write-Host '   skipped (-SkipNetFx3).'
            } elseif ($netfx -and $netfx.State -ne 'Enabled') {
                # Roughly 250 MB straight from Windows Update, and it prints
                # nothing while it works. Say so, rather than looking hung.
                Write-Host '   this one downloads ~250 MB from Windows Update and prints nothing'
                Write-Host '   while it works: 5 to 15 minutes is normal, longer on a VM.'
                Write-Host '   Watch it from another window with:'
                Write-Host '     Get-Content C:\Windows\Logs\DISM\dism.log -Tail 5 -Wait' -ForegroundColor DarkGray
                Write-Host '   (skip it next time with: .\bootstrap-gaming.ps1 -SkipNetFx3)' -ForegroundColor DarkGray
                $started = Get-Date
                try {
                    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop | Out-Null
                    Write-Host "   enabled in $([int]((Get-Date) - $started).TotalMinutes) min."
                } catch {
                    Write-Warning "   could not enable NetFx3 ($($_.Exception.Message))."
                    Write-Warning '   Not fatal: it only matters for older launchers. Retry later with'
                    Write-Warning '   Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All'
                }
            } else {
                Write-Host '   already enabled.'
            }
        }

        'tools' {
            Install-FirstAvailable @('Git.Git') 'Git'
            Install-FirstAvailable @('7zip.7zip') '7-Zip'
        }

        'steamidra' {
            $installer = Join-Path $PSScriptRoot 'install-steamidra.ps1'
            if (Test-Path $installer) {
                try { & $installer } catch { Write-Warning "SteaMidra: $($_.Exception.Message)" }
            } else {
                Write-Warning 'install-steamidra.ps1 is not here, skipping.'
            }
        }

        'java' {
            # Off by default because the official Minecraft launcher has bundled
            # its own runtime since 2021 and picks the version each release
            # needs. System Java is for servers, third-party launchers (Prism,
            # MultiMC) and some mod loaders.
            Install-FirstAvailable @('Microsoft.OpenJDK.21', 'EclipseAdoptium.Temurin.21.JDK') 'Java (OpenJDK 21)'
        }

        'youtube' {
            # Its own script because this one is not a winget id: the TV
            # interface is blocked to browsers, so it comes from a GitHub
            # release, and the reasoning is long enough to want its own file.
            $youtube = Join-Path $PSScriptRoot 'install-youtube.ps1'
            if (Test-Path $youtube) {
                try { & $youtube } catch { Write-Warning "YouTube: $($_.Exception.Message)" }
            } else {
                Write-Warning 'install-youtube.ps1 is not here, skipping.'
            }
        }

        'media' {
            # Players that bundle their own decoders, so HEVC and AV1 play even
            # though Windows ships neither and LTSC has no Store to get them from.
            Install-FirstAvailable @('VideoLAN.VLC') 'VLC'
            Install-FirstAvailable @('shinchiro.mpv') 'mpv'

            $hevc = Get-AppxPackage -AllUsers -Name 'Microsoft.HEVCVideoExtension*' -ErrorAction SilentlyContinue
            if (-not $hevc) {
                Write-Host '   note: no system HEVC decoder (normal on LTSC). VLC and mpv do not need it;' -ForegroundColor DarkGray
                Write-Host '   only the built-in Media Player and Edge would.' -ForegroundColor DarkGray
            }
        }

        'frontends' {
            $splat = @{}
            if ($Launchers) { $splat['Install'] = $Launchers }
            elseif ($Preset -eq 'all') { $splat['Install'] = 'all' }
            # any other preset, including 'recommended': without this the picker
            # was skipped (BootInto was set) and nothing was installed at all,
            # while the run still reported success
            elseif ($Preset) { $splat['Install'] = 'steam' }
            if ($BootInto) { $splat['BootInto'] = $BootInto }
            elseif ($Preset) { $splat['BootInto'] = 'steam' }
            # during provisioning the console account may have no profile yet
            if ($NonInteractive) { $splat['Machine'] = $true }
            if ($ForUser) { $splat['ForUser'] = $ForUser }
            & (Join-Path $PSScriptRoot 'install-frontend.ps1') @splat

            # A freshly installed Steam downloads a sizeable self-update the
            # first time it runs. Start it to the tray now so that download
            # overlaps with the installs still to come, instead of stalling the
            # console account's session later, which is when someone is watching.
            #
            # Elevated is fine here: Steam's installer grants BUILTIN\Users
            # FullControl on its directory, inherited by everything created in
            # it, precisely so ordinary accounts can update the client. Checked,
            # rather than assumed.
            $steamExe = @(
                (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
                'C:\Program Files (x86)\Steam'
            ) | Where-Object { $_ } | ForEach-Object { Join-Path ($_ -replace '/', '\') 'steam.exe' } |
                Where-Object { Test-Path $_ } | Select-Object -First 1

            if ($steamExe -and -not (Get-Process steam -ErrorAction SilentlyContinue)) {
                Write-Host '>> Warming Steam up (its first-run update downloads in the background)...' -ForegroundColor Cyan
                try { Start-Process $steamExe -ArgumentList '-silent' } catch { Write-Warning "  could not start it: $($_.Exception.Message)" }
            }
        }

        'torrent' {
            $splat = @{}
            if ($ForUser) { $splat['ForUser'] = $ForUser }
            & (Join-Path $PSScriptRoot 'install-torrent.ps1') @splat
        }

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
            $scope = $UpdateScope
            if (-not $scope) {
                if ($Preset -or $NonInteractive) {
                    $scope = 'all'
                } else {
                    Write-Host ''
                    Write-Host 'Windows updates: [A] everything or [S] security and critical only?'
                    Write-Host '  On IoT LTSC "everything" is usually right: this edition only ships'
                    Write-Host '  quality and security fixes, never feature updates.'
                    $u = Read-Host 'A/S (Enter for A)'
                    $scope = if ($u -match '^[sS]') { 'security' } else { 'all' }
                }
            }

            Write-Host ">> Windows updates ($scope)..." -ForegroundColor Cyan
            if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
                Install-Module PSWindowsUpdate -Force -Scope AllUsers
            }
            Import-Module PSWindowsUpdate
            try { Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }

            if ($scope -eq 'security') {
                Get-WindowsUpdate -MicrosoftUpdate -Category @('Security Updates', 'Critical Updates') -AcceptAll -Install -IgnoreReboot
            } else {
                Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot
            }
            Write-Host 'Updates done (a reboot may be pending).'
        }
    }
}

Write-Host ''
if ($selected -contains 'frontends') {
    Write-Host 'IMPORTANT before replacing the shell:' -ForegroundColor Yellow
    Write-Host '  Open Steam once and log in with "Remember me" ticked, then confirm Big'
    Write-Host '  Picture opens. Without a saved login, the first boot lands on the desktop'
    Write-Host '  login window with no Explorer behind it, which a controller cannot fill in.'
    Write-Host '  Shortcut: .\install-steam.ps1 -LaunchForLogin'
    Write-Host ''
}
Write-Host 'Bootstrap finished. Suggested order from here:'
Write-Host '  .\quiet-machine.ps1'
Write-Host '  .\power-console.ps1'
Write-Host '  .\clean-startup.ps1'
Write-Host '  .\set-autologon.ps1 -UserName gamer'
Write-Host '  .\preflight.ps1 -UserName gamer'
Write-Host '  .\enable-shell-launcher.ps1 -UserName gamer'
Write-Host '  (and inside the gamer session, once: .\quiet-user.ps1)'
