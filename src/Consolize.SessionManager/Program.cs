using System.Diagnostics;
using System.Drawing;
using System.IO.Pipes;
using System.Text.Json;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Consolize.SessionManager;

internal enum SessionMode
{
    Console,
    Desktop,
}

internal sealed record AppConfig
{
    /// <summary>steam | playnite | hydra | custom</summary>
    public string Frontend { get; init; } = "steam";

    /// <summary>Full path of the frontend executable when Frontend = "custom".</summary>
    public string? CustomCommand { get; init; }

    public string? CustomArgs { get; init; }

    /// <summary>Replaces the built-in arguments for steam/playnite/hydra. Useful
    /// when the frontend needs coaxing on a given machine, for example
    /// "-cef-disable-gpu -bigpicture" where Big Picture cannot use a GPU.</summary>
    public string? FrontendArgs { get; init; }

    /// <summary>Console behavior: closing the frontend brings it right back.
    /// The desktop is reached explicitly via `consolize send desktop`.</summary>
    public bool RelaunchOnCleanExit { get; init; } = true;

    public int MaxCrashesInWindow { get; init; } = 3;

    public int CrashWindowSeconds { get; init; } = 120;

    /// <summary>Crash-loop breaker: after MaxCrashesInWindow, start Explorer instead
    /// of flapping forever, then retry the frontend later.</summary>
    public bool FallbackToDesktopAfterMaxCrashes { get; init; } = true;

    public int RelaunchDelaySeconds { get; init; } = 3;

    /// <summary>Fullscreen image shown while the frontend starts. Defaults to
    /// splash.png next to the config, if one is there.</summary>
    public string? SplashImage { get; init; }

    public bool SplashEnabled { get; init; } = true;

    /// <summary>Leaving Big Picture without closing Steam leaves a windowed
    /// client over nothing, since no desktop is running behind it. When nothing
    /// fills the screen for this long, bring the desktop up. 0 disables it.</summary>
    public int DesktopWhenNothingFillsScreenSeconds { get; init; } = 20;

    /// <summary>Upper bound: the splash also closes as soon as the frontend
    /// puts a window on screen.</summary>
    public int SplashSeconds { get; init; } = 12;
}

internal static class Program
{
    private const string PipeName = "consolize";

    private static readonly string DataDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Consolize");

    private static readonly string LogDir = Path.Combine(DataDir, "logs");
    private static readonly string ConfigPath = Path.Combine(DataDir, "config.json");

    /// <summary>Machine-wide fallback, so provisioning can set the frontend before
    /// the console account has ever logged in (and thus has no profile yet).</summary>
    private static readonly string MachineConfigPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Consolize", "config.json");

    private static readonly object Sync = new();
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    private static readonly CancellationTokenSource Cts = new();

    private static AppConfig _config = new();
    private static Process? _frontend;
    private static volatile SessionMode _mode = SessionMode.Console;
    private static volatile bool _resumeConsoleRequested;

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    private const uint AttachParentProcess = 0xFFFFFFFF;

    /// <summary>
    /// This is a WinExe, so it has no console and Console.Out is a sink: every
    /// diagnostic printed nothing, which matters most when the desktop is gone
    /// and a terminal is all there is. Borrow the caller's console for the
    /// command line paths.
    /// </summary>
    /// <summary>True when there is a console to print to. Launched from a
    /// shortcut there is none, so failures have to be shown, not printed.</summary>
    private static bool _consoleAttached;

    private static void AttachToCallerConsole()
    {
        try
        {
            // When the caller already captures our output (a pipe, a file, `&`
            // in PowerShell), the standard handles are valid and writing works
            // as it is: attaching and reopening would only get in the way.
            if (Console.IsOutputRedirected) { _consoleAttached = true; return; }

            if (!AttachConsole(AttachParentProcess)) return;
            _consoleAttached = true;
            var stdout = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
            Console.SetOut(stdout);
            var stderr = new StreamWriter(Console.OpenStandardError()) { AutoFlush = true };
            Console.SetError(stderr);
        }
        catch
        {
            // no console to attach to (launched from Explorer or as the shell)
        }
    }

