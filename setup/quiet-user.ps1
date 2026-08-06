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

Write-Host 'Desktop background set to the console splash...'
# The desktop is only ever seen for a moment, on the way to the frontend or in
# desktop mode, but the default Windows picture there breaks the illusion.
# Black behind it, so any letterboxing matches the splash.
$splash = Join-Path $env:ProgramData 'Consolize\splash.png'
if (Test-Path $splash) {
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'WallPaper' $splash 'String'
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'WallpaperStyle' '6' 'String'   # 6 = fit
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'TileWallpaper' '0' 'String'
    Set-RegValue 'HKCU:\Control Panel\Colors' 'Background' '0 0 0' 'String'

    Add-Type -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool SystemParametersInfo(int action, int param, string value, int winIni);
'@ -Name Wallpaper -Namespace ConsolizeUI -ErrorAction SilentlyContinue
    # SPI_SETDESKWALLPAPER, SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE
    [void][ConsolizeUI.Wallpaper]::SystemParametersInfo(20, 0, $splash, 3)
    Write-Host "  $splash"
} else {
    Write-Host "  no splash.png at $splash, leaving the background alone"
}

Write-Host 'Screen saver off (a console never interrupts what is on screen)...'
# The screen saver is per user and survives every power setting: without this it
# still cuts in over a paused game or a film.
Set-RegValue 'HKCU:\Control Panel\Desktop' 'ScreenSaveActive' '0' 'String'
Set-RegValue 'HKCU:\Control Panel\Desktop' 'ScreenSaveTimeOut' '0' 'String'
Set-RegValue 'HKCU:\Control Panel\Desktop' 'ScreenSaverIsSecure' '0' 'String'

Write-Host 'Touch keyboard pops up on any text field (no physical keyboard needed)...'
# Windows only auto-invokes the touch keyboard on tablets by default. On a
# couch PC there is no keyboard at all, so make it appear whenever a text field
# takes focus, in any app.
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7' 'EnableDesktopModeAutoInvoke' 1
# Bigger keys, since this is read from three metres away
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7' 'KeyboardLayoutPreference' 0

Write-Host ''
Write-Host 'Typing from the couch, what each layer gives you:' -ForegroundColor Cyan
Write-Host '  Inside Steam Big Picture: Steam draws its own gamepad keyboard. Nothing to do.'
Write-Host '  Inside Playnite Fullscreen: it has its own on-screen keyboard too.'
Write-Host '  Anywhere else (Windows dialogs, other launchers): the Windows touch keyboard'
Write-Host '  now opens by itself on text fields, but only where the field speaks TSF.'
Write-Host '  Chromium based UIs, Steam''s own login window among them, summon nothing:'
Write-Host '  there, osk.exe is the one that always works. It is also driven by mouse or'
Write-Host '  touch, not by a gamepad, so to reach a keyboard from the couch:'
Write-Host '    - Steam > Settings > Controller > Desktop layout: bind a chord (Guide + X'
Write-Host '      works well) to "Show On-Screen Keyboard". Steam then draws ITS keyboard'
Write-Host '      over the desktop, fully gamepad navigable.'
Write-Host '    - the same Desktop layout gives the right stick mouse control for anything'
Write-Host '      that still needs a pointer.'
Write-Host '  That binding lives in your Steam cloud config, so it cannot be scripted here.'
Write-Host ''
Write-Host 'Done. Sign out and back in for everything to apply.'
