<p align="center">
  <img src="assets/logo-dark.png" alt="consolize" width="560">
</p>

<p align="center">
  <strong>A controller-first Windows gaming console that still has a desktop when you need one.</strong>
</p>

<p align="center">
  <a href="https://github.com/cybx/consolize/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/cybx/consolize/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/cybx/consolize/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/cybx/consolize?display_name=tag"></a>
  <img alt="Windows 11" src="https://img.shields.io/badge/Windows-11-0078D4?logo=windows11&logoColor=white">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-green.svg"></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.pt-BR.md">Português</a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#what-the-installer-asks-you">Options</a> ·
  <a href="#what-it-changes-on-your-machine">What it changes</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#quick-settings">Quick Settings</a> ·
  <a href="#a-media-centre-too">Media</a> ·
  <a href="#taking-it-back-off">Uninstall</a> ·
  <a href="docs/architecture.md">Architecture</a>
</p>

# Turn Windows into a console

consolize turns a dedicated Windows 11 PC into a couch gaming console. It boots
straight into Steam Big Picture or Playnite Fullscreen, recovers when the
frontend crashes, and keeps the Windows desktop one controller-friendly action
away.

Think SteamOS Game Mode, for the games and hardware that need Windows.

```powershell
irm https://get-consolize.cybx.dev | iex
```

The guided installer elevates itself, asks what you want once, provisions the
machine, creates a dedicated console account and carries the setup across the
required reboots.