    private static int Main(string[] args)
    {
        if (args.Length >= 1) AttachToCallerConsole();

        if (args.Length >= 2 && args[0].Equals("send", StringComparison.OrdinalIgnoreCase))
            return SendCommand(args[1]);

        if (args.Length >= 1 && (args[0] == "--version" || args[0] == "-v"))
        {
            Console.WriteLine("consolize 0.6.0");
            return 0;
        }

        if (args.Length >= 1 && args[0].Equals("panel", StringComparison.OrdinalIgnoreCase))
        {
            if (args.Length >= 2 && args[1] == "--diag") return PanelDiagnostics();

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new QuickSettingsForm());
            return 0;
        }

        try
        {
            RunSession();
            return 0;
        }
        catch (Exception ex)
        {
            // Returning here would end the process that IS the shell, and Shell
            // Launcher would restart it into the same failure. Give the user a
            // desktop instead and stay alive.
            Log($"FATAL: {ex}");
            try
            {
                EnterDesktop();
                Log("fell back to the desktop; the session manager stays up so you have a way in");
                Cts.Token.WaitHandle.WaitOne();
            }
            catch (Exception inner)
            {
                Log($"could not even fall back to the desktop: {inner.Message}");
            }
            return 1;
        }
    }

    // ----- client mode ------------------------------------------------------

    private static int SendCommand(string command)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
            client.Connect(3000);
            var writer = new StreamWriter(client) { AutoFlush = true };
            var reader = new StreamReader(client);
            writer.WriteLine(command);
            Console.WriteLine(reader.ReadLine() ?? "(no response)");
            return 0;
        }
        catch (Exception ex)
        {
            var message =
                $"consolize could not reach the console session manager.\n\n{ex.Message}\n\n" +
                "This shortcut talks to the process that runs as the console shell. " +
                "On an ordinary Windows desktop that process is not running, so there is " +
                "no console session to switch back to.\n\n" +
                "It works once the console account has had its shell replaced.";

            Console.Error.WriteLine(message);

            // Launched from a shortcut there is no console, so the message above
            // goes nowhere and the shortcut looks like it did nothing at all.
            if (!_consoleAttached)
            {
                try
                {
                    MessageBox.Show(message, "consolize", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch { /* nothing left to try */ }
            }
            return 1;
        }
    }

    /// <summary>Prints what the panel can see, so the interop can be checked
    /// from a terminal without opening a window.</summary>
    private static int PanelDiagnostics()
    {
        Console.WriteLine("=== audio outputs ===");
        var outputs = Interop.Audio.GetOutputs();
        foreach (var device in outputs)
        {
            Console.WriteLine($"  {(device.IsDefault ? "*" : " ")} {device.Name}");
        }
        Console.WriteLine($"  ({outputs.Count} found)");
        Console.WriteLine($"  volume: {Interop.Audio.GetVolume()?.ToString() ?? "unavailable"}   muted: {Interop.Audio.GetMute()?.ToString() ?? "unknown"}");

        Console.WriteLine();
        Console.WriteLine("=== bluetooth ===");
        Console.WriteLine($"  radio present: {Interop.Bluetooth.RadioPresent()}");
        var devices = Interop.Bluetooth.GetDevices(scan: false);
        foreach (var device in devices)
        {
            var state = device.Connected ? "connected" : device.Authenticated ? "paired" : "known";
            Console.WriteLine($"  {device.Name} [{state}] {Interop.Bluetooth.FormatAddress(device.Address)}");
        }
        Console.WriteLine($"  ({devices.Count} remembered)");

        Console.WriteLine();
        Console.WriteLine("=== gamepad ===");
        var pad = new Interop.Gamepad();
        pad.Poll();
        Console.WriteLine($"  XInput available: {Interop.Gamepad.Available}");
        Console.WriteLine($"  connected now: {Interop.Gamepad.ConnectedCount()}");

        Console.WriteLine();
        Console.WriteLine("=== may wake the machine ===");
        foreach (var line in RunForDiagnostics("powercfg.exe", "/devicequery wake_armed"))
        {
            Console.WriteLine($"  armed: {line}");
        }
        var programmable = RunForDiagnostics("powercfg.exe", "/devicequery wake_programmable").Count;
        Console.WriteLine($"  ({programmable} device(s) could be allowed to)");

        return 0;
    }

    private static List<string> RunForDiagnostics(string file, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments)
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (process is null) return new List<string>();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(15000);
            return output.Split('\n')
                .Select(l => l.Trim())
                .Where(l => l.Length > 0 && !l.StartsWith("NONE", StringComparison.OrdinalIgnoreCase))
                .ToList();
        }
        catch (Exception)
        {
            return new List<string>();
        }
    }

    private static void OpenPanel()
    {
        try
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "panel")
            {
                UseShellExecute = false,
            });
            Log("quick settings panel opened");
        }
        catch (Exception ex)
        {
            Log($"could not open the panel: {ex.Message}");
        }
    }

    // ----- session manager --------------------------------------------------

    private static void RunSession()
    {
        Directory.CreateDirectory(LogDir);
        _config = LoadOrCreateConfig();
        Log($"session manager starting (pid {Environment.ProcessId}, frontend '{_config.Frontend}')");

        _ = Task.Run(() => PipeServerLoop(Cts.Token));
        _ = Task.Run(() => EmptyScreenLoop(Cts.Token));
        WatchdogLoop(Cts.Token);
        Log("session manager exiting");
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr param);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr param);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    /// <summary>Is any visible window covering the screen? In console mode
    /// something always should be: the frontend, or a game.</summary>
    private static bool SomethingFillsTheScreen()
    {
        var screenWidth = GetSystemMetrics(0);
        var screenHeight = GetSystemMetrics(1);
        if (screenWidth == 0 || screenHeight == 0) return true;   // no display; do not act

        var covered = false;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window)) return true;
            if (!GetWindowRect(window, out var rect)) return true;

            var width = rect.Right - rect.Left;
            var height = rect.Bottom - rect.Top;
            if (width >= screenWidth * 0.9 && height >= screenHeight * 0.9)
            {
                covered = true;
                return false;   // stop enumerating
            }
            return true;
        }, IntPtr.Zero);

        return covered;
    }

    /// <summary>
    /// Leaving Big Picture does not close Steam: it leaves a windowed client on
    /// top of nothing, because no desktop is running behind it. That reads as a
    /// black screen with a stray window in it, and there is no way out with a
    /// controller. Treat it as a request for the desktop.
    /// </summary>
    private static void EmptyScreenLoop(CancellationToken ct)
    {
        var threshold = _config.DesktopWhenNothingFillsScreenSeconds;
        if (threshold <= 0) return;

        var emptyFor = 0;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                SleepCancellable(ct, TimeSpan.FromSeconds(2));
                if (ct.IsCancellationRequested) return;

                // Only in console mode: on the desktop, windowed is normal.
                if (_mode != SessionMode.Console || ExplorerRunningInThisSession())
                {
                    emptyFor = 0;
                    continue;
                }

                if (SomethingFillsTheScreen())
                {
                    emptyFor = 0;
                    continue;
                }

                emptyFor += 2;
                if (emptyFor >= threshold)
                {
                    Log($"nothing has filled the screen for {emptyFor}s (Big Picture closed?), opening the desktop");
                    EnterDesktop();
                    emptyFor = 0;
                }
            }
            catch (Exception ex)
            {
                Log($"empty-screen watcher failed (ignored): {ex.Message}");
                emptyFor = 0;
            }
        }
    }

    private static AppConfig LoadOrCreateConfig()
    {
        // User config wins; machine config is what provisioning writes.
        foreach (var path in new[] { ConfigPath, MachineConfigPath })
        {
            try
            {
                if (!File.Exists(path)) continue;
                var loaded = JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(path), JsonOpts);
                if (loaded is null) continue;
                Log($"config loaded from {path}");
                return loaded;
            }
            catch (Exception ex)
            {
                Log($"could not read config at {path}: {ex.Message}");
            }
        }

        try
        {
            var config = new AppConfig();
            Directory.CreateDirectory(DataDir);
            File.WriteAllText(ConfigPath, JsonSerializer.Serialize(config, JsonOpts));
            Log($"default config written to {ConfigPath}");
            return config;
        }
        catch (Exception ex)
        {
            Log($"config error, using defaults: {ex.Message}");
            return new AppConfig();
        }
    }

    private static void WatchdogLoop(CancellationToken ct)
    {
        var crashes = new Queue<DateTime>();

        while (!ct.IsCancellationRequested)
        {
            // This process IS the shell. An escaping exception ends it, and
            // whatever restarts the shell (Winlogon's AutoRestartShell, or
            // Shell Launcher) brings it back into the same throw:
            // a black screen in a restart loop. Nothing in here may propagate.
            try
            {
                WatchdogIteration(ct, crashes);
            }
            catch (Exception ex)
            {
                Log($"watchdog iteration failed, staying alive: {ex}");
                EnterDesktop();
                SleepCancellable(ct, TimeSpan.FromSeconds(30));
            }
        }
    }

    private static void WatchdogIteration(CancellationToken ct, Queue<DateTime> crashes)
    {
        var frontend = ResolveFrontend();
        if (frontend is null)
        {
            Log("no frontend found (is Steam/Playnite installed?), falling back to desktop");
            EnterDesktop();
            IdleUntilConsoleRequested(ct, TimeSpan.FromSeconds(30));
            return;
        }

        var (exe, arguments) = frontend.Value;
        Process proc;
        var startedAt = DateTime.UtcNow;
        try
        {
            proc = Process.Start(new ProcessStartInfo
            {
                FileName = exe,
                Arguments = arguments,
                WorkingDirectory = Path.GetDirectoryName(exe) ?? Environment.SystemDirectory,
                UseShellExecute = false,
            }) ?? throw new InvalidOperationException("Process.Start returned null");
        }
        catch (Exception ex)
        {
            Log($"failed to start frontend '{exe}': {ex.Message}");
            SleepCancellable(ct, TimeSpan.FromSeconds(_config.RelaunchDelaySeconds));
            return;
        }

        lock (Sync) _frontend = proc;
        Log($"frontend started: {exe} {arguments} (pid {proc.Id})");
        ShowSplash(proc);

        try { proc.WaitForExit(); } catch { /* killed externally */ }

        int exitCode;
        try { exitCode = proc.ExitCode; } catch { exitCode = -1; }
        var ranFor = DateTime.UtcNow - startedAt;
        lock (Sync) _frontend = null;
        Log($"frontend exited with code {exitCode} after {ranFor.TotalSeconds:F1}s");

        if (ct.IsCancellationRequested) return;

        // steam.exe -bigpicture hands off to an already running client and
        // returns 0 within a second or two; Steam also re-execs itself after a
        // self-update. Relaunching then would loop forever over a perfectly
        // healthy frontend, so adopt the process that is actually running.
        if (exitCode == 0 && ranFor < TimeSpan.FromSeconds(15))
        {
            var adopted = FindRunningFrontend(exe);
            if (adopted is not null)
            {
                lock (Sync) _frontend = adopted;
                Log($"frontend handed off to pid {adopted.Id}, watching that instead");
                try { adopted.WaitForExit(); } catch { /* gone */ }
                lock (Sync) _frontend = null;
                Log("adopted frontend exited");
                if (ct.IsCancellationRequested) return;
                SleepCancellable(ct, TimeSpan.FromSeconds(_config.RelaunchDelaySeconds));
                return;
            }
        }

        if (exitCode == 0 && ranFor > TimeSpan.FromSeconds(15) && !_config.RelaunchOnCleanExit)
        {
            Log("clean exit and RelaunchOnCleanExit=false, entering desktop");
            EnterDesktop();
            IdleUntilConsoleRequested(ct, TimeSpan.FromSeconds(5));
            return;
        }

        // Count anything that dies almost immediately, whatever it returns:
        // a frontend that exits 0 in half a second is failing, not finishing,
        // and only counting non-zero exits meant the breaker could never fire.
        if (exitCode != 0 || ranFor < TimeSpan.FromSeconds(15))
        {
            var now = DateTime.UtcNow;
            crashes.Enqueue(now);
            while (crashes.Count > 0 && (now - crashes.Peek()).TotalSeconds > _config.CrashWindowSeconds)
                crashes.Dequeue();

            if (crashes.Count >= _config.MaxCrashesInWindow)
            {
                Log($"frontend failed {crashes.Count}x within {_config.CrashWindowSeconds}s, breaking the loop");
                crashes.Clear();
                if (_config.FallbackToDesktopAfterMaxCrashes)
                {
                    EnterDesktop();
                    IdleUntilConsoleRequested(ct, TimeSpan.FromSeconds(60));
                    return;
                }
            }
        }

        SleepCancellable(ct, TimeSpan.FromSeconds(_config.RelaunchDelaySeconds));
    }

    /// <summary>
    /// After a launcher hands off to an existing instance, finds the process
    /// actually running the frontend in this session.
    /// </summary>
    private static Process? FindRunningFrontend(string exePath)
    {
        var name = Path.GetFileNameWithoutExtension(exePath);
        var session = Process.GetCurrentProcess().SessionId;
        Process? best = null;

        foreach (var candidate in Process.GetProcessesByName(name))
        {
            try
            {
                if (candidate.SessionId == session && !candidate.HasExited)
                {
                    if (best is null) { best = candidate; continue; }
                    // keep the oldest: that is the client the launcher joined
                    if (candidate.StartTime < best.StartTime) { best.Dispose(); best = candidate; continue; }
                }
                candidate.Dispose();
            }
            catch
            {
                try { candidate.Dispose(); } catch { }
            }
        }

        return best;
    }

    private static (string Exe, string Args)? ResolveFrontend()
    {
        var resolved = ResolveFrontendCore();
        if (resolved is null) return null;

        // An explicit override wins over the built-in arguments.
        return string.IsNullOrWhiteSpace(_config.FrontendArgs)
            ? resolved
            : (resolved.Value.Exe, _config.FrontendArgs!);
    }

    private static (string Exe, string Args)? ResolveFrontendCore()
    {
        switch (_config.Frontend.ToLowerInvariant())
        {
            case "steam":
            {
                var path = FindSteamExe();
                return path is null ? null : (path, "-bigpicture");
            }
            case "playnite":
            {
                var path = FindApp("Playnite", "Playnite.FullscreenApp.exe",
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "Playnite", "Playnite.FullscreenApp.exe"));
                return path is null ? null : (path, "");
            }
            case "hydra":
            {
                var path = FindApp("Hydra", "Hydra.exe",
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "Programs", "Hydra", "Hydra.exe"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                        "Hydra", "Hydra.exe"));
                return path is null ? null : (path, "");
            }
            case "custom":
                return _config.CustomCommand is { Length: > 0 } cmd && File.Exists(cmd)
                    ? (cmd, _config.CustomArgs ?? "")
                    : null;
            default:
                Log($"unknown frontend '{_config.Frontend}'");
                return null;
        }
    }

    /// <summary>
    /// Locates an installed app: the given fallback paths first, then the uninstall
    /// registry (InstallLocation / DisplayIcon), which is where per-user installers
    /// like Electron apps end up regardless of the folder they chose.
    /// </summary>
    private static string? FindApp(string displayNameFragment, string exeName, params string[] candidates)
    {
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate)) return candidate;
        }

        foreach (var (hive, subKey) in new[]
        {
            (Registry.CurrentUser, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
        })
        {
            using var root = hive.OpenSubKey(subKey);
            if (root is null) continue;

            foreach (var name in root.GetSubKeyNames())
            {
                // A single ACL'd subkey would otherwise throw out of the shell
                // process itself, and Shell Launcher would restart it straight
                // back into the same exception.
                try
                {
                    using var app = root.OpenSubKey(name);
                    var displayName = app?.GetValue("DisplayName") as string;
                    if (displayName is null || !displayName.Contains(displayNameFragment, StringComparison.OrdinalIgnoreCase))
                        continue;

                    if (app!.GetValue("InstallLocation") as string is { Length: > 0 } location)
                    {
                        var exe = Path.Combine(location, exeName);
                        if (File.Exists(exe)) return exe;
                    }

                    if (app.GetValue("DisplayIcon") as string is { Length: > 0 } icon)
                    {
                        var iconPath = icon.Split(',')[0].Trim('"');
                        var dir = Path.GetDirectoryName(iconPath);
                        if (dir is not null)
                        {
                            var exe = Path.Combine(dir, exeName);
                            if (File.Exists(exe)) return exe;
                        }
                    }
                }
                catch (Exception ex) when (ex is System.Security.SecurityException
                                            or UnauthorizedAccessException
                                            or IOException)
                {
                    continue;
                }
            }
        }

        return null;
    }

    private static string? FindSteamExe()
    {
        var candidates = new[]
        {
            Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string,
            Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam", "InstallPath", null) as string,
            (Registry.GetValue(@"HKEY_CURRENT_USER\SOFTWARE\Valve\Steam", "SteamPath", null) as string)?.Replace('/', '\\'),
            @"C:\Program Files (x86)\Steam",
        };

        foreach (var dir in candidates)
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            var exe = Path.Combine(dir, "steam.exe");
            if (File.Exists(exe)) return exe;
        }

        return null;
    }

    // ----- boot splash ------------------------------------------------------
    // Unbranded Boot removes the Windows logo, so without this the machine sits
    // on black between logon and the frontend's first frame. Runs on its own STA
    // thread and never blocks the watchdog: a splash that fails is a log line,
    // not a dead console.

    private static Thread? _splashThread;
    private static DateTime _lastSplash = DateTime.MinValue;

    private static void ShowSplash(Process frontend)
    {
        if (!_config.SplashEnabled) return;

        // One splash at a time, and not again right after the last one: a
        // frontend that hands off and relaunches would otherwise stack
        // fullscreen topmost windows over a healthy console.
        if (_splashThread is { IsAlive: true }) return;
        if (DateTime.UtcNow - _lastSplash < TimeSpan.FromSeconds(_config.SplashSeconds + 5)) return;
        _lastSplash = DateTime.UtcNow;

        var imagePath = _config.SplashImage;
        if (string.IsNullOrWhiteSpace(imagePath))
        {
            foreach (var candidate in new[]
            {
                Path.Combine(DataDir, "splash.png"),
                Path.Combine(Path.GetDirectoryName(MachineConfigPath)!, "splash.png"),
            })
            {
                if (File.Exists(candidate)) { imagePath = candidate; break; }
            }
        }

        if (string.IsNullOrWhiteSpace(imagePath) || !File.Exists(imagePath)) return;

        var thread = new Thread(() =>
        {
            try
            {
                using var image = Image.FromFile(imagePath);
                using var form = new Form
                {
                    FormBorderStyle = FormBorderStyle.None,
                    WindowState = FormWindowState.Maximized,
                    BackColor = Color.Black,
                    BackgroundImage = image,
                    BackgroundImageLayout = ImageLayout.Zoom,
                    TopMost = true,
                    ShowInTaskbar = false,
                    StartPosition = FormStartPosition.CenterScreen,
                    Cursor = Cursors.Default,
                };

                var started = DateTime.UtcNow;
                var timer = new System.Windows.Forms.Timer { Interval = 400 };
                timer.Tick += (_, _) =>
                {
                    var frontendVisible = false;
                    try
                    {
                        frontend.Refresh();
                        frontendVisible = !frontend.HasExited && frontend.MainWindowHandle != IntPtr.Zero;
                    }
                    catch { /* frontend died; the timeout closes us anyway */ }

                    if (frontendVisible || (DateTime.UtcNow - started).TotalSeconds >= _config.SplashSeconds)
                    {
                        timer.Stop();
                        form.Close();
                    }
                };
                timer.Start();

                Cursor.Hide();
                Application.Run(form);
                Cursor.Show();
            }
            catch (Exception ex)
            {
                Log($"splash failed (ignored): {ex.Message}");
            }
        })
        {
            IsBackground = true,
            Name = "consolize-splash",
        };
        thread.SetApartmentState(ApartmentState.STA);
        _splashThread = thread;
        thread.Start();
    }

    // ----- tray icon: the way back from desktop mode ------------------------
    // Desktop mode is a dead end without it: the frontend is gone from the
    // screen and there is nothing obvious to click to get the console back.

    private static Thread? _trayThread;
    private static NotifyIcon? _trayIcon;
    private static Control? _trayHost;

    private static void ShowTray()
    {
        if (_trayThread is { IsAlive: true }) return;

        _trayThread = new Thread(() =>
        {
            try
            {
                _trayHost = new Control();
                _trayHost.CreateControl();

                var menu = new ContextMenuStrip();
                menu.Items.Add("Back to console", null, (_, _) => EnterConsole());
                menu.Items.Add("Quick settings", null, (_, _) => OpenPanel());
                menu.Items.Add("Restart the frontend", null, (_, _) =>
                {
                    lock (Sync) { try { _frontend?.Kill(true); } catch { /* already gone */ } }
                });
                menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add("Sleep", null, (_, _) => SetSuspendState(false, false, false));

                Icon icon;
                try { icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application; }
                catch { icon = SystemIcons.Application; }

                _trayIcon = new NotifyIcon
                {
                    Icon = icon,
                    Text = "consolize: desktop mode",
                    Visible = true,
                    ContextMenuStrip = menu,
                };
                _trayIcon.DoubleClick += (_, _) => EnterConsole();
                _trayIcon.ShowBalloonTip(5000, "consolize",
                    "Desktop mode. Double-click here to go back to the console.", ToolTipIcon.Info);

                Application.Run(new ApplicationContext());
            }
            catch (Exception ex)
            {
                Log($"tray icon failed (ignored): {ex.Message}");
            }
            finally
            {
                try { _trayIcon?.Dispose(); } catch { }
                _trayIcon = null;
                _trayHost = null;
            }
        })
        {
            IsBackground = true,
            Name = "consolize-tray",
        };
        _trayThread.SetApartmentState(ApartmentState.STA);
        _trayThread.Start();
    }

    private static void HideTray()
    {
        var host = _trayHost;
        if (host is null) return;
        try
        {
            if (host.InvokeRequired) host.BeginInvoke(new Action(CloseTrayCore));
            else CloseTrayCore();
        }
        catch (Exception ex)
        {
            Log($"could not close the tray icon: {ex.Message}");
        }
    }

    private static void CloseTrayCore()
    {
        try { if (_trayIcon is not null) _trayIcon.Visible = false; } catch { }
        Application.ExitThread();
    }

    [System.Runtime.InteropServices.DllImport("powrprof.dll", SetLastError = true)]
    private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

    // ----- desktop on demand ------------------------------------------------
    // Under Shell Launcher the Winlogon Shell value still points at explorer.exe,
    // so spawning explorer.exe yields the full desktop (taskbar included) and
    // killing it returns to a pure console session. No registry flip-flopping.

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? className, string? windowName);

    /// <summary>The taskbar. Its presence is the difference between "explorer
    /// took over as the shell" and "explorer opened a folder window".</summary>
    private static bool TaskbarPresent() => FindWindow("Shell_TrayWnd", null) != IntPtr.Zero;

    private static void EnterDesktop()
    {
        _mode = SessionMode.Desktop;
        ShowTray();
        if (ExplorerRunningInThisSession()) return;

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"),
                UseShellExecute = false,
            });
            Log("explorer started (desktop mode)");
        }
        catch (Exception ex)
        {
            Log($"failed to start explorer: {ex.Message}");
            return;
        }

        // Whether this actually yields a desktop depends on how the shell was
        // replaced. With the per-user Winlogon Shell value, no shell is
        // registered, so explorer takes over and brings the taskbar. Under
        // Shell Launcher, Microsoft documents that it does not: you get a File
        // Explorer window and nothing else. Check, rather than assume, and say
        // so once instead of leaving the user staring at a folder.
        Task.Run(() =>
        {
            for (var i = 0; i < 20; i++)
            {
                Thread.Sleep(500);
                if (TaskbarPresent())
                {
                    Log("desktop is up (taskbar present)");
                    return;
                }
            }

            Log("explorer started but no taskbar appeared: this session has a shell " +
                "registered, so explorer only opens a folder window. That is expected " +
                "under Shell Launcher; the per-user registry shell does not have it.");
            try
            {
                _trayIcon?.ShowBalloonTip(10000, "consolize",
                    "Explorer opened without a desktop. This machine's shell mode does not " +
                    "allow switching without signing out.", ToolTipIcon.Warning);
            }
            catch { /* the tray may already be gone */ }
        });
    }

    private static void EnterConsole()
    {
        _mode = SessionMode.Console;
        HideTray();
        var session = Process.GetCurrentProcess().SessionId;
        foreach (var p in Process.GetProcessesByName("explorer"))
        {
            try
            {
                if (p.SessionId == session)
                {
                    // Kill explorer alone, never its tree: everything the user
                    // launched from the desktop hangs off it, up to and
                    // including the frontend we are about to return to.
                    p.Kill();
                    Log($"explorer (pid {p.Id}) terminated (console mode)");
                }
            }
            catch (Exception ex)
            {
                Log($"could not terminate explorer {p.Id}: {ex.Message}");
            }
            finally
            {
                p.Dispose();
            }
        }

        _resumeConsoleRequested = true;
    }

    private static bool ExplorerRunningInThisSession()
    {
        var session = Process.GetCurrentProcess().SessionId;
        var found = false;
        foreach (var p in Process.GetProcessesByName("explorer"))
        {
            try { if (p.SessionId == session) found = true; }
            catch { /* process may have died */ }
            finally { p.Dispose(); }
        }

        return found;
    }

    // ----- control pipe -----------------------------------------------------

    private static void PipeServerLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(
                    PipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                server.WaitForConnectionAsync(ct).GetAwaiter().GetResult();

                var reader = new StreamReader(server);
                var writer = new StreamWriter(server) { AutoFlush = true };
                var command = reader.ReadLine()?.Trim().ToLowerInvariant() ?? "";
                writer.WriteLine(HandleCommand(command));
                server.WaitForPipeDrain();
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                Log($"pipe error: {ex.Message}");
                Thread.Sleep(1000);
            }
        }
    }

    private static string HandleCommand(string command)
    {
        Log($"command received: '{command}'");
        switch (command)
        {
            case "ping":
                return "pong";

            case "status":
            {
                Process? p;
                lock (Sync) p = _frontend;
                string fe;
                try { fe = p is { HasExited: false } ? $"running (pid {p.Id})" : "stopped"; }
                catch { fe = "unknown"; }
                return $"mode={_mode}; frontend={fe}";
            }

            case "desktop":
                EnterDesktop();
                return "ok: desktop mode, explorer started";

            case "console":
                EnterConsole();
                return "ok: console mode, explorer terminated";

            case "restart":
                lock (Sync) { try { _frontend?.Kill(true); } catch { /* already gone */ } }
                return "ok: frontend killed, watchdog will relaunch it";

            case "sleep":
                Task.Run(() => { Thread.Sleep(300); SetSuspendState(false, false, false); });
                return "ok: suspending";

            case "panel":
                OpenPanel();
                return "ok: quick settings opened";

            case "quit":
                Task.Run(() =>
                {
                    Thread.Sleep(200);
                    Cts.Cancel();
                    lock (Sync) { try { _frontend?.Kill(true); } catch { /* already gone */ } }
                    Environment.Exit(0);
                });
                return "ok: session manager exiting";

            default:
                return $"error: unknown command '{command}' (try ping|status|desktop|console|restart|quit)";
        }
    }

    // ----- helpers ----------------------------------------------------------

    private static void IdleUntilConsoleRequested(CancellationToken ct, TimeSpan retryAfter)
    {
        // Clear anything latched while nobody was waiting, otherwise a console
        // request from an earlier desktop visit makes the crash-loop breaker
        // return instantly and the machine flaps between a failing frontend and
        // a half-started Explorer.
        _resumeConsoleRequested = false;

        var waited = TimeSpan.Zero;
        var step = TimeSpan.FromMilliseconds(500);
        while (!ct.IsCancellationRequested && waited < retryAfter)
        {
            if (_resumeConsoleRequested) break;
            Thread.Sleep(step);
            waited += step;
        }

        _resumeConsoleRequested = false;
        _mode = SessionMode.Console;
    }

    private static void SleepCancellable(CancellationToken ct, TimeSpan duration)
    {
        ct.WaitHandle.WaitOne(duration);
    }

    private static void Log(string message)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}";
        try
        {
            lock (Sync)
                File.AppendAllText(Path.Combine(LogDir, $"session-{DateTime.Now:yyyyMMdd}.log"), line + Environment.NewLine);
        }
        catch
        {
            // logging must never take the shell down
        }

        Console.WriteLine(line);
    }
}
