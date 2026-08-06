# Follow-up audit — 2026-08-06

This pass started from clean-install failures reported from a Windows 11 IoT
LTSC VM, then reviewed every provisioning boundary again: nested PowerShell
calls, administrator/user transitions, localization, restore paths, release
downloads and the long-running session manager.

All items below were fixed in the `v0.11.0` development line. The earlier
[adversarial audit](audit-2026-08.md) remains the record of the first pass.

| Area | Failure found | Resolution |
|---|---|---|
| Nested scripts | `preflight.ps1` and `install-steam.ps1` used `exit` while called in-process, terminating their parent and silently skipping the rest of setup | Added explicit `-NoExit` contracts and a repository check that rejects unsafe embedded calls |
| winget bootstrap | An alias to the repaired `winget.exe` could pass the executable path as winget's first command — the exact `Unrecognized command: '...winget.exe'` seen in the VM | Resolve and invoke the application path directly |
| Guided HTPC setup | YouTube and HTPC existed in the bootstrap catalog but were unreachable from `setup-console.ps1` | Added guided selections, persisted answers and exact forwarding to the bootstrap |
| HTPC account scope | Per-user apps could install in the provisioning administrator's profile; forcing machine scope rejects Kodi and Stremio's current manifests | Install Kodi/Jellyfin/Plex in the machine phase, then Stremio and Edge shortcuts inside the real console profile |
| YouTube | VacuumTube's per-user installer could land in the administrator's profile | Use its portable x64 archive, verify SHA-256 and extract machine-wide |
| Non-Steam state | Tightening the privileged ProgramData ACL also made the old `extra-shortcuts.json` unwritable by the console account | Move it to the narrowly writable `shared` directory and retain legacy-file migration |
| SteaMidra | Its Steam entry launched without the administrator token SteaMidra requires | Route the entry through a protected `RunAs` launcher which waits for SteaMidra to close |
| Desktop Mode | The watchdog could fight Explorer, duplicate managers could race, and any folder-only `explorer.exe` was mistaken for a working desktop | Pause relaunch in desktop mode, enforce one manager per user/session, minimize the frontend, require a real taskbar and replace incomplete Explorer instances |
| First-logon retry | A completed per-user marker plus a reset shared marker made a rerun wait for an hour | Recreate the shared ready marker on a completed account |
| Account-local settings | Language, keyboard, Game Mode and qBittorrent paths were written to the administrator profile or to a guessed profile directory | Apply them during first logon in the actual account; never pre-create `C:\Users\<name>` |
| Startup cleanup | Machine-only cleanup still disabled third-party logon tasks belonging to the administrator | Limit that phase to boot triggers; clean the console account's HKCU in its own session |
| Power restore | Setup mutated the owner's plan, parsed localized labels and could leave hibernation/fast-startup state behind | Duplicate a private plan, record the original GUID and exact hibernation state, verify activation, and delete only the private plan on restore |
| Boot restore | Boot entry and timeout parsing depended on English labels; missing state guessed a 30-second timeout | Identify loaders and GUIDs structurally; leave unknown timeout state untouched |
| Localized Windows | Built-in group names and `netsh` output broke outside English Windows | Resolve well-known groups by SID and use `wlanapi.dll` for Wi-Fi profiles |
| Autologon | Removal stored an empty LSA secret instead of deleting it; generated accounts could use their public username as password | Delete the secret through LSA, clear identity values and generate a strong random password |
| Shell restore | Uninstall could remove an unrelated custom shell or sweep every enabled user | Save/restore the previous per-user shell and target only accounts identified by setup state |
| Bluetooth | Numeric-comparison pairing was accepted automatically, defeating its verification step | Require an explicit matching-number confirmation |
| Session transport | A global pipe and duplicate shell processes could cross-talk or race | Use a current-user, per-session pipe plus a SID/session mutex |
| Versioning | The executable reported a hard-coded old version and releases did not derive metadata from the tag | Read assembly metadata, build from the tag and smoke-test `--version` in CI |
| Release integrity | The installer trusted a downloaded executable without checking the release asset digest | Verify GitHub's SHA-256 digest, publish a checksum sidecar and refuse provisioning without a usable binary |
| Windows Backup prompts | IoT LTSC could still surface Windows Backup suggestions | Apply the supported backup policy and monitoring opt-out; restore removes both values |

## Verification gate

Before release, the branch must pass:

- parser and cross-script contract checks in PowerShell 7 and Windows
  PowerShell 5.1;
- complete isolated `shortcuts.vdf` round trips in both engines;
- a self-contained .NET publish with warnings treated as errors;
- CLI/version metadata smoke tests;
- mocked `RunAs` launcher tests in both PowerShell engines;
- release workflow success and presence of both the executable and checksum
  assets.

External behavior was checked against primary documentation for
[Windows Backup policy](https://learn.microsoft.com/windows/configuration/windows-backup/),
[well-known security identifiers](https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers),
[winget install scope](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/install.md),
and [GitHub release asset digests](https://docs.github.com/rest/releases/assets).
