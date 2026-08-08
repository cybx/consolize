# consolize: architecture and roadmap

## Design decisions

1. **The session manager is the shell, not Steam.** Shell Launcher restarts *us* if we ever die; *we* watchdog the frontend. Putting Steam directly as the shell (the GamesDows approach, via `Winlogon\Shell`) means a Steam crash leaves a dead session, and "exit to desktop" needs registry flip-flopping with timed scripts. A tiny manager process kills the whole class of problems and gives us a place to hang future features (quick settings, startup sequencing, telemetry-free status).

2. **Explorer on demand, and what that costs.** When no shell is registered for
   the session, launching `explorer.exe` makes it take over as the shell,
   taskbar and desktop included; killing it returns to a pure console session.
   Explorer never starts unless asked, so there is no taskbar flash at boot.

   This is the reason the default shell mechanism is the per-user `Winlogon\Shell`
   registry value rather than the Shell Launcher feature. Microsoft
   [states](https://learn.microsoft.com/en-us/answers/questions/5576492/) that
   under Shell Launcher the system suppresses the shell components, so launching
   explorer there opens a File Explorer window and nothing more; reaching the
   desktop means switching the shell back and signing out. An earlier version of
   this document claimed the opposite, which was wrong.

   Because the answer depends on how the shell was replaced, the session manager
   does not assume: after starting explorer it waits for `Shell_TrayWnd` and logs
   plainly when the taskbar never appears.

3. **Editions.** The default mechanism, the per-user `Winlogon\Shell` value, works
   on every edition including Home and Pro. Shell Launcher, available on
   Enterprise, Education and IoT Enterprise, is offered as `-Method shelllauncher`
   for anyone who wants its restart handling and can live without desktop mode.
   Note it is Shell Launcher v1 (`WESL_UserSetting`, which hosts a Win32 shell
   through `eshell.exe`); v2 exists for UWP shells and is not what this uses.
   IoT Enterprise LTSC remains the edition this is developed against, for its
   leanness and its ten-year servicing, not because the shell needs it.

4. **Autologon via LSA secret, never plaintext.** The classic `DefaultPassword` registry value stores the password in cleartext. Sysinternals Autologon stores it as an LSA secret. F2 automates that.

5. **Defender: the owner decides, the script is honest about Tamper Protection.** `setup/tune-defender.ps1` defaults to tuning (exclusions for every Steam library parsed from `libraryfolders.vdf`, Playnite, Epic and DX/GL shader caches, plus idle-only scans at a 5% CPU cap and no scheduled scan), which is where nearly all the stutter lives. `-Disable` turns Defender off for real: real-time, behavior monitoring, on-access, cloud lookups, every Defender scheduled task, and the "your PC is unprotected" toast that would otherwise pop over a game.

   The part other scripts get wrong: since Windows 10 2004, Tamper Protection makes Defender **ignore** `DisableAntiSpyware` and `Set-MpPreference -DisableRealtimeMonitoring`, so those scripts report success and change nothing. There is no supported way to toggle Tamper Protection programmatically (that is the whole point of it), and the unsupported ways are malware techniques we will not ship. So `-Disable` opens the Windows Security page, waits for the one manual click, verifies `IsTamperProtected` flipped, applies the changes, then re-reads `Get-MpComputerStatus` and reports what actually stuck rather than assuming.

6. **Rest mode strategy.** Sleep is the default and is right on hardware that exposes real S3, including the Steam Deck, where the state machine is firmware driven and Windows is not meaningfully worse than SteamOS. The unreliable case is Modern Standby (S0ix): machines that fail to enter it, or wake for reasons nobody asked for. Hibernate is the fallback *for those machines*, and its cost has to be stated honestly rather than sold as equivalent. It is not a shutdown, RAM is serialised to disk and process state returns, but device and network state do not: a game can hit a [lost D3D device](https://learn.microsoft.com/en-us/windows/uwp/gaming/handling-device-lost-scenarios) on resume, an online session was dropped by the server long ago, and some anticheat modules dislike the gap. So it survives a power cut; it does not reliably return you to the middle of a match. Known trade on top of that: the 8BitDo 2.4G receiver can wake the PC from *sleep* (enable "Allow this device to wake the computer" on the receiver), but nothing wakes from *hibernate* via USB; that is the case power button or an HDMI-CEC adapter.

## Requirements learned from the field (GamesDows issue tracker)

- **Bluetooth pairing without a desktop** (GamesDows #43): pairing controllers/headsets currently requires disabling everything and rebooting twice. Solves in F4.
- **Sleep/resume breakage on handhelds** (GamesDows #27): power management must be part of the product, not an afterthought. F3.
- **Taskbar flash at boot**: designed out by decision 2.
- **Guide button conflict**: long-pressing the Xbox button opens Game Bar *over* Big Picture; Game Bar must be neutered so Steam owns the button. F2.
- **Startup companions** (Decky-style overlays, GamesDows #41): the session manager can sequence them after the frontend is up.

## Phases

- **F1 (this repo, WIP): session manager.** Watchdog + crash-loop breaker + named-pipe control (`ping|status|desktop|console|restart|quit`) + frontend autodetect (Steam registry, Playnite, custom).
- **F2: quiet layer.** Idempotent PowerShell: Game Bar off, Do Not Disturb always on, Windows Update discipline (nightly window, never auto-reboot), lock screen and boot UI off, LSA autologon. First pass shipped: `setup/quiet-machine.ps1`, `setup/quiet-user.ps1`, `setup/set-autologon.ps1`, `setup/tune-defender.ps1`.
- **F3: power.** First pass shipped as `setup/power-console.ps1`: power/sleep button mapped to the chosen rest mode, no password on wake, screen-off timeout without a sleep timeout (so movies and downloads are never cut short), wake timers off, USB selective suspend off so wireless receivers stay responsive, fast startup off (the usual suspect behind "it rebooted instead of resuming", which is what GamesDows #27 looks like), and Ultimate/High Performance to stop core parking. Still to do: a maintenance window that wakes the box at night to pull Steam updates the way a console does.
- **F4: controller-first quick settings.** Gamepad-navigable mini app for Bluetooth pairing, audio output switching, volume and wifi, launchable from inside Big Picture (non-Steam shortcut that talks to the consolize pipe). This is the piece nobody has built for Windows.
- **F0: provisioning.** `autounattend.xml` for IoT Enterprise LTSC: local account, drivers, Steam, consolize, quiet layer, all from first boot. The repo becomes "the ISO recipe for your console". The app/driver layer already exists as `setup/bootstrap-gaming.ps1`: GPU vendor autodetect (NVIDIA/AMD/Intel), VC++ runtimes, DirectX runtime, Steam/Playnite and Windows updates, interactive with recommended defaults or `-Preset` for automation.
- **F5: remote maintenance.** First pass shipped as `setup/remote-console.ps1`: OpenSSH Server with PowerShell as the login shell (commands from another machine, the way a Linux box does it), and Remote Desktop with NLA plus session shadowing, which is the difference between opening *a* session and seeing *the* session that is on the television. Both are scoped to the Domain/Private firewall profiles, and `consolize send` now finds the console session's pipe from an SSH session (the pipe name carries a session id, and SSH logons get their own), so `consolize send desktop` works remotely. The second admin account was already the way in — setup-console warns when none exists — and `uninstall-console.ps1` closes both doors.

## First-boot traps (why `preflight.ps1` exists)

Replacing the shell turns small problems into unrecoverable ones, because the
desktop you would fix them from is gone. The checks worth running while it is
still there:

- **Steam with no saved login.** `steam.exe -bigpicture` does *not* open Big
  Picture when there are no cached credentials: it opens the small desktop
  login window. With no Explorer and a controller in hand, that is a dead end.
  Preflight parses `config/loginusers.vdf` for `RememberPassword "1"` and fails
  hard if it is missing. Steam Guard on a brand new machine is the same trap one
  step later, so launch Steam once and clear the code before flipping the shell.
- **Steam autostarting on its own.** consolize launches the frontend; a leftover
  Run entry means two Steams racing at logon. `clean-startup.ps1` always removes
  Steam entries for that reason.
- **No way back in.** A second admin account with the default shell is the
  cheapest insurance; without it the only escape is Ctrl+Shift+Esc into Task
  Manager and running `explorer.exe` by hand.
- **Cleartext autologon password.** If some other tool wrote `DefaultPassword`,
  preflight fails and points at `set-autologon.ps1`, which stores it as an LSA
  secret instead.
- **Wrong Windows edition.** No Shell Launcher on Home/Pro, so the whole plan
  changes.

`enable-shell-launcher.ps1` runs preflight first and refuses to continue on any
blocking issue unless `-SkipPreflight` is passed.

## What is actually proven, and what is not

Kept honest on purpose. A README that says "shipped" for everything is not much
use to someone deciding whether to point this at their own machine, and the
difference between "the tests pass" and "this was seen working on a television"
is the whole difference here.

**Proven on real hardware or a VM:**

- The installer, the interview and the provisioning, end to end
- Account creation, autologon with the password as an LSA secret
- The Steam library entries: they appear, they carry their artwork, they land in
  the Consolize collection, and launching one runs the target. Checked against a
  live Steam install, not only against the tests
- Edge in `--app` mode with a fresh profile, which is where its welcome flow
  would otherwise take the screen
- 61 automated checks over the shortcuts writer, plus static checks over every
  script in the repository

**Not proven yet, and said so rather than assumed:**

1. **Shell replacement by the per-user registry method.** The mechanism is
   documented and the script writes what it should, but a machine has not yet
   been seen booting into the frontend this way.
2. **The empty-screen watcher.** Leaving Big Picture should bring the desktop up
   within `DesktopWhenNothingFillsScreenSeconds`; that path has not been watched
   on a real session.
3. **`quiet` elevation letting kernel anticheat install.** The reasoning is in
   the README and it follows from how UAC works, but no anticheat has actually
   been installed from the console account to confirm it.
4. **`send desktop` from the library entry.** Reported as not working reliably
   on a test VM whose library had duplicate entries; the duplicate question has
   to be settled first, with `scripts/dump-shortcuts.ps1`, before that is a bug
   in the handler rather than a click on the wrong entry.

## Test lab

**Why not Docker:** Windows containers have no interactive logon session, no GUI and no Shell Launcher; a shell replacement cannot be exercised inside one. The disposable-environment instinct is right, though; the tool that delivers it on a Windows host is **Hyper-V with checkpoints**:

1. `testlab/New-TestVm.ps1 -IsoPath <IoT LTSC iso>` creates a Gen 2 VM (Secure Boot + vTPM) from the ISO.
2. Install Windows in the VM (IoT LTSC accepts a local account offline), snapshot as `clean-install`.
3. Test `install.ps1` + `enable-shell-launcher.ps1` inside the VM; `Restore-VMSnapshot` resets the lab in seconds when something breaks.

`dockur/windows` (Windows inside QEMU/KVM inside a Linux container) may become useful later for CI on Linux runners, but locally Hyper-V is native, faster and checkpoint-friendly.

## Performance tuning: what we do and what we refuse to do

`setup/tune-performance.ps1` only implements settings with a documented
mechanism: hardware-accelerated GPU scheduling, the MMCSS `Games` profile
(`SystemResponsiveness`, GPU priority, scheduling category), Game Mode, reserved
storage off, and a pagefile sanity check. `-Aggressive` additionally disables
Search indexing, SysMain and DiagTrack, and turns memory compression off *only*
at 32 GB or more, because at 16 GB that trade goes the wrong way.

Popular tweaks it deliberately refuses, because they hurt or measure as noise:
`bcdedit useplatformclock` and `disabledynamictick` (breaks the modern timer and
power management, and is a common cause of the stutter it promises to fix),
disabling the pagefile (crashes engines that commit large address spaces),
forcing timer resolution, Nagle/TcpAckFrequency edits, blanket debloat scripts
that break Windows Update, and disabling SSD "defrag" scheduling, which is
actually the TRIM job.

The honest framing: firmware settings (Resizable BAR, XMP/EXPO, the GPU in the
CPU-attached x16 slot) outweigh every registry tweak on this list combined, and
the biggest software win by far is the Defender and startup work, not scheduler
constants.

## Branding the boot

Three separate images show up between the power button and the game, owned by
three different layers:

1. **Firmware logo** (motherboard or laptop vendor). Replaceable only through
   the vendor's own BIOS tooling, if it has any. Not scriptable.
2. **Windows boot logo**, drawn from the UEFI BGRT table. `boot-silent.ps1`
   removes it. Replacing it instead of removing it means [HackBGRT], which is an
   EFI application, so it needs Secure Boot off or a signed shim. Consider that
   a deliberate trade, not a default.
3. **The gap between logon and the frontend's first frame**, which is ours. The
   session manager shows a fullscreen splash there, closing as soon as the
   frontend puts a window on screen or after `SplashSeconds`. Drop a
   `splash.png` next to the config (`%ProgramData%\Consolize\` or
   `%LOCALAPPDATA%\Consolize\`) and it is picked up automatically.

Layer 3 is where a project logo belongs: no Secure Boot trade, no firmware
dependency, and it covers exactly the seconds that would otherwise be black.

[HackBGRT]: https://github.com/Metabolix/HackBGRT

## Static checks

`scripts/check-scripts.ps1` catches the failure modes that only surface at run
time, which in a provisioning tool means they surface on the user's machine,
halfway through:

- **Parameter / local variable collisions.** PowerShell variable names are case
  insensitive, so a local `$items` *is* the `[string[]]$Items` parameter, and the
  type constraint silently coerces an `OrderedDictionary` into a one element
  `String[]`. This broke `bootstrap-gaming.ps1` mid-run with an error pointing at
  a line that looked perfectly fine.
- **A bare `+` inside a command call**, which PowerShell parses as extra
  positional arguments rather than concatenation. This broke `preflight.ps1`
  exactly when autologon was unconfigured, the normal case on a fresh machine.
- **Calls between scripts passing parameters the target does not declare**, which
  is how a renamed or removed parameter turns into a stale instruction.
- Parse errors and functions used before definition.

It walks the AST rather than the text, so `Write-Host '.\foo.ps1 -Restore'
-ForegroundColor Red` is correctly read as a `Write-Host` call and not as
`foo.ps1` receiving a `-ForegroundColor` parameter.

```powershell
pwsh -File scripts/check-scripts.ps1
```

## Non-goals

- Firmware/OEM boot logo replacement (BIOS territory).
- Xbox-style Quick Resume of several suspended titles (no OS support exists).
- Home/Pro support in v1.
