<p align="center">
  <img src="assets/logo-dark.png" alt="consolize" width="560">
</p>

# consolize

Turn a Windows 11 PC into a couch gaming console. The machine boots straight into Steam Big Picture (or Playnite Fullscreen), survives frontend crashes without ever showing a black screen or a desktop, and Explorer only appears when you explicitly ask for it.

Think SteamOS "Game Mode", but on Windows: every anticheat title works, no Proton tax, mature HDR/VRR support.

## Why not just use SteamOS or Bazzite?

If your library is 100% Proton-friendly, do use them. This project exists for the rest of us: Valorant/Vanguard, Fortnite, Destiny 2, EA anticheat titles and friends simply do not run on Linux.

## Why Windows 11 IoT Enterprise LTSC?

This project targets **Windows 11 Enterprise / Education / IoT Enterprise (LTSC included)** on purpose, instead of hacking Home/Pro:

- **Shell Launcher v2** is a native, Microsoft-supported kiosk feature of these editions. It replaces the shell per user and automatically restarts it if it exits or crashes. That is literally console behavior, with zero registry hacks and zero timing races.
- IoT Enterprise LTSC ships lean (no Widgets, Copilot, Teams or Store apps) and only receives quality updates. No feature update will ever break your living room.

## How it works

`consolize.exe` is a small .NET session manager that **is** the shell (via Shell Launcher) for a dedicated gamer account:

1. It launches the configured frontend (Steam Big Picture by default; Playnite Fullscreen, Hydra or any executable via config).
2. It watches the frontend and relaunches it if it crashes, with a crash-loop breaker that falls back to the desktop instead of flapping forever.
3. "Desktop mode" is on demand, the way SteamOS does it, and reachable without a keyboard:
   - **console to desktop:** a "Desktop Mode" entry sits in the Steam library, added automatically during setup. Pick it with the controller and Explorer starts.
   - **desktop to console:** the session manager shows a tray icon while the desktop is up (double-click it), and setup also drops a "Back to Console Mode" shortcut on the desktop.
   - a reboot always comes back to the console, so a session left in desktop mode is never a trap.
4. It exposes a named pipe (`ping`, `status`, `desktop`, `console`, `restart`, `sleep`, `panel`, `quit`) so scripts and future tooling can drive the session.

### Quick Settings

`consolize panel` opens a fullscreen panel built for a gamepad: d-pad or left
stick to move, A to select, B to close, LB and RB to change page. It is added to
the Steam library during setup, so it is reachable from the couch.

| Page | What it does |
|---|---|
| Sound | Switch output device (TV, headset, receiver) and set volume |
| Bluetooth | Scan, pair and forget devices without the Settings app |
| Network | Connect to a saved wifi network |
| Power | Back to console, desktop mode, restart frontend, sleep, restart, shut down |

`consolize panel --diag` prints what it can see (audio devices, Bluetooth radio,
XInput availability) without opening a window, which is the quick way to check a
machine.

No `Winlogon\Shell` registry rewrite, no scheduled task launching a VBS that launches a batch, no fixed 20-second sleeps.

## Status

| Phase | What | Status |
|---|---|---|
| F1 | Session manager (watchdog shell + desktop on demand) | **WIP, this repo** |
| F2 | Quiet layer (Game Bar off, DND, update discipline, autologon via LSA, boot UI) | **first pass in `setup/`** |
| F3 | Power: rest mode (sleep/hibernate profile, wake by controller, no core parking) | **first pass in `setup/`** |
| F4 | Controller-first quick settings (Bluetooth pairing, audio output, volume, wifi) without touching a desktop | **shipped** |
| F0 | Provisioning: gaming bootstrap (GPU driver, runtimes, updates) + `autounattend.xml` | **bootstrap in `setup/`**, autounattend pending |
| F5 | Remote maintenance (OpenSSH, second admin account, clean uninstall) | planned |

## Install

On the machine that will become the console:

```powershell
irm https://raw.githubusercontent.com/cybx/consolize/main/get.ps1 | iex
```

No need to open PowerShell as administrator: it asks for elevation itself and
continues in the elevated window.

