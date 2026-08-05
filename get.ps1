<#
consolize one-line installer.

    irm https://raw.githubusercontent.com/cybx/consolize/main/get.ps1 | iex

Downloads consolize.exe (latest release) plus the setup scripts, installs them
to C:\Program Files\Consolize and C:\ProgramData\consolize\setup, and offers to
run the provisioning menu right away.

Options, when piping is not enough:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cybx/consolize/main/get.ps1))) -DownloadOnly
    & ([scriptblock]::Create((irm .../get.ps1))) -Ref v0.1.0
#>
param(
    [string]$Repo = 'cybx/consolize',
    [string]$Ref = 'main',
    [string]$InstallDir = 'C:\Program Files\Consolize',
    [string]$ScriptDir = 'C:\ProgramData\consolize\setup',
    [switch]$DownloadOnly,
    [switch]$NoElevate
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ''
Write-Host '  consolize installer' -ForegroundColor Cyan
Write-Host '  turns this PC into a couch gaming console'
Write-Host ''

# Everything past this point writes to Program Files, services, the registry and
# the shell, so elevate rather than failing halfway. Piped through iex there is
# no script file to re-launch, so the elevated session re-fetches this same
# script and replays the parameters, base64 encoded to dodge quoting entirely.
if (-not (Test-Admin) -and -not $DownloadOnly -and -not $NoElevate) {
    $selfUrl = "https://raw.githubusercontent.com/$Repo/$Ref/get.ps1"

    $replay = foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) {
            if ($p.Value.IsPresent) { "-$($p.Key)" }
        } else {
            "-$($p.Key) '$($p.Value -replace "'", "''")'"
        }
    }

    $inner = "& ([scriptblock]::Create((Invoke-RestMethod '$selfUrl'))) $($replay -join ' ')"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

    Write-Host 'Administrator rights are needed (Program Files, services, registry, shell).'
    Write-Host 'Approve the prompt: the installer continues in a new elevated window.'
    try {
        Start-Process powershell -Verb RunAs -ArgumentList `
            '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    } catch {
        Write-Warning 'Elevation was declined. Open PowerShell as administrator and run the one-liner again:'
        Write-Host "    irm $selfUrl | iex"
    }
    return
}

$tmp = Join-Path $env:TEMP ("consolize-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# --- setup scripts always come from the source tree (small, always available)
Write-Host "Downloading setup scripts ($Ref)..."
$srcZip = Join-Path $tmp 'src.zip'
Invoke-WebRequest "https://github.com/$Repo/archive/refs/heads/$Ref.zip" -OutFile $srcZip -UseBasicParsing -ErrorAction SilentlyContinue
if (-not (Test-Path $srcZip)) {
    # $Ref may be a tag rather than a branch
    Invoke-WebRequest "https://github.com/$Repo/archive/refs/tags/$Ref.zip" -OutFile $srcZip -UseBasicParsing
}
Expand-Archive $srcZip -DestinationPath $tmp -Force
$extracted = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'consolize-*' } | Select-Object -First 1
if (-not $extracted) { throw 'Could not find the extracted source folder.' }

# --- consolize.exe comes from the latest release; the source tree has no binary
Write-Host 'Looking for the latest consolize.exe release...'
$exeSource = $null
try {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -Headers @{ 'User-Agent' = 'consolize-installer' }
    $asset = $rel.assets | Where-Object { $_.name -eq 'consolize.exe' } | Select-Object -First 1
    if ($asset) {
        $exeSource = Join-Path $tmp 'consolize.exe'
        Write-Host "  $($rel.tag_name)"
        Invoke-WebRequest $asset.browser_download_url -OutFile $exeSource -UseBasicParsing
    }
} catch {
    Write-Warning "No published release found ($($_.Exception.Message))."
}

if (-not $exeSource) {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) {
        Write-Host 'Building consolize.exe from source instead...'
        & dotnet publish (Join-Path $extracted.FullName 'src\Consolize.SessionManager') -c Release -o (Join-Path $tmp 'publish')
        if ($LASTEXITCODE -eq 0) { $exeSource = Join-Path $tmp 'publish\consolize.exe' }
    }
}

if ($DownloadOnly) {
    Write-Host ''
    Write-Host "Downloaded to: $tmp"
    Write-Host ("  setup scripts : " + (Get-ChildItem (Join-Path $extracted.FullName 'setup') -Filter *.ps1).Count + ' files')
    Write-Host ("  consolize.exe : " + $(if ($exeSource) { $exeSource } else { 'not available' }))
    return
}

New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
Copy-Item (Join-Path $extracted.FullName 'setup\*.ps1') $ScriptDir -Force
Write-Host "Setup scripts installed to $ScriptDir"

# The boot splash: Windows' own logo is switched off, so this is what the
# machine shows on the way up.
$splashSource = Join-Path $extracted.FullName 'assets\splash.png'
if (Test-Path $splashSource) {
    $stateDir = Join-Path $env:ProgramData 'Consolize'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    Copy-Item $splashSource (Join-Path $stateDir 'splash.png') -Force
    Write-Host "Boot splash installed to $stateDir\splash.png"
}

if ($exeSource) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item $exeSource (Join-Path $InstallDir 'consolize.exe') -Force
    Write-Host "consolize.exe installed to $InstallDir"

    # make `consolize` work in any new shell
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$InstallDir", 'Machine')
        Write-Host "  added to PATH (new shells only)"
    }
} else {
    Write-Warning 'consolize.exe is not installed. Setup scripts still work; grab the binary later from'
    Write-Warning "https://github.com/$Repo/releases"
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host ''
Write-Host 'setup-console.ps1 runs the whole thing: apps, runtimes, quiet layer,'
Write-Host 'power, startup, performance, the console account and the shell. It asks'
Write-Host 'before each part, and every step is also runnable on its own from'
Write-Host "$ScriptDir."
Write-Host ''
$run = Read-Host 'Run the full console setup now? [Y/n]'
if ($run -notmatch '^[nN]') {
    & (Join-Path $ScriptDir 'setup-console.ps1')
} else {
    Write-Host ''
    Write-Host 'When you are ready:'
    Write-Host "    cd '$ScriptDir'"
    Write-Host '    .\setup-console.ps1'
}
