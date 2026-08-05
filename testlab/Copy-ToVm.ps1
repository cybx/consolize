#Requires -RunAsAdministrator
<#
Pushes a built consolize plus the setup scripts into the lab VM, so the guest
never needs the .NET SDK, git or even a network connection.

Uses Hyper-V Copy-VMFile over the Guest Service Interface (the VM must be
running and past OOBE, with a user logged in at least once).

    .\Copy-ToVm.ps1                       # builds, then copies to C:\consolize
    .\Copy-ToVm.ps1 -SkipBuild            # copies whatever is already in out/publish
#>
param(
    [string]$VmName = 'consolize-lab',
    [string]$GuestPath = 'C:\consolize',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$publishDir = Join-Path $repoRoot 'out\publish'
$exe = Join-Path $publishDir 'consolize.exe'

if (-not $SkipBuild) {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet -and (Test-Path "$env:USERPROFILE\.dotnet\dotnet.exe")) {
        $dotnet = "$env:USERPROFILE\.dotnet\dotnet.exe"
    }
    if (-not $dotnet) { throw 'dotnet SDK not found on the host. Install it or pass -SkipBuild.' }

    Write-Host 'Building consolize...'
    & $dotnet publish (Join-Path $repoRoot 'src\Consolize.SessionManager') -c Release -o $publishDir
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
}
if (-not (Test-Path $exe)) { throw "consolize.exe not found at $exe" }

$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.State -ne 'Running') { throw "VM '$VmName' is not running. Start-VM '$VmName' first." }

Write-Host 'Enabling the Guest Service Interface...'
Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface' -ErrorAction SilentlyContinue

$files = @($exe) + (Get-ChildItem (Join-Path $repoRoot 'setup') -Filter *.ps1 | Select-Object -ExpandProperty FullName)

foreach ($f in $files) {
    $dest = Join-Path $GuestPath (Split-Path $f -Leaf)
    try {
        Copy-VMFile -Name $VmName -SourcePath $f -DestinationPath $dest -FileSource Host -CreateFullPath -Force
        Write-Host "  -> $dest"
    } catch {
        throw @"
Copy-VMFile failed for $(Split-Path $f -Leaf): $($_.Exception.Message)

Common cause: the guest has not finished OOBE, or integration services are not
running yet. Log into the VM once, then re-run. Offline alternative: create an
ISO from out\publish and setup\, and attach it with Set-VMDvdDrive.
"@
    }
}

Write-Host ''
Write-Host "Files are in $GuestPath inside '$VmName'. From an admin PowerShell in the guest:"
Write-Host "    Set-ExecutionPolicy Bypass -Scope Process -Force"
Write-Host "    cd $GuestPath"
Write-Host "    .\bootstrap-gaming.ps1"
