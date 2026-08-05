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

1. It launches the configured frontend (Steam Big Picture by default, Playnite or anything else via config).
2. It watches the frontend and relaunches it if it crashes, with a crash-loop breaker that falls back to the desktop instead of flapping forever.
3. "Desktop mode" is on demand: `consolize send desktop` starts Explorer, `consolize send console` kills it and returns to the frontend. Add these as non-Steam shortcuts and you can hop between modes from the couch.
4. It exposes a named pipe (`ping`, `status`, `desktop`, `console`, `restart`, `quit`) so scripts and future tooling can drive the session.

No `Winlogon\Shell` registry rewrite, no scheduled task launching a VBS that launches a batch, no fixed 20-second sleeps.

## Status

| Phase | What | Status |
|---|---|---|
| F1 | Session manager (watchdog shell + desktop on demand) | **WIP, this repo** |
| F2 | Quiet layer (Game Bar off, DND, update discipline, autologon via LSA, boot UI) | planned |
| F3 | Power: rest mode (sleep/hibernate profile, wake by controller, nightly maintenance window) | planned |
| F4 | Controller-first quick settings (Bluetooth pairing, audio output, volume, wifi) without touching a desktop | planned |
| F0 | Provisioning: `autounattend.xml` that installs a ready-to-play machine from first boot | planned |
| F5 | Remote maintenance (OpenSSH, second admin account, clean uninstall) | planned |

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
# as admin, from the repo root
./setup/install.ps1
./setup/enable-shell-launcher.ps1 -UserName gamer
# undo:
./setup/disable-shell-launcher.ps1 -UserName gamer
```

See [docs/architecture.md](docs/architecture.md) for design decisions and the full roadmap.

## Credits

Idea inspired by [GamesDows](https://github.com/jazir555/GamesDows) by jazir555, which pioneered "boot Windows into Big Picture" with batch scripts. consolize is a from-scratch implementation (no code reused) built specifically around Shell Launcher v2.

## License

MIT
