#Requires -RunAsAdministrator
<#
Remote maintenance (F5): work on the console from another machine, because the
couch is the worst place to debug the couch machine.

Two doors, both built into Windows, both answering only on the home network
(the firewall rules are scoped to the Domain and Private profiles, never
Public):

  SSH             run commands here from any other machine, the way a Linux box
                  does it. OpenSSH Server with PowerShell as the login shell.
                  `consolize send desktop` works from an SSH session, so the
                  television can be rescued without touching it.

  Remote Desktop  see a screen, and there are two different screens to see.
                  Signing in as the ADMIN account opens a separate session and
                  leaves the television alone. Shadowing shows THE console
                  session, the thing actually on the TV. Signing in over RDP as
                  the console account itself is the mistake: it takes the
                  session away from the television, which drops to a lock
                  screen until tscon gives it back (printed below).

Sign-in uses the accounts and passwords this machine already has: nothing new
to manage, nothing stored by this script.

  .\remote-console.ps1              # both doors
  .\remote-console.ps1 -Ssh        # commands only
  .\remote-console.ps1 -Rdp        # screen only
  .\remote-console.ps1 -Restore    # both off, which is the Windows default
#>
param(
    [switch]$Ssh,
    [switch]$Rdp,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

$doSsh = $Ssh -or -not ($Ssh -or $Rdp)
$doRdp = $Rdp -or -not ($Ssh -or $Rdp)

$tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$tsPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
# The group id, not the display name: 'Remote Desktop' is localized, and this
# has to keep working on a Portuguese Windows.
$rdpFirewallGroup = '@FirewallAPI.dll,-28752'
$hostName = $env:COMPUTERNAME.ToLower()

# ---------------------------------------------------------------- restore ----

if ($Restore) {
    Write-Host 'Closing the remote doors (off is the Windows default)...'

    $sshd = Get-Service sshd -ErrorAction SilentlyContinue
    if ($sshd) {
        Stop-Service sshd -Force -ErrorAction SilentlyContinue
        Set-Service sshd -StartupType Disabled
        Write-Host '  sshd stopped and disabled (the OpenSSH capability stays; it is inert while the service is off)'
    } else {
        Write-Host '  sshd was never installed'
    }
    Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue |
        Disable-NetFirewallRule

    Set-ItemProperty $tsKey -Name fDenyTSConnections -Value 1
    Get-NetFirewallRule -Group $rdpFirewallGroup -ErrorAction SilentlyContinue |
        Disable-NetFirewallRule
    Remove-ItemProperty $tsPolicy -Name Shadow -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
    Write-Host '  Remote Desktop off, its firewall rules disabled, the shadow policy and remote-UAC exception removed'
    return
}

# -------------------------------------------------------------------- ssh ----

if ($doSsh) {
    Write-Host ''
    Write-Host '==> SSH: run commands here from another machine' -ForegroundColor Cyan

    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if (-not $cap -or $cap.State -ne 'Installed') {
        Write-Host '  installing the OpenSSH Server capability...'
        try {
            $add = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
            if ($add.RestartNeeded) { Write-Host '  (Windows flagged a restart to finish it)' }
        } catch {
            throw ("Could not install OpenSSH Server: $($_.Exception.Message). " +
                'Features on Demand come from Windows Update; if this machine cannot reach ' +
                'it, install the FoD from offline media and run this again.')
        }
    } else {
        Write-Host '  OpenSSH Server capability already installed'
    }

    # PowerShell as the login shell rather than cmd: every consolize script and
    # every fix you would type over this connection is PowerShell anyway. pwsh
    # when the machine has it, Windows PowerShell otherwise. Written even when
    # the service is not up yet, so the re-run after a restart has less to do.
    $shell = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if (-not $shell) { $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    New-Item 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null

    # Seen in the field: Add-WindowsCapability reports success and the sshd
    # service only exists after the restart it quietly wanted. Wait a little,
    # then step aside with instructions, rather than dying at Set-Service --
    # which once took a whole provisioning run down three steps from the end.
    $sshd = $null
    for ($i = 0; $i -lt 20 -and -not $sshd; $i++) {
        $sshd = Get-Service sshd -ErrorAction SilentlyContinue
        if (-not $sshd) { Start-Sleep -Seconds 1 }
    }

    if ($sshd) {
        Set-Service sshd -StartupType Automatic
        Start-Service sshd

        # The capability sometimes creates this rule on every profile and
        # sometimes not at all; either way the end state is one rule, home
        # network only.
        $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
        if ($rule) {
            Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Domain, Private
        } else {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH SSH Server (sshd)' `
                -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Domain, Private | Out-Null
        }

        Write-Host "  sshd running, PowerShell as the login shell ($shell)"
        Write-Host ''
        Write-Host '  From another machine:'
        Write-Host "    ssh $env:USERNAME@$hostName" -ForegroundColor Cyan
        Write-Host '  Key sign-in for administrators reads C:\ProgramData\ssh\administrators_authorized_keys'
        Write-Host '  (not the usual ~\.ssh\authorized_keys); passwords work with nothing extra.'
    } else {
        Write-Warning '  OpenSSH Server is staged, but its service has not appeared: Windows'
        Write-Warning '  wants the restart first. After the next reboot, finish with:'
        Write-Warning '    .\remote-console.ps1 -Ssh'
    }
}

# -------------------------------------------------------------------- rdp ----

if ($doRdp) {
    Write-Host ''
    Write-Host '==> Remote Desktop: see a screen from another machine' -ForegroundColor Cyan

    Set-ItemProperty $tsKey -Name fDenyTSConnections -Value 0
    # NLA on: the connecting side proves who it is before any session exists.
    Set-ItemProperty "$tsKey\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
    Enable-NetFirewallRule -Group $rdpFirewallGroup
    Set-NetFirewallRule -Group $rdpFirewallGroup -Profile Domain, Private

    # Session shadowing rides a SEPARATE firewall rule that enabling the Remote
    # Desktop group does not reliably turn on. Without it, `mstsc /shadow` is
    # refused with "access denied" even though normal RDP works and the policy
    # below is set. Seen in the field, so turn it on by name.
    $shadowRule = Get-NetFirewallRule -Name 'RemoteDesktop-Shadow-In-TCP' -ErrorAction SilentlyContinue
    if ($shadowRule) {
        Enable-NetFirewallRule -Name 'RemoteDesktop-Shadow-In-TCP'
        Set-NetFirewallRule -Name 'RemoteDesktop-Shadow-In-TCP' -Profile Domain, Private
    }

    # Shadowing: view and drive the session that is on the television instead
    # of opening one of your own. 2 = full control without asking on the TV,
    # which is the point: the person at the TV and the person shadowing are the
    # same owner.
    New-Item $tsPolicy -Force | Out-Null
    New-ItemProperty $tsPolicy -Name Shadow -Value 2 -PropertyType DWord -Force | Out-Null

    # Remote shadow's control channel authenticates over the network, and Windows
    # filters a LOCAL admin account down to a standard-user token over the network
    # (remote UAC), so the shadow is refused with "access denied" even with the
    # policy and firewall right. Seen in the field on the first live console. This
    # lets a local admin keep its full token over the network, which is what
    # shadowing from another machine, and remote administration generally, needs.
    New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null

    Write-Host '  Remote Desktop on, NLA required, home network only'
    Write-Host ''
    Write-Host '  To fix things without touching the TV, sign in as an admin account:'
    Write-Host "    mstsc /v:$hostName      (as $env:USERNAME, NOT the console account)" -ForegroundColor Cyan
    Write-Host '  To SEE the television session, find its id (over SSH: qwinsta), then:'
    Write-Host "    mstsc /v:$hostName /shadow:<id> /control /noConsentPrompt" -ForegroundColor Cyan
    Write-Host '  Shadowing from a machine whose Windows user is not an admin here needs the'
    Write-Host '  credential cached first, or it is refused with "access denied":'
    Write-Host "    cmdkey /generic:TERMSRV/$hostName /user:$env:USERNAME /pass" -ForegroundColor Cyan
    Write-Host '  Signed in over RDP as the console account by mistake, and the TV is stuck'
    Write-Host '  on a lock screen? Give the session back (over SSH, or the admin session):'
    Write-Host '    tscon <id> /dest:console' -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'The doors opened here answer on Domain and Private networks only; on Public' -ForegroundColor Green
Write-Host 'this machine stays silent. Sign-in is the accounts it already has.' -ForegroundColor Green
Write-Host 'Off again with: .\remote-console.ps1 -Restore'
