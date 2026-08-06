# Lab runbook

End-to-end test of consolize in a throwaway VM, before touching real hardware.

## 0. Create the VM (host, admin PowerShell)

```powershell
.\New-TestVm.ps1 -IsoPath "$env:USERPROFILE\Downloads\<win11-iot-ltsc>.iso"
Start-VM consolize-lab; vmconnect.exe localhost consolize-lab
```

## 1. Install Windows

Either answer setup by hand, or drop `unattend/autounattend.xml` on a FAT32 USB
stick / small ISO attached as a second drive and let it run unattended (see
[../unattend/README.md](../unattend/README.md)).

Manual install notes:

- Press a key fast at "Press any key to boot from CD or DVD". Missed it? Just
  reset the VM.
- IoT Enterprise LTSC accepts a **local account** with no Microsoft account
  nagging. Create the user `gamer`.
- Create a second admin user too (`admin`), so you always have a way in if the
  custom shell misbehaves.

Freeze that state before changing anything:

```powershell
Checkpoint-VM -Name consolize-lab -SnapshotName clean-install
```

Reset to it at any time:

```powershell
Restore-VMSnapshot -VMName consolize-lab -Name clean-install -Confirm:$false
```

## 2. Get consolize into the VM

If the guest has internet, that is the whole step (admin PowerShell in the guest):

```powershell
irm https://raw.githubusercontent.com/cybx/consolize/main/get.ps1 | iex
```

Offline guest? Push the files from the host instead:

```powershell
.\Copy-ToVm.ps1
```

Builds and drops `consolize.exe` plus every `setup\*.ps1` into `C:\consolize`
in the guest. No SDK, git or internet needed inside the VM.

## 3. Provision (guest, admin PowerShell)

```powershell
cd 'C:\Program Files\Consolize\setup'   # or C:\consolize if you used Copy-ToVm
.\bootstrap-gaming.ps1               # winget bootstrap, runtimes, Steam, Defender choice
.\quiet-machine.ps1
.\set-autologon.ps1 -UserName gamer
.\enable-shell-launcher.ps1 -UserName gamer
```

The one-liner already put `consolize.exe` in `C:\Program Files\Consolize`, so
`install.ps1` (which needs the .NET SDK) is only for building from source.

In the `gamer` session, once: `.\quiet-user.ps1`.

## 4. What to verify after a reboot

| Check | Expected |
|---|---|
| Boot | No Windows logo, no lock screen, no logon animation, straight into the frontend |
| `consolize send status` | `mode=Console; frontend=running (pid N)` |
| Kill the frontend from Task Manager | It comes back within seconds (watchdog) |
| Kill it 3x in a row quickly | Explorer appears instead of a black screen (crash-loop breaker) |
| `consolize send desktop` | Explorer starts, taskbar appears |
| `consolize send console` | Explorer dies, back to the frontend only |
| Logs | `%LOCALAPPDATA%\Consolize\logs\session-<date>.log` explains every transition |

A VM has no GPU, so Steam Big Picture may refuse to render properly. To test the
session manager logic itself, point the frontend at anything: edit
`%LOCALAPPDATA%\Consolize\config.json` to

```json
{ "Frontend": "custom", "CustomCommand": "C:\\Windows\\System32\\notepad.exe" }
```

and the watchdog, crash-loop breaker and desktop toggle can all be exercised
without a GPU. Steam Big Picture itself is a bare-metal test.

## Watch out: Enhanced Session Mode lies to you here

Hyper-V's Enhanced Session Mode connects **over RDP**, and only administrators
and members of *Remote Desktop Users* may sign in that way. The console account
is an ordinary user, so an enhanced session shows a logon screen offering your
admin account and refuses the console account with:

> To sign in remotely, you need the right to sign in through Remote Desktop
> Services.

That looks exactly like autologon having failed, while the real console session
is sitting behind it, logged in and running perfectly. Two ways out:

```powershell
# see the real machine, which is what a TV would show
# (vmconnect: toggle off the enhanced session, or)
Set-VMHost -EnableEnhancedSessionMode $false

# or let the console account in over RDP too, a lab convenience only:
# on a real console this grants remote access to the account that plays games
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member gamer
```

Basic session is the honest view: it is the actual framebuffer. Enhanced session
buys clipboard and resolution, and costs you this confusion.

## 5. Escape hatches

If the custom shell leaves you stuck:

- `Ctrl+Shift+Esc` opens Task Manager over any shell, then File > Run new task >
  `explorer.exe`.
- Log in as the second admin account, which still has the default shell, and run
  `.\disable-shell-launcher.ps1 -UserName gamer`.
- In the lab, just `Restore-VMSnapshot`.
