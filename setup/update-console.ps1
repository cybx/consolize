<#
Updates the console from the couch: written to be launched from the Steam
library, where a controller can reach it.

It pulls the current setup scripts and binary, and can pull Windows updates too.
It elevates itself, because everything it touches lives in Program Files, and on
a console account set up by this project that prompt is a Yes/No a controller
can click.

The session manager is the shell and its file is therefore in use, so the new
binary cannot replace the running one. The installer moves the running file
aside instead, which Windows allows, and the new one takes over at the next
sign-in. Nothing breaks in the meantime.

  .\update-console.ps1                  # scripts and binary
  .\update-console.ps1 -IncludeWindows  # ...and Windows updates
#>
param(
    [switch]$IncludeWindows,
    [string]$SelfUrl = 'https://get-consolize.cybx.dev',
    [switch]$NoElevate
)
$ErrorActionPreference = 'Continue'

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin) -and -not $NoElevate) {
    Write-Host 'Asking for administrator rights...'
    $arguments = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($IncludeWindows) { $arguments += '-IncludeWindows' }
    if ($SelfUrl -ne 'https://get-consolize.cybx.dev') { $arguments += @('-SelfUrl', "`"$SelfUrl`"") }
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $arguments
    } catch {
        Write-Warning 'Elevation was declined, nothing was updated.'
        Start-Sleep -Seconds 5
    }
    return
}

Write-Host ''
Write-Host '  consolize update' -ForegroundColor Cyan
Write-Host ''

# --- scripts and binary -------------------------------------------------------
$exePath = 'C:\Program Files\Consolize\consolize.exe'
$before = if (Test-Path $exePath) { (Get-FileHash $exePath -Algorithm SHA256).Hash } else { $null }

Write-Host '==> Fetching the current scripts and binary...' -ForegroundColor Cyan
try {
    & ([scriptblock]::Create((Invoke-RestMethod $SelfUrl))) -UpdateOnly
} catch {
    Write-Warning "Could not update: $($_.Exception.Message)"
    Write-Warning 'Check the network and try again.'
}

$after = if (Test-Path $exePath) { (Get-FileHash $exePath -Algorithm SHA256).Hash } else { $null }
$binaryChanged = $before -ne $after

# --- Windows ------------------------------------------------------------------
if ($IncludeWindows) {
    Write-Host ''
    Write-Host '==> Windows updates...' -ForegroundColor Cyan
    try {
        if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
            Install-Module PSWindowsUpdate -Force -Scope AllUsers
        }
        Import-Module PSWindowsUpdate
        Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot
    } catch {
        Write-Warning "Windows updates failed: $($_.Exception.Message)"
    }
}

# --- games and apps -----------------------------------------------------------
Write-Host ''
Write-Host '==> Installed apps (winget)...' -ForegroundColor Cyan
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget upgrade --all --source winget --silent --accept-package-agreements --accept-source-agreements
} else {
    Write-Host '  winget not available, skipping'
}

# --- the library entries ------------------------------------------------------
# Reapplied on every update, not only at setup. Otherwise a machine whose
# shortcuts were written by an older version has no way back: the entry that
# launches this very script is one of the ones missing from the library, so the
# fix can never arrive through the route that needs fixing. The script decides
# for itself whether there is anything to do, and only closes Steam if there is.
Write-Host ''
Write-Host '==> Console entries in the Steam library...' -ForegroundColor Cyan
$shortcuts = Join-Path $PSScriptRoot 'add-console-shortcuts.ps1'
if (Test-Path $shortcuts) {
    try { & $shortcuts -Force } catch { Write-Warning "Could not update the library entries: $($_.Exception.Message)" }
} else {
    Write-Warning "  $shortcuts not found, skipping"
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green

if (-not $binaryChanged -and -not $IncludeWindows) {
    Write-Host 'Nothing that needs a restart. Closing in 15 seconds.'
    Start-Sleep -Seconds 15
    return
}

# --- ask for the restart, on screen, where a controller can answer -----------
# A console has no keyboard and this window is behind the frontend, so a console
# prompt would go unanswered. A topmost window with two large buttons, and a
# countdown that restarts on its own, works from the sofa.
$reason = if ($binaryChanged) { 'A new version of consolize is installed.' }
          else { 'Windows updates were installed.' }

Write-Host ''
Write-Host $reason
Write-Host 'It takes effect after a restart.'

$restart = $true
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'consolize'
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(760, 420)
    $form.BackColor = [System.Drawing.Color]::FromArgb(14, 16, 22)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(232, 238, 248)
    $form.TopMost = $true

    $splash = Join-Path $env:ProgramData 'Consolize\splash.png'
    if (Test-Path $splash) {
        $logo = New-Object System.Windows.Forms.PictureBox
        $logo.Image = [System.Drawing.Image]::FromFile($splash)
        $logo.SizeMode = 'Zoom'
        $logo.Size = New-Object System.Drawing.Size(720, 150)
        $logo.Location = New-Object System.Drawing.Point(20, 20)
        $form.Controls.Add($logo)
    }

    $message = New-Object System.Windows.Forms.Label
    $message.Text = "$reason`nRestart to finish."
    $message.Font = New-Object System.Drawing.Font('Segoe UI', 17)
    $message.TextAlign = 'MiddleCenter'
    $message.Size = New-Object System.Drawing.Size(720, 80)
    $message.Location = New-Object System.Drawing.Point(20, 180)
    $form.Controls.Add($message)

    $countdown = New-Object System.Windows.Forms.Label
    $countdown.Font = New-Object System.Drawing.Font('Segoe UI', 12)
    $countdown.ForeColor = [System.Drawing.Color]::FromArgb(130, 142, 160)
    $countdown.TextAlign = 'MiddleCenter'
    $countdown.Size = New-Object System.Drawing.Size(720, 30)
    $countdown.Location = New-Object System.Drawing.Point(20, 370)
    $form.Controls.Add($countdown)

    $now = New-Object System.Windows.Forms.Button
    $now.Text = 'Restart now'
    $now.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $now.Size = New-Object System.Drawing.Size(300, 70)
    $now.Location = New-Object System.Drawing.Point(60, 280)
    $now.BackColor = [System.Drawing.Color]::FromArgb(96, 190, 255)
    $now.ForeColor = [System.Drawing.Color]::FromArgb(10, 14, 20)
    $now.FlatStyle = 'Flat'
    $now.Add_Click({ $form.Tag = 'now'; $form.Close() })
    $form.Controls.Add($now)

    $later = New-Object System.Windows.Forms.Button
    $later.Text = 'Later'
    $later.Font = New-Object System.Drawing.Font('Segoe UI', 15)
    $later.Size = New-Object System.Drawing.Size(300, 70)
    $later.Location = New-Object System.Drawing.Point(400, 280)
    $later.BackColor = [System.Drawing.Color]::FromArgb(36, 42, 54)
    $later.ForeColor = [System.Drawing.Color]::FromArgb(232, 238, 248)
    $later.FlatStyle = 'Flat'
    $later.Add_Click({ $form.Tag = 'later'; $form.Close() })
    $form.Controls.Add($later)

    $form.AcceptButton = $now
    $form.CancelButton = $later

    $remaining = 60
    $countdown.Text = "Restarting on its own in $remaining seconds"
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:remaining--
        if ($script:remaining -le 0) { $timer.Stop(); $form.Tag = 'now'; $form.Close() }
        else { $countdown.Text = "Restarting on its own in $script:remaining seconds" }
    })
    $timer.Start()

    [void]$form.ShowDialog()
    $timer.Stop()
    $restart = $form.Tag -ne 'later'
    $form.Dispose()
} catch {
    Write-Warning "Could not show the restart screen ($($_.Exception.Message)); asking here instead."
    $answer = Read-Host 'Restart now? [Y/n]'
    $restart = $answer -notmatch '^[nN]'
}

if ($restart) {
    Write-Host 'Restarting...'
    shutdown.exe /r /t 5 /c 'consolize: restarting to finish the update'
} else {
    Write-Host 'Left for later. The update takes effect at the next restart.'
    Start-Sleep -Seconds 10
}
