#Requires -RunAsAdministrator
<#
Gives an account its normal Windows desktop back, undoing either mechanism
enable-shell-launcher.ps1 can use. It always undoes both, so it works without
you having to remember which one was applied.

  .\disable-shell-launcher.ps1 -UserName gamer
  .\disable-shell-launcher.ps1 -UserName gamer -DisableGlobally   # also turn the feature off
#>
param(
    [Parameter(Mandatory)] [string]$UserName,
    [switch]$DisableGlobally
)
# Continue, not Stop: this is a repair path and every step should be attempted
# even when an earlier one has nothing to undo.
$ErrorActionPreference = 'Continue'

try {
    $sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
} catch {
    Write-Warning "Could not resolve '$UserName' to a SID: $($_.Exception.Message)"
    $sid = $null
}

# --- the per-user registry shell ---------------------------------------------

if ($sid) {
    $hive = "Registry::HKEY_USERS\$sid"
    $mounted = $null

    if (-not (Test-Path $hive)) {
        $profileDir = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.SID -eq $sid } | Select-Object -First 1).LocalPath
        $dat = if ($profileDir) { Join-Path $profileDir 'NTUSER.DAT' } else { $null }
        if ($dat -and (Test-Path $dat)) {
            $mounted = "consolize-$sid"
            & reg.exe load "HKU\$mounted" $dat *>$null
            if ($LASTEXITCODE -eq 0) { $hive = "Registry::HKEY_USERS\$mounted" } else { $mounted = $null }
        }
    }

    if (Test-Path $hive) {
        try {
            $key = Join-Path $hive 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            if (Test-Path $key) {
                $current = (Get-ItemProperty -Path $key -Name Shell -ErrorAction SilentlyContinue).Shell
                if ($current) {
                    Remove-ItemProperty -Path $key -Name Shell -Force -ErrorAction SilentlyContinue
                    Write-Host "Per-user shell removed for '$UserName' (was: $current)"
                } else {
                    Write-Host "No per-user shell set for '$UserName'"
                }
            }
        } finally {
            if ($mounted) {
                [GC]::Collect(); [GC]::WaitForPendingFinalizers()
                & reg.exe unload "HKU\$mounted" *>$null
            }
        }
    }
}

# --- Shell Launcher ----------------------------------------------------------

$ns = 'root\standardcimv2\embedded'
$hasShellLauncher = $null -ne (Get-CimClass -Namespace $ns -ClassName WESL_UserSetting -ErrorAction SilentlyContinue)

if ($hasShellLauncher -and $sid) {
    try {
        $null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting `
            -MethodName RemoveCustomShell -Arguments @{ Sid = $sid } -ErrorAction Stop
        Write-Host "Shell Launcher custom shell removed for '$UserName'"
    } catch {
        Write-Host "No Shell Launcher entry for '$UserName'"
    }

    if ($DisableGlobally) {
        try {
            $null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting `
                -MethodName SetEnabled -Arguments @{ Enabled = $false } -ErrorAction Stop
            Write-Host 'Shell Launcher disabled globally'
        } catch {
            Write-Warning "Could not disable Shell Launcher: $($_.Exception.Message)"
        }
    }
} elseif (-not $hasShellLauncher) {
    Write-Host 'Shell Launcher is not present on this edition (nothing to undo there)'
}

Write-Host ''
Write-Host "Done. '$UserName' gets explorer.exe again at its next sign-in." -ForegroundColor Green
