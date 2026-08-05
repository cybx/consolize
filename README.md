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
3. "Desktop mode" is on demand: `consolize send desktop` starts Explorer, `consolize send console` kills it and returns to the frontend. Add these as non-Steam shortcuts and you can hop between modes from the couch.
4. It exposes a named pipe (`ping`, `status`, `desktop`, `console`, `restart`, `quit`) so scripts and future tooling can drive the session.

No `Winlogon\Shell` registry rewrite, no scheduled task launching a VBS that launches a batch, no fixed 20-second sleeps.

## Status

| Phase | What | Status |
|---|---|---|
| F1 | Session manager (watchdog shell + desktop on demand) | **WIP, this repo** |
| F2 | Quiet layer (Game Bar off, DND, update discipline, autologon via LSA, boot UI) | **first pass in `setup/`** |
| F3 | Power: rest mode (sleep/hibernate profile, wake by controller, no core parking) | **first pass in `setup/`** |
| F4 | Controller-first quick settings (Bluetooth pairing, audio output, volume, wifi) without touching a desktop | planned |
| F0 | Provisioning: gaming bootstrap (GPU driver, runtimes, updates) + `autounattend.xml` | **bootstrap in `setup/`**, autounattend pending |
| F5 | Remote maintenance (OpenSSH, second admin account, clean uninstall) | planned |

## Install

On the machine that will become the console:

```powershell
irm https://raw.githubusercontent.com/cybx/consolize/main/get.ps1 | iex
```

No need to open PowerShell as administrator: it asks for elevation itself and
continues in the elevated window. It installs `consolize.exe` plus every setup
script and then runs the whole provisioning, asking before each part.

### Two accounts, and why

The account Windows was installed with keeps the normal desktop and stays your
way back in. A second account (`gamer` by default) is the only one whose shell
gets replaced.

Setup runs in three phases, because Steam keeps its login per Windows user, so
an administrator cannot sign in on the console account's behalf:

1. **As admin:** apps, runtimes, quiet layer, power, startup, performance,
   autologon, and a one-shot task for the console account.
2. **As the console account:** log in once. A window opens by itself, applies
   the per-user settings and Steam so you can sign in with "Remember me".
3. **As admin again:** `.\setup-console.ps1 -EnableShell`, which preflights and
   only then replaces the shell.

Everything below is the manual/from-source path; each script also works alone.

## Quick start (bench testing, no shell replacement)

You can try the session manager inside a normal desktop session first:

```powershell
dotnet publish src/Consolize.SessionManager -c Release -r win-x64 -o out/publish
./out/publish/consolize.exe          # Steam Big Picture opens, watchdog active
./out/publish/consolize.exe send status
./out/publish/consolize.exe send desktop
./out/publish/consolize.exe send quit
```

Config lives at `%LOCALAPPDATA%\Consolize\config.json` (created on first run), logs at `%LOCALAPPDATA%\Consolize\logs\`.

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
