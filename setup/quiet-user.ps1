<#
Per-user quiet layer (F2). Run INSIDE the gamer session, no admin needed.
Idempotent: safe to re-run. Sign out/in afterwards.
#>
$ErrorActionPreference = 'Stop'

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Host "  $Path\$Name = $Value"
}

Write-Host 'Guide button belongs to Steam (Game Bar nexus binding off)...'
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'ShowStartupPanel' 0

Write-Host 'Game DVR capture off for this user...'
Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0

Write-Host 'Notification toasts off (nothing pops over the game)...'
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0

Write-Host '"Finish setting up your device" nag off...'
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0

Write-Host 'Windows tips and suggestions off...'
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0

Write-Host 'Done. Sign out and back in for everything to apply.'
