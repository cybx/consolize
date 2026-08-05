#Requires -RunAsAdministrator
<#
Removes the Consolize custom shell for a user, restoring explorer.exe.
Optionally disables Shell Launcher globally.
#>
param(
    [Parameter(Mandatory)] [string]$UserName,
    [switch]$DisableGlobally
)
$ErrorActionPreference = 'Stop'

$ns = 'root\standardcimv2\embedded'
$sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value

Write-Host "Removing custom shell for '$UserName' ($sid)..."
$null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting -MethodName RemoveCustomShell -Arguments @{ Sid = $sid }

if ($DisableGlobally) {
    Write-Host 'Disabling Shell Launcher globally...'
    $null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting -MethodName SetEnabled -Arguments @{ Enabled = $false }
}

Write-Host "Done. '$UserName' gets explorer.exe again on next logon."
