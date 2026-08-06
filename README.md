<p align="center">
  <img src="assets/logo-dark.png" alt="consolize" width="560">
</p>

# consolize

Turn a Windows 11 PC into a couch gaming console. The machine boots straight into Steam Big Picture (or Playnite Fullscreen), survives frontend crashes without ever showing a black screen or a desktop, and Explorer only appears when you explicitly ask for it.

Think SteamOS "Game Mode", but on Windows.

## Why not just use SteamOS or Bazzite?

They are excellent, and if everything you play runs under Proton you should
probably use them: they do all of this natively and need no project like this
one to behave. Three reasons someone ends up here anyway.

**Anticheat.** The hard blocker, and the one no amount of tuning fixes.
Valorant, Fortnite, Destiny 2, most EA titles: kernel anticheat does not run on
Linux, and the games are not "slow" there, they simply refuse to start.

**Performance on current AMD hardware.** The old assumption that Linux matches
or beats Windows does not hold on RDNA 4 today. Aggregated testing on an RX 9070
XT puts Bazzite at [92% of Windows](https://en.gamegpu.com/news/zhelezo/sravnenie-proizvoditelnosti-rx-9070-xt-i-rtx-5080-v-windows-11-i-linux-v-2026-godu)
(127.9 against 138.6 FPS average), with CachyOS at 94%.

Be careful with that number, though. It is an average, and per title the picture
is genuinely mixed: on a 7900 XTX at 4K, SteamOS
[wins Cyberpunk 2077 and Spider-Man 2](https://www.notebookcheck.net/Cyberpunk-2077-and-Red-Dead-Redemption-2-tested-at-4K-Ultra-on-SteamOS-and-Windows-11-offering-a-snapshot-of-Linux-gaming-in-2026.1201785.0.html)
while Windows takes Forza Horizon 5 by a mile. GamersNexus, who ran the widest
RDNA 4 set,
[refuses to cross-compare their own numbers](https://gamersnexus.net/gpus/rip-windows-linux-gpu-gaming-benchmarks-bazzite)
across the two operating systems at all, and flags compatibility issues, crashes
and shader compilation stalls as the thing that actually shapes the experience.
So: a real edge on average with new AMD silicon, not a rout.

**Newest hardware, day one.** A GPU launches with a Windows driver. Linux
support arrives when the kernel and Mesa catch up, which is exactly the gap RDNA
4 spent most of its first year in.

### What you give up, honestly

Suspend and resume. SteamOS does it properly; Windows desktop does not, which is
why [`power-console.ps1`](setup/power-console.ps1) exists and why hibernate is
offered as the reliable fallback. And you need this project at all, whereas
SteamOS ships a console experience out of the box.

## Why Windows 11 IoT Enterprise LTSC?

Any edition works. LTSC is what this is developed and tested against, because it
ships lean (no Widgets, Copilot, Teams or Store apps) and only receives quality
updates, so no feature update will ever break your living room.

### How the shell is replaced

Two mechanisms, and the default is the one that keeps desktop mode working:

| | `-Method registry` (default) | `-Method shelllauncher` |
|---|---|---|
| What it does | Sets Winlogon's per-user `Shell` value in that account's hive | The Shell Launcher feature (`WESL_UserSetting`) |
| Editions | all, Home and Pro included | Enterprise, Education, IoT Enterprise |
| Restart on exit | Winlogon's `AutoRestartShell` | built in, with per-return-code actions |
| **Desktop mode** | **works**: no shell is registered, so launching `explorer.exe` makes it take over, taskbar and all | **does not**: Microsoft [states](https://learn.microsoft.com/en-us/answers/questions/5576492/) that explorer there opens a folder window, not a desktop |

consolize is its own watchdog and never exits on purpose, so Shell Launcher's
restart handling is worth less to it than being able to reach the desktop. The
session manager checks for the taskbar after starting explorer and says so in
the log when it does not appear, rather than leaving you looking at a folder.

## How it works

`consolize.exe` is a small .NET session manager that **is** the shell for a dedicated gamer account:

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
| Controllers | How many pads are connected, and which devices may wake the machine |
| Network | Connect to a saved wifi network |
| Power | Back to console, desktop mode, restart frontend, sleep, restart, shut down |

The Controllers page covers the setting that decides whether a button on the pad
turns the console back on. It used to live in Device Manager, which is precisely
where a controller cannot go. Note it only applies to **sleep**: nothing on USB
wakes a hibernated machine, so with `-RestMode Hibernate` it is the case button
or an HDMI-CEC adapter.

`consolize panel --diag` prints what it can see (audio devices, Bluetooth radio,
XInput availability) without opening a window, which is the quick way to check a
machine.

No `Winlogon\Shell` registry rewrite, no scheduled task launching a VBS that launches a batch, no fixed 20-second sleeps.

## Status

| Phase | What | Status |
|---|---|---|
| F1 | Session manager (watchdog shell + desktop on demand) | **shipped** |
| F2 | Quiet layer (Game Bar off, DND, update discipline, autologon via LSA, boot UI) | **first pass in `setup/`** |
| F3 | Power: rest mode (sleep/hibernate profile, wake by controller, no core parking) | **first pass in `setup/`** |
| F4 | Controller-first quick settings (Bluetooth pairing, audio output, volume, wifi) without touching a desktop | **shipped** |
| F0 | Provisioning: gaming bootstrap (GPU driver, runtimes, updates) + `autounattend.xml` | **bootstrap in `setup/`**, autounattend pending |
| F5 | Remote maintenance (OpenSSH, second admin account, clean uninstall) | uninstall and recovery done: `uninstall-console.ps1`, `rescue.ps1`. Remote access still open |

## Install

On the machine that will become the console:

```powershell
irm https://get-consolize.cybx.dev | iex
```

No need to open PowerShell as administrator: it asks for elevation itself and
continues in the elevated window.

That address is a Cloudflare Worker in front of this repository, reading through
the GitHub contents API so a fix published a minute ago is the one that runs;
`raw.githubusercontent.com` caches for minutes, which is long enough to run
yesterday's code by accident. Its source is [`cloudflare/worker.js`](cloudflare/worker.js).

The setup scripts are copied to the machine at install time, so a fix published
later does not reach it on its own. To pull the current ones without starting
over:

```powershell
& ([scriptblock]::Create((irm https://get-consolize.cybx.dev))) -UpdateOnly
``` It installs `consolize.exe` plus every setup
script and then runs the whole provisioning, asking before each part.

You answer a short interview once. Everything after that is automatic, including
the reboot and the account switch it needs.

### What the console account is allowed to do

It installs and plays games, pairs Bluetooth devices, joins wifi and switches
audio output without any of that needing elevation. One thing does: games with
kernel anticheat (Fortnite, Apex, Rainbow Six) install a system service the first
time they run.

That single case decides the account type, because Windows handles it in two
unhelpful ways. A standard account is asked for an administrator's **username
and password**, which cannot be typed with a gamepad. An administrator account is
asked only Yes or No, but the prompt is drawn on the secure desktop, which
ignores injected input by design, so Steam's mouse emulation cannot click it.

[`console-elevation.ps1`](setup/console-elevation.ps1) offers three answers, and
all of them make the console account an administrator, without which none of
them work:

| | what it does |
|---|---|
| `quiet` (default) | UAC on, but administrators elevate without being asked. Nothing prompts, and programs still start unprivileged. |
| `off` | UAC off entirely (`EnableLUA = 0`). Nothing prompts either, but everything runs elevated from the start, integrity levels included. |
| `prompt` | UAC on and still asking, moved off the secure desktop so an emulated mouse can answer. |

`quiet` is the default because it prompts exactly as never as `off` does, so the
sofa experience is identical, while programs still start unprivileged. A game
that goes wrong sits at medium integrity instead of having owned the machine
since it launched, and the sandboxes in the browser and in packaged apps, which
are built on integrity levels, keep working.

The trade, plainly: both `quiet` and `off` mean anything running as this account
can gain administrator rights without you being asked. Reasonable for one
person's console in a living room; not for a machine other people use. Setup
asks, and leaving Windows alone is one of the answers.

(`off` used to break Store and packaged apps. That was fixed in Windows 10 build
15063, so it no longer applies here.)

Everything else is covered up front rather than at runtime: the `runtimes` step
installs every VC++ generation, DirectX, .NET and the rest precisely so a game
never has to install a prerequisite mid-launch.

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

### Putting your own apps in the library

Steam can add a non-Steam game itself, but that takes a mouse and a file
browser, and a machine that boots into Big Picture has neither. From a terminal
in desktop mode:

```powershell
cd 'C:\Program Files\Consolize\setup'
.\add-app-shortcut.ps1 -Name 'RetroArch' -Exe 'C:\RetroArch\retroarch.exe'
.\add-app-shortcut.ps1 -List
```

It gets cover art and lands in the **Consolize** collection with the rest. The
list lives in `C:\ProgramData\Consolize\extra-shortcuts.json`, so it is
reapplied on every update rather than being a one-off.

Taking an app off the list does not remove it from the library: an entry that no
longer matches anything consolize knows about cannot be told apart from one you
added by hand. To clear them all: `add-console-shortcuts.ps1 -Remove -Force`,
then run it again without `-Remove`.

### YouTube on the television

`bootstrap-gaming.ps1` offers it, or on its own:

```powershell
.\install-youtube.ps1
```

The obvious route does not work, which is worth knowing before you try it.
YouTube's TV interface is a plain web app at `youtube.com/tv`, but Google blocks
browsers from it unless they identify as a console or a TV, and the user-agent
trick that gets past that gives you the interface without gamepad support: arrow
keys work, the controller does nothing. Most recipes for this online predate the
block.

So this installs [VacuumTube](https://github.com/shy1132/VacuumTube), which
wraps that same official interface in Electron, identifies as the YouTube TV app
and implements controller input itself. MIT, actively maintained, not on winget,
so it comes from its GitHub release. It gets a library entry like everything
else.

Sign in with **Settings > Link with TV code** rather than typing a password on a
television.

### Taking it back off

`rescue.ps1` is for a setup that went wrong, and only undoes what can hide the
screen. To remove consolize entirely:

```powershell
& 'C:\Program Files\Consolize\setup\uninstall-console.ps1'
```

It puts the shell back first, so a failure in any later step still leaves a
machine you can sign into, then restores Defender, the firewall, UAC, the power
plan, startup and the quiet layers, and removes the scheduled tasks, the Steam
library entries and the installed files. Add `-WhatIfOnly` to see the plan
without doing it.

The console account is **kept** unless you pass `-RemoveAccount`, because it
owns the Steam library, the saves and the screenshots. `-RemoveAccount
-DeleteProfile` takes those too.

Anything already back to normal is skipped, so running it twice is safe. What it
cannot recover is a setting that already had a non-default value before
consolize ran: those were overwritten without being recorded, and the script
says so rather than pretending otherwise.

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

**Coaxing a stubborn frontend:** `FrontendArgs` replaces the built-in arguments.
Big Picture is Chromium and wants a GPU, so on a machine without 3D acceleration
(a plain Hyper-V VM, for instance) it hangs or renders black until you turn that
off:

```json
{ "Frontend": "steam", "FrontendArgs": "-cef-disable-gpu -bigpicture" }
```

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

Idea inspired by [GamesDows](https://github.com/jazir555/GamesDows) by jazir555, which pioneered "boot Windows into Big Picture" with batch scripts. consolize is a from-scratch implementation, with no code reused.

## License

MIT
