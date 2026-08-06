using System.Runtime.InteropServices;

namespace Consolize.SessionManager.Interop;

[Flags]
internal enum PadButton
{
    None = 0,
    Up = 0x0001,
    Down = 0x0002,
    Left = 0x0004,
    Right = 0x0008,
    Start = 0x0010,
    Back = 0x0020,
    LeftShoulder = 0x0100,
    RightShoulder = 0x0200,
    A = 0x1000,
    B = 0x2000,
    X = 0x4000,
    Y = 0x8000,
}

/// <summary>
/// Reads XInput controllers by polling. Every gamepad worth using on Windows
/// speaks XInput, including the 8BitDo pads in X-input mode; DirectInput-only
/// devices are out of scope on purpose.
///
/// Presses are edge triggered, and the analog stick is folded into the d-pad
/// directions with a repeat delay, so a list can be driven with either.
/// </summary>
internal sealed class Gamepad
{
    private const short StickDeadzone = 16000;
    private static readonly TimeSpan RepeatFirst = TimeSpan.FromMilliseconds(400);
    private static readonly TimeSpan RepeatNext = TimeSpan.FromMilliseconds(120);

    private PadButton _previous;
    private PadButton _held;
    private DateTime _heldSince = DateTime.MinValue;
    private DateTime _lastRepeat = DateTime.MinValue;

    public static bool Available { get; private set; } = true;

    /// <summary>How many XInput pads are plugged in or paired right now.</summary>
    public static int ConnectedCount()
    {
        if (!Available) return 0;

        var connected = 0;
        for (uint i = 0; i < 4; i++)
        {
            try
            {
                if (XInputGetState(i, out _) == 0) connected++;
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
            {
                Available = false;
                return 0;
            }
        }
        return connected;
    }

    /// <summary>Buttons that went down since the last poll, plus auto-repeat
    /// for the directions while they are held.</summary>
    public PadButton Poll()
    {
        var current = ReadAll();
        var pressed = current & ~_previous;
        _previous = current;

        const PadButton directions = PadButton.Up | PadButton.Down | PadButton.Left | PadButton.Right;
        var heldDirections = current & directions;

        if (heldDirections == PadButton.None)
        {
            _held = PadButton.None;
        }
        else if (heldDirections != _held)
        {
            _held = heldDirections;
            _heldSince = DateTime.UtcNow;
            _lastRepeat = DateTime.UtcNow;
        }
        else
        {
            var now = DateTime.UtcNow;
            if (now - _heldSince > RepeatFirst && now - _lastRepeat > RepeatNext)
            {
                _lastRepeat = now;
                pressed |= heldDirections;
            }
        }

        return pressed;
    }

    private static PadButton ReadAll()
    {
        if (!Available) return PadButton.None;

        var buttons = PadButton.None;
        for (uint i = 0; i < 4; i++)
        {
            uint result;
            XInputState state;
            try
            {
                result = XInputGetState(i, out state);
            }
            catch (DllNotFoundException)
            {
                Available = false;
                return PadButton.None;
            }
            catch (EntryPointNotFoundException)
            {
                Available = false;
                return PadButton.None;
            }

            if (result != 0) continue;   // ERROR_DEVICE_NOT_CONNECTED

            buttons |= (PadButton)state.Gamepad.Buttons;

            if (state.Gamepad.ThumbLY > StickDeadzone) buttons |= PadButton.Up;
            if (state.Gamepad.ThumbLY < -StickDeadzone) buttons |= PadButton.Down;
            if (state.Gamepad.ThumbLX < -StickDeadzone) buttons |= PadButton.Left;
            if (state.Gamepad.ThumbLX > StickDeadzone) buttons |= PadButton.Right;
        }

        return buttons;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct XInputGamepad
    {
        public ushort Buttons;
        public byte LeftTrigger;
        public byte RightTrigger;
        public short ThumbLX;
        public short ThumbLY;
        public short ThumbRX;
        public short ThumbRY;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct XInputState
    {
        public uint PacketNumber;
        public XInputGamepad Gamepad;
    }

    [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")]
    private static extern uint XInputGetState(uint userIndex, out XInputState state);
}
