<#
Per-user quiet layer (F2). Run INSIDE the gamer session, no admin needed.
Idempotent: safe to re-run. Sign out/in afterwards.

  .\quiet-user.ps1
  .\quiet-user.ps1 -Restore   # give this account its notifications back
#>
param([switch]$Restore)
$ErrorActionPreference = 'Stop'

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Host "  $Path\$Name = $Value"
}

# One list, so undoing cannot drift from doing. Windows treats every one of
# these as "on" when the value is absent, so deleting is the way back rather
# than writing a guessed default.
$settings = @(
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; Value = 0
       Note = 'Guide button belongs to Steam (Game Bar nexus binding off)' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\GameBar'; Name = 'ShowStartupPanel'; Value = 0 }

    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0
       Note = 'Game DVR capture off for this user' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 }

    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0
       Note = 'Notification toasts off (nothing pops over the game)' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'; Value = 0 }

    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0
       Note = '"Finish setting up your device" nag off' }

    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Value = 0
       Note = 'Windows tips and suggestions off' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Value = 0 }

    # Default on, and it makes any console window look frozen the moment someone
    # clicks in it. On a machine driven with a mouse that reads as a crash.
    @{ Path = 'HKCU:\Console'; Name = 'QuickEdit'; Value = 0
       Note = 'Console QuickEdit off (a click in a console window pauses whatever it is running)' }

    # The screen saver is per user and survives every power setting: without this
    # it still cuts in over a paused game or a film.
    @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'ScreenSaveActive'; Value = '0'; Type = 'String'
       Note = 'Screen saver off (a console never interrupts what is on screen)' }
    @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'ScreenSaveTimeOut'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'ScreenSaverIsSecure'; Value = '0'; Type = 'String' }

    # Windows only auto-invokes the touch keyboard on tablets by default. On a
    # couch PC there is no keyboard at all, so make it appear whenever a text
    # field takes focus, in any app.
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableDesktopModeAutoInvoke'; Value = 1
       Note = 'Touch keyboard pops up on any text field (no physical keyboard needed)' }
    # Bigger keys, since this is read from three metres away
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'KeyboardLayoutPreference'; Value = 0 }
)

if ($Restore) {
    Write-Host "Undoing the quiet layer for $env:USERNAME..."
    foreach ($setting in $settings) {
        if (Test-Path $setting.Path) {
            Remove-ItemProperty -Path $setting.Path -Name $setting.Name -Force -ErrorAction SilentlyContinue
            Write-Host "  removed $($setting.Path)\$($setting.Name)"
        }
    }

    Set-RegValue 'HKCU:\Control Panel\Desktop' 'WallPaper' '' 'String'
    Add-Type -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool SystemParametersInfo(int action, int param, string value, int winIni);
'@ -Name Wallpaper -Namespace ConsolizeUI -ErrorAction SilentlyContinue
    [void][ConsolizeUI.Wallpaper]::SystemParametersInfo(20, 0, '', 3)

    Write-Host ''
    Write-Host 'Done, sign out and back in. The picture that was on the desktop before is not' -ForegroundColor Yellow
    Write-Host 'restored: it was replaced without being recorded, so the background is now empty.' -ForegroundColor Yellow
    return
}

foreach ($setting in $settings) {
    if ($setting.Note) { Write-Host "$($setting.Note)..." }
    $type = if ($setting.Type) { $setting.Type } else { 'DWord' }
    Set-RegValue $setting.Path $setting.Name $setting.Value $type
}

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
