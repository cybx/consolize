#Requires -RunAsAdministrator
<#
Gives an account its normal Windows desktop back, undoing either mechanism
enable-shell-launcher.ps1 can use. It always undoes both, so it works without
you having to remember which one was applied.

  .\disable-shell-launcher.ps1 -UserName gamer
  .\disable-shell-launcher.ps1 -UserName gamer -DisableGlobally   # also turn the feature off
#>
param(
    [string]$UserName,
    [switch]$DisableGlobally
)
# Continue, not Stop: this is a repair path and every step should be attempted
# even when an earlier one has nothing to undo.
$ErrorActionPreference = 'Continue'

if ($UserName) {
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        Write-Warning "Could not resolve '$UserName' to a SID: $($_.Exception.Message)"
        $sid = $null
    }
} else {
    $sid = $null
    if (-not $DisableGlobally) { throw 'UserName is required unless -DisableGlobally is used.' }
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
                $shellState = Join-Path $env:ProgramData "Consolize\shell-before-$sid.json"
                $before = $null
                if (Test-Path $shellState) {
                    try { $before = Get-Content $shellState -Raw | ConvertFrom-Json } catch { }
                }

                if ($current -match '(?i)(?:^|[\\/])consolize\.exe(?:\s|$|")') {
                    if ($before -and $before.HadShell -and $before.PreviousShell) {
                        New-ItemProperty -Path $key -Name Shell -Value $before.PreviousShell `
                            -PropertyType String -Force | Out-Null
                        Write-Host "Previous per-user shell restored for '$UserName': $($before.PreviousShell)"
                    } else {
                        Remove-ItemProperty -Path $key -Name Shell -Force -ErrorAction SilentlyContinue
                        Write-Host "Per-user Consolize shell removed for '$UserName' (was: $current)"
                    }
                    Remove-Item $shellState -Force -ErrorAction SilentlyContinue
                } elseif ($current) {
                    Write-Warning "'$UserName' now has a different custom shell ('$current'); leaving it untouched."
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

} elseif (-not $hasShellLauncher) {
    Write-Host 'Shell Launcher is not present on this edition (nothing to undo there)'
}

if ($hasShellLauncher -and $DisableGlobally) {
    try {
        $null = Invoke-CimMethod -Namespace $ns -ClassName WESL_UserSetting `
            -MethodName SetEnabled -Arguments @{ Enabled = $false } -ErrorAction Stop
        Write-Host 'Shell Launcher disabled globally'
    } catch {
        Write-Warning "Could not disable Shell Launcher: $($_.Exception.Message)"
    }
}

Write-Host ''
if ($UserName) {
    Write-Host "Done. '$UserName' gets explorer.exe again at its next sign-in." -ForegroundColor Green
} else {
    Write-Host 'Done. Shell Launcher is disabled globally.' -ForegroundColor Green
}
