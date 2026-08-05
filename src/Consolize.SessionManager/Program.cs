using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
using Microsoft.Win32;

namespace Consolize.SessionManager;

internal enum SessionMode
{
    Console,
    Desktop,
}

internal sealed record AppConfig
{
    /// <summary>steam | playnite | custom</summary>
    public string Frontend { get; init; } = "steam";

    /// <summary>Full path of the frontend executable when Frontend = "custom".</summary>
    public string? CustomCommand { get; init; }

    public string? CustomArgs { get; init; }

    /// <summary>Console behavior: closing the frontend brings it right back.
    /// The desktop is reached explicitly via `consolize send desktop`.</summary>
    public bool RelaunchOnCleanExit { get; init; } = true;

    public int MaxCrashesInWindow { get; init; } = 3;

    public int CrashWindowSeconds { get; init; } = 120;

    /// <summary>Crash-loop breaker: after MaxCrashesInWindow, start Explorer instead
    /// of flapping forever, then retry the frontend later.</summary>
    public bool FallbackToDesktopAfterMaxCrashes { get; init; } = true;

    public int RelaunchDelaySeconds { get; init; } = 3;
}

internal static class Program
{
    private const string PipeName = "consolize";

    private static readonly string DataDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Consolize");

    private static readonly string LogDir = Path.Combine(DataDir, "logs");
    private static readonly string ConfigPath = Path.Combine(DataDir, "config.json");

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

    private static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0].Equals("send", StringComparison.OrdinalIgnoreCase))
            return SendCommand(args[1]);

        if (args.Length >= 1 && (args[0] == "--version" || args[0] == "-v"))
        {
            Console.WriteLine("consolize 0.1.0");
            return 0;
        }

        try
        {
            RunSession();
            return 0;
        }
        catch (Exception ex)
        {
            Log($"FATAL: {ex}");
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
            Console.Error.WriteLine($"consolize: could not reach the session manager ({ex.Message})");
            return 1;
        }
    }

    // ----- session manager --------------------------------------------------

    private static void RunSession()
    {
        Directory.CreateDirectory(LogDir);
        _config = LoadOrCreateConfig();
        Log($"session manager starting (pid {Environment.ProcessId}, frontend '{_config.Frontend}')");

        _ = Task.Run(() => PipeServerLoop(Cts.Token));
        WatchdogLoop(Cts.Token);
        Log("session manager exiting");
    }

    private static AppConfig LoadOrCreateConfig()
    {
        try
        {
            if (File.Exists(ConfigPath))
                return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(ConfigPath), JsonOpts) ?? new AppConfig();

            var config = new AppConfig();
            File.WriteAllText(ConfigPath, JsonSerializer.Serialize(config, JsonOpts));
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
            var frontend = ResolveFrontend();
            if (frontend is null)
            {
                Log("no frontend found (is Steam/Playnite installed?), falling back to desktop");
                EnterDesktop();
                IdleUntilConsoleRequested(ct, TimeSpan.FromSeconds(30));
                continue;
            }

            var (exe, arguments) = frontend.Value;
            Process proc;
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
                continue;
            }

            lock (Sync) _frontend = proc;
            Log($"frontend started: {exe} {arguments} (pid {proc.Id})");

            try { proc.WaitForExit(); } catch { /* killed externally */ }

            int exitCode;
            try { exitCode = proc.ExitCode; } catch { exitCode = -1; }
            lock (Sync) _frontend = null;
            Log($"frontend exited with code {exitCode}");

            if (ct.IsCancellationRequested) break;

            if (exitCode == 0 && !_config.RelaunchOnCleanExit)
            {
                Log("clean exit and RelaunchOnCleanExit=false, entering desktop");
                EnterDesktop();
                IdleUntilConsoleRequested(ct, TimeSpan.FromSeconds(5));
                continue;
            }

            if (exitCode != 0)
            {
                var now = DateTime.UtcNow;
                crashes.Enqueue(now);
                while (crashes.Count > 0 && (now - crashes.Peek()).TotalSeconds > _config.CrashWindowSeconds)
                    crashes.Dequeue();

                if (crashes.Count >= _config.MaxCrashesInWindow)
                {
                    Log($"frontend crashed {crashes.Count}x within {_config.CrashWindowSeconds}s, breaking the loop");
                    crashes.Clear();
                    if (_config.FallbackToDesktopAfterMaxCrashes)
                    {
                        EnterDesktop();
                        IdleUntilConsoleRequested(ct, TimeSpan.FromSeconds(60));
                        continue;
                    }
                }
            }

            SleepCancellable(ct, TimeSpan.FromSeconds(_config.RelaunchDelaySeconds));
        }
    }

    private static (string Exe, string Args)? ResolveFrontend()
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
                var path = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Playnite", "Playnite.FullscreenApp.exe");
                return File.Exists(path) ? (path, "") : null;
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

    // ----- desktop on demand ------------------------------------------------
    // Under Shell Launcher the Winlogon Shell value still points at explorer.exe,
    // so spawning explorer.exe yields the full desktop (taskbar included) and
    // killing it returns to a pure console session. No registry flip-flopping.

    private static void EnterDesktop()
    {
        _mode = SessionMode.Desktop;
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
        }
    }

    private static void EnterConsole()
    {
        _mode = SessionMode.Console;
        var session = Process.GetCurrentProcess().SessionId;
        foreach (var p in Process.GetProcessesByName("explorer"))
        {
            try
            {
                if (p.SessionId == session)
                {
                    p.Kill(true);
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
