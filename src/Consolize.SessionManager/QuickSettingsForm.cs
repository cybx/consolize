using System.Diagnostics;
using Consolize.SessionManager.Interop;

namespace Consolize.SessionManager;

/// <summary>
/// The panel that keeps you off the desktop: audio output, volume, Bluetooth
/// pairing, wifi and power, all reachable with a controller.
///
/// Deliberately plain: a single column of large rows, read from three metres
/// away. D-pad or left stick moves, A activates, left and right adjust, B
/// closes, LB and RB change page.
/// </summary>
internal sealed class QuickSettingsForm : Form
{
    private enum Page { Audio, Bluetooth, Controllers, Network, Power }

    private readonly System.Windows.Forms.Timer _padTimer = new() { Interval = 33 };
    private readonly Gamepad _pad = new();
    private readonly Label _header = new();
    private readonly Label _status = new();
    private readonly ListBox _list = new();
    private readonly Label _hint = new();

    private Page _page = Page.Audio;
    private List<Action> _actions = new();
    private List<AudioDevice> _outputs = new();
    private List<BluetoothDeviceInfo> _btDevices = new();
    private bool _busy;

    private static readonly Color Background = Color.FromArgb(14, 16, 22);
    private static readonly Color Foreground = Color.FromArgb(232, 238, 248);
    private static readonly Color Accent = Color.FromArgb(96, 190, 255);
    private static readonly Color Dim = Color.FromArgb(130, 142, 160);

    public QuickSettingsForm()
    {
        Text = "consolize";
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Maximized;
        BackColor = Background;
        ForeColor = Foreground;
        KeyPreview = true;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;

        _header.Font = new Font("Segoe UI", 28, FontStyle.Bold);
        _header.ForeColor = Accent;
        _header.AutoSize = false;
        _header.Height = 70;
        _header.Dock = DockStyle.Top;
        _header.Padding = new Padding(60, 30, 60, 0);

        _status.Font = new Font("Segoe UI", 13);
        _status.ForeColor = Dim;
        _status.Height = 42;
        _status.Dock = DockStyle.Top;
        _status.Padding = new Padding(62, 0, 60, 0);

        _list.Font = new Font("Segoe UI", 18);
        _list.BackColor = Background;
        _list.ForeColor = Foreground;
        _list.BorderStyle = BorderStyle.None;
        _list.Dock = DockStyle.Fill;
        _list.ItemHeight = 52;
        _list.DrawMode = DrawMode.OwnerDrawFixed;
        _list.DrawItem += DrawRow;
        _list.Margin = new Padding(60);
        _list.DoubleClick += (_, _) => Activate(_list.SelectedIndex);

        _hint.Font = new Font("Segoe UI", 12);
        _hint.ForeColor = Dim;
        _hint.Height = 56;
        _hint.Dock = DockStyle.Bottom;
        _hint.Padding = new Padding(62, 14, 60, 0);
        _hint.Text = "A select     B close     LB / RB page     left / right adjust";

        var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(50, 10, 50, 0), BackColor = Background };
        body.Controls.Add(_list);

        Controls.Add(body);
        Controls.Add(_hint);
        Controls.Add(_status);
        Controls.Add(_header);

        KeyDown += OnKeyDown;
        _padTimer.Tick += OnPadTick;
        _padTimer.Start();

