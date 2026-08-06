#Requires -RunAsAdministrator
<#
Decides how elevation behaves on a machine that is operated with a gamepad.

Why it needs deciding at all: games with kernel anticheat (Easy Anti-Cheat,
BattlEye: Fortnite, Apex, Rainbow Six) install a system service the first time
they run, and that needs elevation. Out of the box, Windows handles it in two
ways that are both dead ends from a sofa. A standard account is asked for an
administrator's username and password, which no gamepad can type. An
administrator account is asked only Yes or No, but the prompt is drawn on the
secure desktop, which ignores injected input by design, so Steam's mouse
emulation cannot click it either.

Whichever mode is chosen, the account is made an administrator, because none of
this works without that.

  -Mode quiet   (default) UAC stays on, but administrators elevate without
                being asked (ConsentPromptBehaviorAdmin = 0). Nothing ever
                prompts, and yet programs still start unprivileged and only
                gain rights when something actually asks for them. Same
                convenience as turning UAC off, far smaller blast radius, which
                is why it is the default.

  -Mode off     UAC off entirely: EnableLUA = 0. Nothing ever asks either, but
                everything the account runs is elevated from the moment it
                starts, Steam and games included, and with it go integrity
                levels (what the browser and packaged-app sandboxes are built
                on) and registry and file virtualisation.
                Needs a restart to take effect.

  -Mode prompt  UAC stays on and still asks, but on the normal desktop rather
                than the secure one, so a controller-driven mouse can answer.
                The most conservative of the three that still works from a sofa.

  -Restore      Windows defaults, and the account back to standard.

The trade, plainly: off and quiet both mean anything running as this account can
gain administrator rights without you being asked. On one person's console in a
living room that is a reasonable thing to choose. On a machine other people use,
it is not.

Between those two, quiet is strictly the better deal. Both prompt exactly never,
so the sofa experience is identical; the difference is only how much is running
elevated while nothing has gone wrong. Under quiet a compromised game sits at
medium integrity and cannot touch the system. Under off it was already at high
integrity from the moment it launched.
#>
param(
    [Parameter(Mandatory)] [string]$UserName,
    [ValidateSet('off', 'quiet', 'prompt')] [string]$Mode = 'quiet',
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'

$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

function Set-Policy {
    param([string]$Name, [int]$Value)
    New-ItemProperty -Path $policies -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    Write-Host "  $Name = $Value"
}

if ($Restore) {
    Write-Host "Restoring Windows defaults and putting '$UserName' back to a standard account..."
    Set-Policy 'EnableLUA' 1
    Set-Policy 'ConsentPromptBehaviorAdmin' 5
    Set-Policy 'PromptOnSecureDesktop' 1
    Remove-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host 'Done. Restart to apply. Anticheat games will need a keyboard the first time.'
    return
}

# Every mode needs this: without it Windows asks for a password instead of a
# yes, and no gamepad can type one.
if (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*\$UserName" }) {
    Write-Host "'$UserName' is already an administrator"
} else {
    Add-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction Stop
    Write-Host "'$UserName' added to Administrators"
}

switch ($Mode) {
    'off' {
        Write-Host ''
        Write-Host 'UAC off: nothing will ask for elevation again.'
        Set-Policy 'EnableLUA' 0
        Write-Host ''
        Write-Host '  Everything this account runs will be elevated from the moment it starts,' -ForegroundColor Yellow
        Write-Host '  Steam and games included, and integrity levels go with it, which is what' -ForegroundColor Yellow
        Write-Host '  the browser and packaged-app sandboxes are built on.' -ForegroundColor Yellow
        Write-Host '  -Mode quiet prompts just as never and keeps all of that.' -ForegroundColor Yellow
        Write-Host '  Takes effect after a restart.' -ForegroundColor Yellow
    }

    'quiet' {
        Write-Host ''
        Write-Host 'UAC on, but administrators elevate without being asked.'
        Set-Policy 'EnableLUA' 1
        Set-Policy 'ConsentPromptBehaviorAdmin' 0
        Set-Policy 'PromptOnSecureDesktop' 0
        Write-Host ''
        Write-Host '  Nothing prompts, and programs still start unprivileged: a game that goes' -ForegroundColor DarkGray
        Write-Host '  wrong is stuck at medium integrity instead of owning the machine.' -ForegroundColor DarkGray
    }

    'prompt' {
        Write-Host ''
        Write-Host 'UAC on and still asking, but where a controller can answer.'
        Set-Policy 'EnableLUA' 1
        Set-Policy 'ConsentPromptBehaviorAdmin' 5
        Set-Policy 'PromptOnSecureDesktop' 0
        Write-Host ''
        Write-Host '  The prompt moves off the secure desktop, which is what made it' -ForegroundColor DarkGray
        Write-Host '  unclickable with an emulated mouse.' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host "Undo with: .\console-elevation.ps1 -UserName $UserName -Restore" -ForegroundColor DarkGray