The setup scripts are copied to the machine at install time, so a fix published
later does not reach it on its own. To pull the current ones without starting
over:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cybx/consolize/main/get.ps1))) -UpdateOnly
``` It installs `consolize.exe` plus every setup
script and then runs the whole provisioning, asking before each part.

You answer a short interview once. Everything after that is automatic, including
the reboot and the account switch it needs.

### Two accounts, and why

The account Windows was installed with keeps the normal desktop and stays your
way back in. A second account (`gamer` by default) is the only one whose shell
gets replaced.

The setup drives itself across that boundary, which it has to cross because
Windows keeps the Steam login per user and no administrator can sign in on
another account's behalf:

1. Everything machine-wide runs from your answers, then the machine reboots.
2. It logs into the console account by itself and a window finishes that
   account: per-user settings, then Steam, waiting for you to sign in with
   "Remember me" ticked. That is the one screen that needs you.
3. A SYSTEM task notices the account is ready, preflights, replaces the shell
   and reboots into console mode.

If the Steam sign-in never happens, step 3 refuses to replace the shell and says
why: booting into a login window a controller cannot fill in would strand you.
Cancel a setup in progress with `.\setup-console.ps1 -Abort`.

**If you end up looking at a black screen**, `Ctrl+Shift+Esc` opens Task Manager
over any shell. File > Run new task, tick "Create this task with administrative
privileges", and run:

```
powershell -ExecutionPolicy Bypass -File "C:\Program Files\Consolize\setup\rescue.ps1"
```

That gives back the logon screen, the desktop and the boot messages in one go,
and cancels anything still scheduled. The logon screen is only hidden at the very
end of a successful setup, precisely so a failure never hides the way back in.

Everything below is the manual/from-source path; each script also works alone.

## Quick start (bench testing, no shell replacement)

You can try the session manager inside a normal desktop session first:

```powershell
dotnet publish src/Consolize.SessionManager -c Release -r win-x64 -o out/publish
./out/publish/consolize.exe          # Steam Big Picture opens, watchdog active
Start-Process ./out/publish/consolize.exe -ArgumentList 'send status'  -NoNewWindow -Wait
Start-Process ./out/publish/consolize.exe -ArgumentList 'send desktop' -NoNewWindow -Wait
Start-Process ./out/publish/consolize.exe -ArgumentList 'send quit'    -NoNewWindow -Wait
```

`Start-Process -Wait` rather than a plain call on purpose: `consolize.exe` is a
GUI subsystem binary, so being the shell never flashes a console window, and
PowerShell does not wait for those. A plain `consolize send status` still prints,
it just arrives after your prompt comes back and cannot be captured into a
variable.

Config lives at `%LOCALAPPDATA%\Consolize\config.json` (created on first run,
with `%ProgramData%\Consolize\config.json` as the machine-wide fallback), logs at
`%LOCALAPPDATA%\Consolize\logs\`.

**Your own boot logo:** drop a `splash.png` next to either config and the
session manager shows it fullscreen while the frontend starts, closing the
moment the frontend draws its first window. Since `boot-silent.ps1` removes the
Windows logo, this is what the machine shows on the way up.

## Making it the real shell

> **Warning:** you are replacing the Windows shell for a user. Do this on a dedicated gamer account, keep a second admin account with the default shell, and read the scripts before running them. Tested target: Windows 11 IoT Enterprise LTSC 2024.

```powershell
# as admin, from the repo root, on the machine that will become the console
./setup/bootstrap-gaming.ps1              # updates, GPU driver, game runtimes, launchers, media players, tools; interactive with recommended defaults (installs winget itself if missing)
./setup/quiet-machine.ps1                 # nothing ever pops over a game, updates at 04:00, quiet boot
./setup/tune-defender.ps1                 # game folders excluded, idle-only scans (add -Disable to turn Defender off entirely)
./setup/tune-performance.ps1              # HAGS, MMCSS game profile, reserved storage (add -Aggressive to strip background services)
./setup/power-console.ps1                 # power button = rest mode, no password on wake, no core parking
./setup/clean-startup.ps1                 # nothing starts with Windows except the console itself (reversible)
./setup/boot-silent.ps1                   # no Windows logo, no welcome screen, no boot error dialogs

# log into Steam once with "Remember me" before the next step, then:
./setup/preflight.ps1 -UserName gamer     # catches the first-boot traps while a desktop is still there
./setup/set-autologon.ps1 -UserName gamer # autologon with the password stored as an LSA secret (never plaintext)
./setup/install.ps1                       # builds and installs consolize.exe
./setup/enable-shell-launcher.ps1 -UserName gamer

# once, inside the gamer session (no admin):
./setup/quiet-user.ps1                    # guide button goes to Steam, toasts off, tips off

# undo:
./setup/disable-shell-launcher.ps1 -UserName gamer
./setup/set-autologon.ps1 -UserName gamer -Remove
./setup/tune-defender.ps1 -Restore
```

See [docs/architecture.md](docs/architecture.md) for design decisions and the full roadmap.

## Credits

Idea inspired by [GamesDows](https://github.com/jazir555/GamesDows) by jazir555, which pioneered "boot Windows into Big Picture" with batch scripts. consolize is a from-scratch implementation (no code reused) built specifically around Shell Launcher v2.

## License

MIT