> [!WARNING]
> **This is for a machine you are willing to dedicate to it, not your daily
> driver and not a work PC.**
>
> The shell is only replaced for a second account it creates, so the account you
> use now keeps its normal desktop. But the setup also changes the machine as a
> whole: Defender, UAC, the firewall, the power plan and the boot screen. Setup
> asks about each of those and "leave it alone" is always one of the answers, and
> [`uninstall-console.ps1`](setup/uninstall-console.ps1) puts them back, but you
> should know that before running the line above, not after.
>
> The full list, with what each one costs and the script that reverses it, is in
> [what it changes on your machine](#what-it-changes-on-your-machine).
>
> Use a spare drive or a VM if you have one. If you do not, take a system image
> first. That advice applies to any project that replaces the Windows shell,
> this one included.

## What you get

| | |
|---|---|
| **Console boot** | Automatic sign-in directly to Steam Big Picture or Playnite Fullscreen, with no desktop flash |
| **Self-healing frontend** | A watchdog restarts a crashed frontend and falls back to the desktop instead of leaving a black screen |
| **Desktop on demand** | Enter from the Steam library; return through the tray icon or desktop shortcut; reboot always returns to console mode |
| **Gamepad Quick Settings** | Audio output and volume, Bluetooth pairing, controller wake, wifi and power controls |
| **Console-style Windows** | Quiet notifications, controlled updates, silent boot, gaming runtimes, power tuning and optional startup cleanup |
| **SteaMidra integration** | Optionally installs the latest upstream Windows build and adds it to Steam automatically |
| **Safe way back** | A separate administrator keeps its ordinary desktop; rescue and uninstall scripts restore the Windows experience |

## What the installer asks you

One interview, then it runs unattended across the reboots. Every answer has a
default, so Enter all the way through is a working console.

| | Options | Default |
|---|---|---|
| Console account name and password | any name; the password is never left blank | `gamer` |
| Steam language, keyboard layout | any Steam language; layout is asked separately and never guessed from the language | english, current layout |
| Launchers | Steam, Playnite, Hydra, or all | Steam |
| Which one boots | steam / playnite / hydra | steam |
| Windows updates | everything / security only / skip | everything |
| Software | runtimes, GPU app, media players, Java, Git and 7-Zip, qBittorrent | the recommended set |
| Media centre | Kodi, Jellyfin, Plex, Stremio, and streaming sites | kodi, jellyfin |
| Defender | tune / disable entirely / leave alone | tune |
| Power button | sleep / hibernate | sleep |
| Elevation | quiet / off / prompt | quiet |
| Firewall | quiet / off / leave alone | quiet |

The only step that needs you afterwards is signing in to Steam, inside the
console account, because Windows keeps that login per user and no administrator
can do it on another account's behalf.

## What it changes on your machine

This replaces the Windows shell for one account and changes machine-wide
settings, some of which reduce security. All of it is listed here rather than
discovered later, and all of it is reversible with
[`uninstall-console.ps1`](setup/uninstall-console.ps1).

**The shell and the session**

| Change | Why | Undo |
|---|---|---|
| The console account's `Winlogon\Shell` becomes `consolize.exe` | that account boots into the frontend instead of Explorer | `disable-shell-launcher.ps1` |
| Autologon, password stored as an LSA secret | a console does not ask who you are | `set-autologon.ps1 -Remove` |
| Windows logo, boot animation, error screens and boot menu timeout off | a console does not show you Windows on the way up | `boot-silent.ps1 -Restore` |
| Sign-in screen hidden (only at the very end of a successful setup) | so a failure never hides the way back in | `rescue.ps1` |

**Quiet**

| Change | Why | Undo |
|---|---|---|
| Game Bar and Game DVR off, machine and user | the guide button belongs to Steam | `quiet-machine.ps1 -Restore` |
| Notification toasts, tips, "finish setting up your device" off | nothing pops over a game | `quiet-user.ps1 -Restore` |
| Lock screen, screen saver and startup sound off | a console never interrupts what is on screen | same |
| Windows Update: installs at 04:00, never reboots under a session | it will not restart mid-film | `quiet-machine.ps1 -Restore` |
| Touch keyboard auto-opens on text fields | there is no keyboard on the sofa | `quiet-user.ps1 -Restore` |
| Desktop background becomes the console splash | the default picture breaks the illusion | same, though the old picture is not recorded |
| Startup items removed (Run, RunOnce, Startup folders, logon tasks) | optional, backed up first, Windows' own entries untouched | `clean-startup.ps1 -Restore` |

**Performance and power**

| Change | Why | Undo |
|---|---|---|
| Hardware-accelerated GPU scheduling on, MMCSS tuned for games | measurable, and reversible | `tune-performance.ps1 -Restore` |
| Reserved storage off (about 7 GB back) | space on a console SSD | same |
| `-Aggressive` also disables Search, SysMain and DiagTrack | opt-in only | same |
| Power button sleeps or hibernates, no password on wake, no core parking, screen never blanked | a television handles blanking; blanking drops HDMI | `power-console.ps1 -Restore`, which records the previous scheme first |

It deliberately does **not** do the things most "optimisation" scripts do:
`bcdedit useplatformclock`, disabling the pagefile, forcing timer resolution,
Nagle edits, blanket debloat, disabling SSD defrag scheduling. Each of those
either does nothing or causes the stutter it claims to fix, and the script says
so on screen.

**Security, and this is the part to read twice**

| Change | What you lose | Undo |
|---|---|---|
| Defender: game folders excluded, scans only when idle | very little | `tune-defender.ps1 -Restore` |
| Defender **disabled entirely**, if you choose it | real-time protection, and it needs you to switch off Tamper Protection by hand | same |
| UAC `quiet`: administrators elevate without a prompt | anything running as the console account can gain administrator rights without asking you | `console-elevation.ps1 -Restore` |
| UAC `off`: `EnableLUA = 0` | the above, plus everything runs elevated from the start, integrity levels included | same |
| Firewall: inbound allowed on the private profile, notifications off | games stop asking, and so does Windows | `firewall-console.ps1 -Restore` |

Reasonable for one person's console in a living room. Not for a machine other
people use, and not for the only account of a work machine. Leaving Windows
alone is one of the answers to every one of these questions.

## Before you install

This project replaces the Windows shell **for one dedicated account** and makes
machine-wide system changes. Use it on a gaming PC, handheld or test VM, not on
the only account of a work machine. Keep a second administrator account as the
recovery path.

Windows 11 IoT Enterprise LTSC 2024 is the primary tested target. Home, Pro,
Education and regular Enterprise can use the default registry shell method;
some optional provisioning features vary by edition. A keyboard is still useful
for the initial Windows and Steam sign-ins, even though everyday operation is
designed for a controller.

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

Suspend and resume, with a caveat that matters. The problem is not sleep as
such: on hardware that exposes real S3, sleep works fine and it is what
[`power-console.ps1`](setup/power-console.ps1) defaults to. The pain is Modern
Standby (S0ix), which is most new laptops and handhelds, where Windows drops
into it unreliably and wakes for reasons nobody asked for. On a Steam Deck,
where S3 is firmware driven, Windows is not meaningfully worse than SteamOS
here.

Hibernate is offered for the machines where sleep is not trustworthy, and it is
worth being honest about what it costs. It is not a shutdown: RAM is serialised
to disk and process state comes back. But device and network state do not. A
game can hit a lost D3D device on resume, an online session was dropped by the
server long ago, and some anticheat modules dislike the gap. So hibernate is
the option that survives a power cut, not the one that returns you to the middle
of a match.

And you need this project at all, whereas SteamOS ships a console experience out
of the box.

## Why Windows 11 IoT Enterprise LTSC?

Any edition works. LTSC is what this is developed and tested against, because it
ships lean (no Widgets, Copilot, Teams or Store apps) and only receives quality
updates, so no feature update will ever break your living room.

### Getting hold of it

Worth saying plainly, because it is the first wall people hit: **IoT Enterprise
LTSC is not sold at retail.** There is no boxed copy and no store page. It is
licensed per device through Microsoft's authorised IoT distributors (Arrow,
Avnet, Advantech and similar) or through volume licensing.

