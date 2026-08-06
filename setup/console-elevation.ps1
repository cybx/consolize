#Requires -RunAsAdministrator
<#
Makes elevation answerable with a controller, which decides whether some games
can be launched at all from the couch.

The problem, in order:

  Games with kernel anticheat (Easy Anti-Cheat, BattlEye: Fortnite, Apex,
  Rainbow Six and friends) install a system service the first time they run,
  and that needs elevation.

  As a STANDARD user, Windows asks for an administrator's username and
  password. There is no way to type that with a gamepad, so the game simply
  never starts.

  As an ADMINISTRATOR, Windows asks only Yes or No, which is clickable. But it
  draws that prompt on the secure desktop, which deliberately ignores injected
  input, so Steam's mouse emulation cannot click it either.

So both halves are needed: the console account must be an administrator, and
the prompt must appear on the normal desktop.

What this costs, stated plainly: the account that runs games can elevate with a
click, and the prompt loses the secure desktop's protection against another
program clicking it for you. On a single-user machine in a living room that is
a reasonable trade. On a machine other people use, it is not.

  .\console-elevation.ps1 -UserName gamer
  .\console-elevation.ps1 -UserName gamer -Restore
#>
param(
    [Parameter(Mandatory)] [string]$UserName,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

if ($Restore) {
    Write-Host "Putting '$UserName' back to a standard account and restoring the secure desktop..."
    Remove-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction SilentlyContinue
    New-ItemProperty -Path $policies -Name 'PromptOnSecureDesktop' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host 'Done. Elevation prompts are back on the secure desktop.'
    Write-Host 'Anticheat games will need a keyboard the first time they run.'
    return
}

$isAdmin = (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*\$UserName" }) -ne $null

if ($isAdmin) {
    Write-Host "'$UserName' is already an administrator"
} else {
    Add-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction Stop
    Write-Host "'$UserName' added to Administrators"
    Write-Host '  so elevation asks Yes or No instead of for a password nobody can type'
}

# UAC itself stays on. Only the secure desktop goes, because that is the part
# that makes the prompt unclickable from a controller.
New-ItemProperty -Path $policies -Name 'PromptOnSecureDesktop' -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host 'Elevation prompts now appear on the normal desktop'
Write-Host '  reachable with the mouse emulation in Steam Input'

Write-Host ''
Write-Host 'Undo with: .\console-elevation.ps1 -UserName ' -NoNewline -ForegroundColor DarkGray
Write-Host "$UserName -Restore" -ForegroundColor DarkGray