        Load += (_, _) => Render();
    }

    // ----- rendering --------------------------------------------------------

    private void DrawRow(object? sender, DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        var selected = (e.State & DrawItemState.Selected) != 0;
        var text = _list.Items[e.Index]?.ToString() ?? "";

        using var background = new SolidBrush(selected ? Color.FromArgb(30, 40, 58) : Background);
        e.Graphics.FillRectangle(background, e.Bounds);

        if (selected)
        {
            using var bar = new SolidBrush(Accent);
            e.Graphics.FillRectangle(bar, new Rectangle(e.Bounds.X, e.Bounds.Y + 8, 5, e.Bounds.Height - 16));
        }

        using var foreground = new SolidBrush(selected ? Foreground : Color.FromArgb(200, 210, 226));
        e.Graphics.DrawString(text, _list.Font!, foreground, e.Bounds.X + 24, e.Bounds.Y + 12);
    }

    private void SetStatus(string text)
    {
        _status.Text = text;
        _status.Refresh();
    }

    private void Render()
    {
        var previousIndex = _list.SelectedIndex;
        _list.BeginUpdate();
        _list.Items.Clear();
        _actions = new List<Action>();

        switch (_page)
        {
            case Page.Audio: RenderAudio(); break;
            case Page.Bluetooth: RenderBluetooth(); break;
            case Page.Controllers: RenderControllers(); break;
            case Page.Network: RenderNetwork(); break;
            case Page.Power: RenderPower(); break;
        }

        _list.EndUpdate();
        if (_list.Items.Count > 0)
        {
            _list.SelectedIndex = previousIndex >= 0 && previousIndex < _list.Items.Count ? previousIndex : 0;
        }
    }

    private void Add(string text, Action action)
    {
        _list.Items.Add(text);
        _actions.Add(action);
    }

    private void RenderAudio()
    {
        _header.Text = "Sound";
        var volume = Audio.GetVolume();
        var muted = Audio.GetMute() ?? false;
        SetStatus(volume is null
            ? "no audio device found"
            : $"volume {volume}%{(muted ? "   (muted)" : "")}   left and right to adjust");

        Add($"Volume   {Bar(volume ?? 0)}   {volume ?? 0}%", () => Audio.ToggleMute());

        _outputs = Audio.GetOutputs();
        if (_outputs.Count == 0)
        {
            Add("no output devices", () => { });
            return;
        }

        foreach (var device in _outputs)
        {
            var marker = device.IsDefault ? "*" : " ";
            var captured = device;
            Add($"{marker} {device.Name}", () =>
            {
                SetStatus($"switching to {captured.Name}...");
                var ok = Audio.SetDefaultOutput(captured.Id);
                SetStatus(ok ? $"output: {captured.Name}" : "could not switch output");
                Render();
            });
        }
    }

    private void RenderBluetooth()
    {
        _header.Text = "Bluetooth";

        if (!Bluetooth.RadioPresent())
        {
            SetStatus("no Bluetooth radio on this machine");
            Add("nothing to do here", () => { });
            return;
        }

        SetStatus("A pairs or connects, Y scans for new devices, X forgets");

        Add("Scan for new devices (takes a few seconds)", () => RunInBackground(
            "scanning...",
            () => LoadBluetooth(scan: true),
            devices =>
            {
                _btDevices = devices;
                SetStatus($"{devices.Count} device(s) found");
            }));

        if (_btDevices.Count == 0) _btDevices = LoadBluetooth(scan: false);

        // Iterate the same list the rows are indexed against. Sorting only in
        // the projection meant "forget" acted on a different device than the
        // highlighted one, quite possibly the gamepad in your hands.
        foreach (var device in _btDevices)
        {
            var state = device.Connected ? "connected"
                : device.Authenticated ? "paired"
                : "not paired";
            var captured = device;
            Add($"{device.Name}   [{state}]", () => RunInBackground(
                $"pairing with {captured.Name}...",
                () =>
                {
                    var (ok, message) = Bluetooth.Pair(captured.Address);
                    return (Message: message, Devices: LoadBluetooth(scan: false));
                },
                result =>
                {
                    _btDevices = result.Devices;
                    SetStatus($"{captured.Name}: {result.Message}");
                }));
        }
    }

    private List<string> _wakeDevices = new();
    private List<string> _wakeArmed = new();
    private bool _wakeLoaded;

    /// <summary>
    /// Which devices are allowed to wake the machine. This is the setting that
    /// decides whether pressing a button on the controller turns the console
    /// back on, and until now it lived in Device Manager, which is exactly the
    /// place a controller cannot reach.
    ///
    /// Only from sleep: nothing on USB wakes a hibernated machine, so on
    /// hibernate it is the case button or an HDMI-CEC adapter.
    /// </summary>
    private void RenderControllers()
    {
        _header.Text = "Controllers";

        var pads = Gamepad.ConnectedCount();
        SetStatus(Gamepad.Available
            ? $"{pads} controller(s) connected. A is select, B closes."
            : "XInput is not available on this machine");

        if (!_wakeLoaded)
        {
            _wakeLoaded = true;
            RunInBackground("reading which devices may wake the machine...",
                () => (All: ParsePowercfgList("wake_programmable"), Armed: ParsePowercfgList("wake_armed")),
                result =>
                {
                    _wakeDevices = result.All;
                    _wakeArmed = result.Armed;
                    SetStatus($"{pads} controller(s) connected");
                });
            Add("reading devices...", () => { });
            return;
        }

        if (_wakeDevices.Count == 0)
        {
            Add("no device on this machine can wake it", () => { });
            Add("(a 2.4G receiver usually can; Bluetooth usually cannot)", () => { });
            return;
        }

        Add("Wake the console with these devices:", () => { });
        foreach (var device in _wakeDevices)
        {
            var armed = _wakeArmed.Contains(device, StringComparer.OrdinalIgnoreCase);
            var captured = device;
            var name = device.Length > 60 ? device.Substring(0, 57) + "..." : device;

            Add($"{(armed ? "[on ]" : "[off]")} {name}", () => RunInBackground(
                armed ? $"stopping {name} from waking the machine..." : $"letting {name} wake the machine...",
                () =>
                {
                    // powercfg needs elevation; on a console account set up by
                    // this project that is granted without a prompt.
                    RunElevated("powercfg.exe",
                        $"/device{(armed ? "disable" : "enable")}wake \"{captured}\"");
                    return (All: ParsePowercfgList("wake_programmable"), Armed: ParsePowercfgList("wake_armed"));
                },
                result =>
                {
                    _wakeDevices = result.All;
                    _wakeArmed = result.Armed;
                    SetStatus(result.Armed.Contains(captured, StringComparer.OrdinalIgnoreCase)
                        ? $"{name} can now wake the console"
                        : $"{name} will no longer wake the console");
                }));
        }
    }

    private static List<string> ParsePowercfgList(string query)
    {
        return RunCommand("powercfg.exe", $"/devicequery {query}")
            .Split('\n')
            .Select(line => line.Trim())
            .Where(line => line.Length > 0 && !line.StartsWith("NONE", StringComparison.OrdinalIgnoreCase))
            .Distinct()
            .ToList();
    }

    private static void RunElevated(string file, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments)
            {
                UseShellExecute = true,
                Verb = "runas",
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            });
            process?.WaitForExit(20000);
        }
        catch (Exception)
        {
            // elevation refused, or no such device: the caller re-reads the
            // state either way and shows what actually happened
        }
    }

    private List<string> _wifiProfiles = new();
    private bool _wifiLoaded;

    private void RenderNetwork()
    {
        _header.Text = "Network";
        SetStatus("A connects to a saved network");

        // netsh can take seconds; never on the UI thread
        if (!_wifiLoaded)
        {
            _wifiLoaded = true;
            RunInBackground("reading saved networks...", LoadWifiProfiles, profiles =>
            {
                _wifiProfiles = profiles;
                SetStatus("A connects to a saved network");
            });
            Add("reading saved networks...", () => { });
            return;
        }

        var profiles = _wifiProfiles;
        if (profiles.Count == 0)
        {
            Add("no saved wifi networks", () => { });
            Add("(a new network needs the desktop once, for the password)", () => { });
            return;
        }

        foreach (var profile in profiles)
        {
            var captured = profile;
            Add($"Connect to {profile}", () => RunInBackground(
                $"connecting to {captured}...",
                () => RunCommand("netsh", $"wlan connect name=\"{captured}\""),
                _ => SetStatus($"asked Windows to connect to {captured}")));
        }
    }

    private void RenderPower()
    {
        _header.Text = "Power";
        SetStatus("");

        Add("Back to the console", () => { Send("console"); Close(); });
        Add("Desktop mode", () => { Send("desktop"); Close(); });
        Add("Restart the frontend", () => { Send("restart"); Close(); });
        Add("Sleep", () => { Send("sleep"); Close(); });
        Add("Restart", () => Process.Start(new ProcessStartInfo("shutdown.exe", "/r /t 0") { UseShellExecute = false }));
        Add("Shut down", () => Process.Start(new ProcessStartInfo("shutdown.exe", "/s /t 0") { UseShellExecute = false }));
    }

    private static List<string> LoadWifiProfiles()
    {
        return RunCommand("netsh", "wlan show profiles")
            .Split('\n')
            .Where(line => line.Contains(':') && line.Contains("Profile", StringComparison.OrdinalIgnoreCase)
                        && !line.Contains("Group", StringComparison.OrdinalIgnoreCase))
            .Select(line => line.Split(':', 2)[1].Trim())
            .Where(name => name.Length > 0)
            .Distinct()
            .ToList();
    }

    private static List<BluetoothDeviceInfo> LoadBluetooth(bool scan)
    {
        return Bluetooth.GetDevices(scan)
            .OrderByDescending(d => d.Connected)
            .ThenBy(d => d.Name)
            .ToList();
    }

    /// <summary>
    /// Runs slow work off the UI thread. A Bluetooth inquiry or a pairing
    /// attempt takes seconds to tens of seconds, and doing it inline froze a
    /// borderless topmost window over the game with the B button dead: on a
    /// console with no keyboard, the only way out was the power button.
    /// </summary>
    private void RunInBackground<T>(string status, Func<T> work, Action<T> onDone)
    {
        if (_busy) return;
        _busy = true;
        SetStatus(status);

        Task.Run(work).ContinueWith(task =>
        {
            if (IsDisposed || Disposing) return;
            try
            {
                BeginInvoke(new Action(() =>
                {
                    _busy = false;
                    if (task.IsFaulted)
                    {
                        SetStatus($"failed: {task.Exception?.GetBaseException().Message}");
                    }
                    else
                    {
                        onDone(task.Result);
                    }
                    Render();
                }));
            }
            catch (ObjectDisposedException)
            {
                // the panel was closed while the work was running
            }
        });
    }

    private static string Bar(int percent)
    {
        const int width = 20;
        var filled = (int)Math.Round(percent / 100.0 * width);
        return new string('=', filled) + new string('.', width - filled);
    }

    // ----- input ------------------------------------------------------------

    private void OnPadTick(object? sender, EventArgs e)
    {
        var pressed = _pad.Poll();
        if (pressed == PadButton.None) return;

        if (pressed.HasFlag(PadButton.Down)) MoveSelection(1);
        if (pressed.HasFlag(PadButton.Up)) MoveSelection(-1);
        if (pressed.HasFlag(PadButton.A)) Activate(_list.SelectedIndex);
        if (pressed.HasFlag(PadButton.B) || pressed.HasFlag(PadButton.Back)) Close();
        if (pressed.HasFlag(PadButton.RightShoulder)) ChangePage(1);
        if (pressed.HasFlag(PadButton.LeftShoulder)) ChangePage(-1);
        if (pressed.HasFlag(PadButton.Right)) Adjust(5);
        if (pressed.HasFlag(PadButton.Left)) Adjust(-5);
        if (pressed.HasFlag(PadButton.Y) && _page == Page.Bluetooth) Activate(0);
        if (pressed.HasFlag(PadButton.X) && _page == Page.Bluetooth) ForgetSelected();
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        switch (e.KeyCode)
        {
            case Keys.Escape: Close(); break;
            case Keys.Enter: Activate(_list.SelectedIndex); break;
            case Keys.Right: Adjust(5); break;
            case Keys.Left: Adjust(-5); break;
            case Keys.Tab: ChangePage(e.Shift ? -1 : 1); break;
        }
    }

    private void MoveSelection(int delta)
    {
        if (_list.Items.Count == 0) return;
        var index = _list.SelectedIndex + delta;
        _list.SelectedIndex = Math.Clamp(index, 0, _list.Items.Count - 1);
    }

    private void ChangePage(int delta)
    {
        var pages = Enum.GetValues<Page>();
        var index = (Array.IndexOf(pages, _page) + delta + pages.Length) % pages.Length;
        _page = pages[index];
        _list.SelectedIndex = -1;
        Render();
    }

    private void Activate(int index)
    {
        if (index < 0 || index >= _actions.Count) return;
        try { _actions[index](); }
        catch (Exception ex) { SetStatus($"failed: {ex.Message}"); }
    }

    private void Adjust(int delta)
    {
        if (_page != Page.Audio || _list.SelectedIndex != 0) return;
        var volume = Audio.GetVolume();
        if (volume is null) return;
        Audio.SetVolume(volume.Value + delta);
        Render();
    }

    private void ForgetSelected()
    {
        var index = _list.SelectedIndex - 1;   // row 0 is the scan entry
        if (index < 0 || index >= _btDevices.Count) return;
        var device = _btDevices[index];
        RunInBackground(
            $"forgetting {device.Name}...",
            () => (Ok: Bluetooth.Remove(device.Address), Devices: LoadBluetooth(scan: false)),
            result =>
            {
                _btDevices = result.Devices;
                SetStatus(result.Ok ? $"{device.Name} forgotten" : $"could not forget {device.Name}");
            });
    }

    private static void Send(string command)
    {
        try
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!, $"send {command}")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Exception)
        {
            // the panel can be opened without a session manager running
        }
    }

    private static string RunCommand(string file, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments)
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (process is null) return "";
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(15000);
            return output;
        }
        catch (Exception)
        {
            return "";
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _padTimer.Stop();
        _padTimer.Dispose();
        base.OnFormClosed(e);
    }
}
