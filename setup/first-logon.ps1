<#
Runs once, automatically, the first time the console account logs in. Registered
by setup-console.ps1; needs no administrator rights, on purpose.

It does the two things that only exist inside this account:
  - the per-user quiet settings (guide button belongs to Steam, no toasts)
  - the Steam login, which Windows keeps per user, so an administrator cannot
    do it on this account's behalf

A marker file in %LOCALAPPDATA% keeps it from running again. The scheduled task
itself is removed by the SYSTEM finish task once the shell is replaced.
#>
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$marker = Join-Path $env:LOCALAPPDATA 'Consolize\first-logon-done'

# What the SYSTEM finish task waits for: this account is ready to become a
# console. setup-console.ps1 grants this account write access to that folder.
$readyMarker = Join-Path $env:ProgramData 'Consolize\shared\account-ready'

if (Test-Path $marker) { return }

Write-Host ''
Write-Host '  consolize: finishing this account' -ForegroundColor Cyan
Write-Host '  phase 2 of 3'
Write-Host ''

# --- per-user quiet settings -------------------------------------------------
$quietUser = Join-Path $here 'quiet-user.ps1'
if (Test-Path $quietUser) {
    Write-Host '==> Per-user quiet settings...' -ForegroundColor Cyan
    & $quietUser
} else {
    Write-Warning "quiet-user.ps1 not found next to this script ($here)."
}

# --- this account's own startup ----------------------------------------------
# Phase 1 runs as the administrator, where HKCU is theirs, so it deliberately
# skips per-user entries. This is the session where the console account's own
# startup can be emptied, and everything removed is backed up first.
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path $runKey) {
    $removed = @()
    foreach ($p in (Get-ItemProperty $runKey).PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        $removed += [pscustomobject]@{ Name = $p.Name; Value = [string]$p.Value }
    }

    if ($removed) {
        $backup = Join-Path $env:LOCALAPPDATA 'Consolize\startup-backup.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $backup) | Out-Null
        $removed | ConvertTo-Json -Depth 3 | Set-Content $backup -Encoding UTF8

        foreach ($entry in $removed) {
            Remove-ItemProperty -Path $runKey -Name $entry.Name -Force -ErrorAction SilentlyContinue
            Write-Host "  removed from this account's startup: $($entry.Name)"
        }
        Write-Host "  backed up to $backup"
    }
}