Two honest routes:

- **Trying it:** Microsoft publishes a free
  [90-day evaluation](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-iot-enterprise-ltsc)
  of Windows 11 IoT Enterprise LTSC. That is enough to build the machine, run
  consolize and decide whether the whole idea is for you.
- **Keeping it:** an authorised IoT distributor for a single device licence, or
  volume licensing if you already have an agreement.

If you obtain an ISO from any third party, compare its SHA-256 with
[Microsoft's published hash list](https://cdn-dynmedia-1.microsoft.com/is/content/microsoftcorp/microsoft/final/en-us/microsoft-brand/documents/Windows11IoTEnterpriseLTSC2024EvalHashValues.pdf)
before booting it. Consolize does not endorse modified images or unauthorised
activation; the evaluation above is the safe way to test before buying a licence.

And the part that saves most people the trouble: **you do not need LTSC.** The
default shell method is a per-user registry value that works on Home and Pro
just as well. What LTSC buys you is a leaner install and no feature updates, not
a working console. If you already have Windows 11 on the machine, use it.

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
| Audio | Switch output device (TV, headset, receiver) and set volume |
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

### The way out of anything: **hold Start + Back**

Steam's overlay is what normally gives a non-Steam entry a way back, and it does
not hook Electron applications or a browser window. So inside YouTube, Kodi or a
streaming site the guide button does nothing, a window with no decorations has
nothing to close, and a sofa has no keyboard. Before this the only way out was
the power button.

The session manager is the shell and is always running, so it is the only thing
that can watch for a chord no matter what holds the foreground. **Start and Back
held together for a second** opens Quick Settings over whatever is on screen,
and its Power page goes back to the console.

It only reads XInput; it never injects or swallows input, so a game receives
exactly the buttons it always did. The hold is what stops it firing mid-play,
and `PanelChordSeconds` in `config.json` changes the delay or, at `0`, switches
it off.

What it is not: a scheduled task launching a VBS that launches a batch, or a
chain of fixed 20-second sleeps hoping the frontend is up by then. The one
registry value it does write is the per-user `Winlogon\Shell` above, which is
the documented way to give an account a different shell, and
[`disable-shell-launcher.ps1`](setup/disable-shell-launcher.ps1) takes it back.

## Status

| Phase | What | Status |
|---|---|---|
| F1 | Session manager (watchdog shell + desktop on demand) | **shipped** |
| F2 | Quiet layer (Game Bar off, DND, update discipline, autologon via LSA, boot UI) | **shipped**, and reversible with `-Restore` |
| F3 | Power: rest mode (sleep/hibernate profile, wake by controller, no core parking) | **shipped**; `-Restore` records the previous scheme before changing it |
| F4 | Controller-first quick settings (Bluetooth pairing, audio output, volume, wifi) without touching a desktop | **shipped** |
| F0 | Provisioning: gaming bootstrap (GPU driver, runtimes, updates) + `autounattend.xml` | **bootstrap shipped**, autounattend pending |
| F5 | Remote maintenance (OpenSSH, second admin account, clean uninstall) | uninstall and rescue **shipped**; remote access still open |
| F6 | Media: your own apps in the library, YouTube, and a media centre | **shipped** |

Verified on hardware so far: everything up to the shell replacement. Four things
are still only proven in a VM or not at all, and they are listed honestly in
[docs/architecture.md](docs/architecture.md) rather than assumed here.

## Install

On the machine that will become the console:

```powershell
irm https://get-consolize.cybx.dev | iex
```

No need to open PowerShell as administrator: it asks for elevation itself and
continues in the elevated window. Setup disables QuickEdit, so clicking inside
that window does not silently pause the installer.

That address is a Cloudflare Worker in front of this repository, reading through
the GitHub contents API so a fix published a minute ago is the one that runs;
`raw.githubusercontent.com` caches for minutes, which is long enough to run
yesterday's code by accident. Its source is [`cloudflare/worker.js`](cloudflare/worker.js).

It installs `consolize.exe` plus every setup script, then runs the whole
provisioning, asking before each part. You answer a short interview once;
everything after that is automatic, including the reboot and the account switch
it needs.

The setup scripts are copied to the machine at install time, so a fix published
later does not reach it on its own. To pull the current ones without starting
over:

```powershell
& ([scriptblock]::Create((irm https://get-consolize.cybx.dev))) -UpdateOnly
```

From the console itself there is an **Update consolize** entry in the Steam
library, which does the same thing plus winget upgrades and offers the restart.

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

On the first reboot, Windows may show the blue PowerShell window with no text
briefly while `powershell.exe` cold-starts and the new user profile settles. No
script can draw before that process is ready. As soon as phase 2 begins it now
prints `consolize: starting the first-logon setup...` and keeps all subsequent
work in that same window; it no longer closes it and relaunches another
PowerShell that looks blank. QuickEdit is disabled directly in the live console
through the Windows console API, as well as in the account's saved console
settings, so an accidental click cannot freeze this phase either.

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
list lives in `C:\ProgramData\Consolize\shared\extra-shortcuts.json`, so it is
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
so its portable x64 archive comes from the upstream GitHub release, has its
published SHA-256 digest verified, and is extracted machine-wide under
`C:\Program Files\VacuumTube`. It gets a library entry like everything else.

Sign in with **Settings > Link with TV code** rather than typing a password on a
television.

### SteaMidra

The software interview offers [SteaMidra](https://github.com/Midrags/SFF) as an
optional integration. Consolize resolves its latest upstream GitHub release at
install time, downloads the Windows ZIP, extracts it with 7-Zip to
`C:\Program Files\SteaMidra`, and adds **SteaMidra** to Steam as a non-Steam
app. That library entry goes through Windows' elevation broker because SteaMidra
requires administrator rights. With the default `quiet` elevation mode it opens
without a prompt; `prompt` shows a controller-friendly Yes/No dialog. Steam
keeps the entry marked as running until SteaMidra closes. Run or update it on
its own with:

```powershell
.\install-steamidra.ps1
```

### A media centre too

`bootstrap-gaming.ps1` offers it, or on its own:

```powershell
.\install-htpc.ps1
.\install-htpc.ps1 -Apps kodi,jellyfin -Services netflix,primevideo
```

Two kinds of thing, and they behave differently:

**Players** (Kodi, Jellyfin Media Player, Plex HTPC, Stremio) are real
applications. Kodi reads a gamepad natively, so it is the one that actually
feels like a console, and it has add-ons for Jellyfin and Plex if you would
rather have one front door.

**Streaming services** (Netflix, Prime Video, Disney+, Max, Globoplay,
Crunchyroll) have no native Windows application any more. Netflix's "app" in the
Microsoft Store has been an Edge web app since 2024, so on LTSC, which has no
Store, nothing is lost by opening the site in Edge directly with `--app`: a
window with no tabs, no address bar and no back button over the film, each
service on its own profile so they stay signed in separately.

Edge and not Chrome or Firefox, deliberately. Netflix serves 1080p and 4K only
to browsers that can use PlayReady, which on Windows means Edge (Chrome gained
it recently on Windows 11, Firefox is still capped at 720p). Getting 720p on a
television because of the browser would be a strange way to lose.

The catch, said plainly: **a web app does not read a gamepad.** Set Steam's
Settings > Controller > Desktop layout to one with right-stick mouse, and bind a
chord to the on-screen keyboard for signing in. The native players do not need
any of that.

### Taking it back off

`rescue.ps1` is for a setup that went wrong, and only undoes what can hide the
screen. To remove consolize entirely:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\Consolize\setup\uninstall-console.ps1"
```

Run that from an **administrator** PowerShell. The `-ExecutionPolicy Bypass` is
not superstition: Windows refuses unsigned scripts by default, and reports it as
"cannot be loaded because it is not digitally signed", which is a confusing
thing to be told about a file in Program Files. The installer unblocks what it
writes, so `& '...\uninstall-console.ps1'` works too on a machine set to
`RemoteSigned`, but the line above works everywhere and is the one to use if the
other is refused.

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

# optional, any time after setup:
./setup/add-app-shortcut.ps1 -Name 'RetroArch' -Exe 'C:\RetroArch\retroarch.exe'
./setup/install-youtube.ps1                # YouTube's TV interface, gamepad driven
./setup/install-htpc.ps1                   # Kodi, Jellyfin, Plex, and the streaming sites

# undo, all of it at once:
./setup/uninstall-console.ps1              # add -WhatIfOnly to see the plan first
```

Each piece still undoes itself alone (`disable-shell-launcher.ps1`,
`set-autologon.ps1 -Remove`, `tune-defender.ps1 -Restore`, and `-Restore` on the
rest), which is what `uninstall-console.ps1` calls in the order that keeps the
machine signable-into at every step.

See [docs/architecture.md](docs/architecture.md) for design decisions and the full roadmap.

## Credits

consolize stands on ideas and software from the wider Windows and couch-gaming
community:

- [GamesDows](https://github.com/jazir555/GamesDows) by
  [jazir555](https://github.com/jazir555) pioneered the idea of booting Windows
  directly into Steam Big Picture or Playnite as a console experience. consolize
  is a from-scratch implementation and reuses no GamesDows code.
- [SteaMidra](https://github.com/Midrags/SFF), made by Midrag and his brother, is
  available as an optional third-party integration. Consolize downloads its
  official release and creates the Steam library entry; SteaMidra remains its
  own GPL-3.0 project with its own documentation and terms.
- [VacuumTube](https://github.com/shy1132/VacuumTube) by
  [shy1132](https://github.com/shy1132) provides the optional controller-aware
  YouTube TV experience installed by `install-youtube.ps1`.
- Thanks to everyone reporting hardware quirks, testing clean Windows installs
  and contributing fixes. Issues and pull requests are welcome.

Steam and SteamOS are trademarks of Valve Corporation. Windows is a trademark
of Microsoft Corporation. consolize is an independent project and is not
affiliated with or endorsed by Valve, Microsoft, GamesDows, SteaMidra or
VacuumTube.

## License

[MIT](LICENSE) © 2026 Victor Corrêa.
