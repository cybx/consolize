#Requires -RunAsAdministrator
<#
Builds and installs the Consolize session manager to Program Files.
Run from anywhere inside the repository. Requires the .NET 10 SDK.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'src\Consolize.SessionManager'
$out = Join-Path $repoRoot 'out\publish'
$installDir = 'C:\Program Files\Consolize'

dotnet publish $project -c Release -r win-x64 -o $out
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item (Join-Path $out 'consolize.exe') $installDir -Force

Write-Host ''
Write-Host "Installed: $installDir\consolize.exe"
Write-Host "Bench test it inside a normal desktop session first:"
Write-Host "    & '$installDir\consolize.exe'            # frontend opens, watchdog active"
Write-Host "    & '$installDir\consolize.exe' send status"
Write-Host "    & '$installDir\consolize.exe' send quit"
Write-Host "Then make it the shell for the gamer account:"
Write-Host "    .\enable-shell-launcher.ps1 -UserName gamer"