# --- Steam login -------------------------------------------------------------
function Get-SteamPath {
    foreach ($dir in @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        (Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath,
        'C:\Program Files (x86)\Steam'
    )) {
        if ($dir -and (Test-Path (Join-Path ($dir -replace '/', '\') 'steam.exe'))) { return ($dir -replace '/', '\') }
    }
    return $null
}

function Test-SteamLogin {
    param([string]$SteamDir)
    # What matters is that Steam signs in on its own next launch. The modern
    # client records that as AutoLogin or RememberPassword in loginusers.vdf
    # plus AutoLoginUser under this Windows user. Do not require the
    # RememberPassword checkbox alone: the QR sign-in never shows one, and
    # ssfn files are gone since Steam moved to refresh tokens.
    $auto = (Get-ItemProperty 'HKCU:\SOFTWARE\Valve\Steam' -Name AutoLoginUser -ErrorAction SilentlyContinue).AutoLoginUser
    if (-not $auto) { return $false }

    $vdf = Join-Path $SteamDir 'config\loginusers.vdf'
    if (-not (Test-Path $vdf)) { return $false }
    $raw = Get-Content $vdf -Raw
    if ($raw -notmatch '"AccountName"\s+"') { return $false }
    return ($raw -match '"(RememberPassword|AutoLogin)"\s+"1"')
}

# Which frontend the console boots into decides what this account still needs.
# Without reading it, a Playnite console would sit here waiting for a Steam
# sign-in that is never coming, and the whole automated flow would dead-end.
$bootInto = 'steam'
$answersPath = Join-Path $env:ProgramData 'Consolize\answers.json'
if (Test-Path $answersPath) {
    try {
        $answers = Get-Content $answersPath -Raw | ConvertFrom-Json
        if ($answers.BootInto) { $bootInto = $answers.BootInto }
    } catch {
        Write-Warning "Could not read $answersPath, assuming Steam."
    }
}

# --- seeing the screen without covering it -----------------------------------
# The frontend opens fullscreen, on top of this window. Asking here would mean
# leaving the frontend to answer a question about the frontend, so: detect it
# automatically, and when a question is unavoidable, ask in a topmost dialog
# that draws over it.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ConsolizeWin32
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
'@ -ErrorAction SilentlyContinue

function Test-FrontendOnScreen {
    param([string[]]$ProcessNames = @('steam', 'steamwebhelper'))

    $handle = [ConsolizeWin32]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return $false }

    # NOT $pid: that is an automatic variable and [ref] on it fails
    $ownerId = 0
    [void][ConsolizeWin32]::GetWindowThreadProcessId($handle, [ref]$ownerId)
    $owner = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
    if (-not $owner -or $ProcessNames -notcontains $owner.ProcessName) { return $false }

    $rect = New-Object ConsolizeWin32+RECT
    if (-not [ConsolizeWin32]::GetWindowRect($handle, [ref]$rect)) { return $false }

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    return ($width -ge $screen.Width * 0.9 -and $height -ge $screen.Height * 0.9)
}

function Show-TopmostQuestion {
    param([string]$Text, [string]$Caption = 'consolize')

    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $owner.StartPosition = 'CenterScreen'
    $null = $owner.Handle   # force the window to exist so it can own the dialog
    try {
        return [System.Windows.Forms.MessageBox]::Show(
            $owner, $Text, $Caption,
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question)
    } finally {
        $owner.Dispose()
    }
}

$script:loginConfirmed = $false
$steam = Get-SteamPath

if ($bootInto -ne 'steam') {
    Write-Host ''
    Write-Host "==> Frontend for this account: $bootInto" -ForegroundColor Cyan
    $frontendPath = switch ($bootInto) {
        'playnite' { Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe' }
        'hydra'    { Join-Path $env:LOCALAPPDATA 'Programs\Hydra\Hydra.exe' }
        default    { $null }
    }
    if ($frontendPath -and (Test-Path $frontendPath)) {
        Write-Host "  found: $frontendPath"
        Write-Host '  opening it once so it can finish its own first-run setup...'
        Start-Process $frontendPath
        Start-Sleep -Seconds 10
        $confirm = Read-Host '  Did it open and look usable? [Y/n]'
        $script:loginConfirmed = $confirm -notmatch '^[nN]'
    } else {
        Write-Warning "  $bootInto is not installed for this account ($frontendPath)."
        Write-Warning '  Launchers other than Steam install per user, so install it while'
        Write-Warning '  signed in here, then run this script again.'
    }
} elseif (-not $steam) {
    Write-Warning 'Steam is not installed. Run bootstrap-gaming.ps1 as admin first.'
} else {
    Write-Host ''
    Write-Host '==> Steam login for this account' -ForegroundColor Cyan
    if (Test-SteamLogin $steam) {
        Write-Host '  already signed in on this account.'
        $script:loginConfirmed = $true
    } else {
        Write-Host '  Steam keeps its login per Windows user, so this account needs its own.'
        Write-Host '  Two-factor and the QR code are both fine: Steam Guard asks once per'
        Write-Host '  machine and then stores a token, so the console never asks again.'
        Write-Host '  Scanning the QR with the Steam mobile app is the easiest here, since'
        Write-Host '  it skips typing a password on a TV.'
        Write-Host ''

        # Steam's login window is Chromium, and the Windows touch keyboard only
        # auto-invokes for fields that speak TSF, so clicking the email box
        # summons nothing. osk.exe is the classic on-screen keyboard: a plain
        # window that types into whatever has focus, including Chromium.
        try {
            Start-Process "$env:WINDIR\System32\osk.exe" -ErrorAction Stop
            Write-Host '  An on-screen keyboard is open in case you type the password:'
            Write-Host '  Steam''s own login box does not summon the Windows one by itself.'
        } catch {
            Write-Host '  (could not open the on-screen keyboard; the QR sign-in needs no typing)'
        }

        Start-Process (Join-Path $steam 'steam.exe')

        Write-Host '  Waiting for the sign-in. Press Enter once you are in and I will check.'
        $waited = 0
        while (-not (Test-SteamLogin $steam) -and $waited -lt 1800) {
            if ($Host.UI.RawUI.KeyAvailable) {
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                if (Test-SteamLogin $steam) { break }
                Write-Host '  not signed in yet as far as I can tell, still waiting...'
            }
            Start-Sleep -Seconds 3
            $waited += 3
        }

        # Heuristics can be wrong; the real acceptance test is whether Big
        # Picture comes up. Restart Steam rather than switching modes in the
        # running client: one that just authenticated is usually still updating
        # or restarting itself, and -bigpicture on top of that does nothing.
        $bigPictureOk = $false
        $attempt = 0
        while ($true) {
            $attempt++
            Write-Host ''
            Write-Host "  Restarting Steam into Big Picture (attempt $attempt)..."
            Get-Process steam, steamwebhelper -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            Start-Process (Join-Path $steam 'steam.exe') -ArgumentList '-bigpicture'

            # Watch for it rather than ask: a fullscreen frontend in the
            # foreground is the answer, and it arrives without anyone leaving it.
            Write-Host '  Watching for a fullscreen Steam window (up to 90s)...'
            $detected = $false
            for ($i = 0; $i -lt 45; $i++) {
                Start-Sleep -Seconds 2
                if (Test-FrontendOnScreen) { $detected = $true; break }
                Write-Host -NoNewline '.'
            }
            Write-Host ''

            if ($detected) {
                Write-Host '  Big Picture is on screen.' -ForegroundColor Green
                $bigPictureOk = $true
                break
            }

            # Only now ask, and ask on top of whatever is covering the screen.
            $reply = Show-TopmostQuestion -Caption 'consolize: is Big Picture up?' -Text @"
Steam was restarted in Big Picture mode, but no fullscreen Steam window was
detected.

Yes    it is on screen and signed in, carry on
No     try again (restart Steam and watch once more)
Cancel it will not open here, replace the shell anyway

Cancel is the right answer on a machine with no GPU, where Big Picture cannot
render at all. The shell still falls back to the desktop if the frontend never
starts.
"@

            if ($reply -eq [System.Windows.Forms.DialogResult]::Yes) { $bigPictureOk = $true; break }
            if ($reply -eq [System.Windows.Forms.DialogResult]::Cancel) {
                Write-Warning '  Carrying on without a verified frontend.'
                $bigPictureOk = $true
                break
            }
            if ($attempt -ge 3) {
                Write-Warning '  Giving up after three attempts; the shell will not be replaced.'
                break
            }
        }

        if ($bigPictureOk) {
            Write-Host '  Big Picture confirmed.' -ForegroundColor Green
            $script:loginConfirmed = $true

            # Steam re-adds its autostart entry once it runs
            foreach ($p in (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ($p.Name -match 'steam' -or [string]$p.Value -match 'steam\.exe') {
                    Remove-ItemProperty -Path $runKey -Name $p.Name -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Warning '  Big Picture did not come up clean, so the shell will not be replaced.'
        }
    }
}

# Outside the sign-in branch on purpose: an account that was ALREADY signed in
# skips that branch entirely, and used to end up as a console with no way to
# reach the desktop or the settings panel.
if ($script:loginConfirmed -and $bootInto -eq 'steam') {
    $shortcuts = Join-Path $here 'add-console-shortcuts.ps1'
    if (Test-Path $shortcuts) {
        Write-Host ''
        Write-Host '==> Adding "Quick Settings" and "Desktop Mode" to the Steam library' -ForegroundColor Cyan
        # a child script with its own EAP=Stop would otherwise kill this one and
        # the account would never report itself ready
        try { & $shortcuts -Force } catch { Write-Warning "  could not add them: $($_.Exception.Message)" }
    }
}

# Trust what was actually seen on screen over the file heuristics: the QR
# sign-in and some Steam Guard flows do not write the checkbox key at all.
$steamReady = $script:loginConfirmed
if ($steamReady) {
    # only mark this done when it actually finished: otherwise the task should
    # run again at the next logon instead of silently skipping itself
    New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
    Set-Content $marker (Get-Date).ToString('s') -Encoding UTF8
    try {
        # the account name, not a timestamp: the finish task uses it to reject a
        # marker left behind by an earlier run against a different account
        Set-Content $readyMarker $env:USERNAME -Encoding UTF8
        Write-Host ''
        Write-Host 'This account is ready.' -ForegroundColor Green
        Write-Host 'The machine takes it from here: it checks everything, replaces the shell'
        Write-Host 'and reboots into console mode in a moment. Nothing else for you to do.'
        Write-Host ''
        Write-Host 'Closing in 20 seconds...'
        Start-Sleep -Seconds 20
    } catch {
        Write-Warning "Could not signal readiness ($($_.Exception.Message))."
        Write-Warning 'From an administrator session run: setup-console.ps1 -Finish'
        Read-Host 'Press Enter to close'
    }
} else {
    Write-Host ''
    Write-Warning "This account is not ready ($bootInto), so the shell will NOT be replaced."
    Write-Warning 'That is deliberate: booting into a login window a controller cannot fill'
    Write-Warning 'in would strand you. Finish the frontend sign-in, then run:'
    Write-Host "    $($MyInvocation.MyCommand.Path)"
    Read-Host 'Press Enter to close'
}
