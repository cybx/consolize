#Requires -RunAsAdministrator
<#
Stops Windows Firewall interrupting games, which it does with an elevated
"allow this app to communicate" dialog the first time a game opens a listening
socket. That prompt is a dead end from a sofa for the same reason every other
elevated prompt is.

Two ways to stop it, and they are not equally blunt:

  (default) quiet
      Firewall stays on. Its notifications are turned off, and the PRIVATE
      profile stops blocking inbound connections, so games work on your home
      network without asking. Public and Domain keep blocking, so the machine
      is still shielded on a network you do not control.

  -Off
      Firewall off on every profile. Simplest, and closest to how a console
      behaves, since an Xbox has no user-facing firewall and relies on the
      router. It also removes the boundary between this machine and everything
      else on your LAN.

Note that "quiet" is not the same as "no firewall": outbound filtering, the
rules you already have and the Public profile all keep working.

  .\firewall-console.ps1
  .\firewall-console.ps1 -Off
  .\firewall-console.ps1 -Restore
#>
param(
    [switch]$Off,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

if ($Restore) {
    Write-Host 'Restoring Windows Firewall defaults...'
    Set-NetFirewallProfile -Profile Domain, Private, Public `
        -Enabled True -DefaultInboundAction Block -NotifyOnListen True -ErrorAction SilentlyContinue
    Write-Host 'Firewall on, inbound blocked, notifications back.'
    return
}

if ($Off) {
    Write-Host 'Turning Windows Firewall off on every profile...'
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False
    Write-Warning 'No inbound filtering at all now, including from other devices on your'
    Write-Warning 'network. Defensible for a console behind a home router; not for a laptop'
    Write-Warning 'that travels. Undo with: .\firewall-console.ps1 -Restore'
    return
}

# --- quiet: no prompts, no blocking on the home network ---------------------

Write-Host 'Firewall notifications off (that prompt is elevated, so a controller cannot answer it)...'
Set-NetFirewallProfile -Profile Domain, Private, Public -NotifyOnListen False

Write-Host 'Private profile: inbound allowed, so games do not have to ask...'
Set-NetFirewallProfile -Profile Private -DefaultInboundAction Allow

Write-Host 'Public and Domain: still blocking inbound'
Set-NetFirewallProfile -Profile Public, Domain -DefaultInboundAction Block

# Which profile is in force depends on how the current network is classified,
# and a console on a home LAN wants Private. Windows often lands on Public.
$profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
foreach ($p in $profiles) {
    if ($p.NetworkCategory -eq 'Public') {
        Write-Host ''
        Write-Host "  '$($p.Name)' is classified as a Public network, where inbound stays blocked." -ForegroundColor Yellow
        Write-Host '  On a home network that is worth changing, or none of the above applies:'
        Write-Host "    Set-NetConnectionProfile -Name '$($p.Name)' -NetworkCategory Private" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'Done. The firewall is still on: outbound filtering, your existing rules and' -ForegroundColor Green
Write-Host 'the Public profile all keep working. Undo with: .\firewall-console.ps1 -Restore' -ForegroundColor Green
