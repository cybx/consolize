#Requires -RunAsAdministrator
<#
Sets the language the console speaks: the Windows display language, the keyboard
layout, the regional formats and the time zone.

Worth separating two things that people mean by "install it in Portuguese":

  The Windows display language is a downloaded language pack. This installs it
  and makes it the preferred UI language, then copies the settings to the system
  and to accounts created afterwards, so the console account gets them too.

  An application's language is usually its own business. Steam in particular
  follows the language on your Steam account once you sign in, so it ends up in
  your language regardless of what the installer showed. What this script does
  set is the client's starting language, for the screens you see before signing
  in.

The keyboard layout is the one that bites hardest and gets the least attention:
it decides what comes out when you type the Steam password on the on-screen
keyboard. A Brazilian machine left on the US layout puts the wrong characters
under the punctuation keys.

  .\locale-console.ps1 -Language pt-BR
  .\locale-console.ps1 -Language pt-BR -TimeZone 'E. South America Standard Time'
  .\locale-console.ps1 -Language en-US -SkipLanguagePack   # only formats/keyboard
#>
param(
    [Parameter(Mandatory)] [string]$Language,
    [string]$TimeZone,
    # The display language is a real download. Skip it to change only the
    # keyboard, formats and time zone.
    [switch]$SkipLanguagePack
)
$ErrorActionPreference = 'Stop'

# Keyboard layouts for the languages worth spelling out; anything else falls
# back to whatever Windows pairs with the language by default.
$layouts = @{
    'pt-BR' = '0416:00000416'   # ABNT2
    'pt-PT' = '0816:00000816'
    'en-US' = '0409:00000409'
    'es-ES' = '0C0A:0000040A'
    'fr-FR' = '040C:0000040C'
    'de-DE' = '0407:00000407'
    'it-IT' = '0410:00000410'
}

Write-Host "Language: $Language"

# --- the display language pack ----------------------------------------------

if (-not $SkipLanguagePack) {
    $installed = (Get-InstalledLanguage -ErrorAction SilentlyContinue).LanguageId
    if ($installed -contains $Language) {
        Write-Host '  language pack already installed'
    } else {
        Write-Host '  installing the language pack (a download, this takes a few minutes)...'
        try {
            Install-Language -Language $Language -ErrorAction Stop | Out-Null
            Write-Host '  installed'
        } catch {
            Write-Warning "  could not install it: $($_.Exception.Message)"
            Write-Warning '  carrying on with the formats and keyboard, which do not need it'
        }
    }

    try {
        Set-SystemPreferredUILanguage -Language $Language -ErrorAction Stop
        Write-Host '  set as the preferred display language'
    } catch {
        Write-Warning "  could not set the display language: $($_.Exception.Message)"
    }
}

# --- keyboard, formats, region ----------------------------------------------

$layout = $layouts[$Language]
$list = New-WinUserLanguageList -Language $Language
if ($layout) {
    $list[0].InputMethodTips.Clear()
    $list[0].InputMethodTips.Add($layout)
    Write-Host "  keyboard layout: $layout"
}
Set-WinUserLanguageList $list -Force
Write-Host '  user language list set'

try {
    Set-Culture -CultureInfo $Language
    Write-Host "  regional formats: $Language"
} catch {
    Write-Warning "  could not set the regional format: $($_.Exception.Message)"
}

try {
    Set-WinSystemLocale -SystemLocale $Language
    Write-Host "  system locale: $Language (applies after a restart)"
} catch {
    Write-Warning "  could not set the system locale: $($_.Exception.Message)"
}

if ($TimeZone) {
    try {
        Set-TimeZone -Id $TimeZone
        Write-Host "  time zone: $TimeZone"
    } catch {
        Write-Warning "  unknown time zone '$TimeZone'. List them with: Get-TimeZone -ListAvailable"
    }
}

# --- and make the console account inherit all of it -------------------------
# Without this the settings stop at the account that ran the script, and the
# console account, created here and signed into later, keeps the defaults.
try {
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop
    Write-Host '  copied to the sign-in screen and to accounts created from now on'
} catch {
    Write-Warning "  could not copy the settings to new accounts: $($_.Exception.Message)"
    Write-Warning '  the console account may keep the previous language and keyboard'
}

Write-Host ''
Write-Host 'Done. The display language applies after a restart.' -ForegroundColor Green
