using System.Runtime.InteropServices;

namespace Consolize.SessionManager.Interop;

internal sealed record BluetoothDeviceInfo(
    ulong Address,
    string Name,
    bool Authenticated,
    bool Connected,
    bool Remembered);

/// <summary>
/// Pairing and connecting Bluetooth devices without the Settings app, which is
/// the single reason people end up back on the desktop with a keyboard in hand.
///
/// Uses the Win32 Bluetooth API (bthprops.cpl). Pairing goes through
/// BluetoothAuthenticateDeviceEx with a callback that accepts Just Works and
/// asks the person to verify numeric comparison. Devices that demand a typed
/// passkey are reported as such instead of failing silently.
/// </summary>
internal static class Bluetooth
{
    public static bool RadioPresent()
    {
        var parameters = new BLUETOOTH_FIND_RADIO_PARAMS { dwSize = Marshal.SizeOf<BLUETOOTH_FIND_RADIO_PARAMS>() };
        IntPtr radio = IntPtr.Zero;
        IntPtr find = IntPtr.Zero;
        try
        {
            find = BluetoothFindFirstRadio(ref parameters, out radio);
            return find != IntPtr.Zero;
        }
        catch (DllNotFoundException)
        {
            return false;
        }
        finally
        {
            if (radio != IntPtr.Zero) CloseHandle(radio);
            if (find != IntPtr.Zero) BluetoothFindRadioClose(find);
        }
    }

    /// <param name="scan">Ask the radio to look for new devices. Takes several
    /// seconds, so the caller should say so on screen first.</param>
    public static List<BluetoothDeviceInfo> GetDevices(bool scan = false)
    {
        var devices = new List<BluetoothDeviceInfo>();

        var search = new BLUETOOTH_DEVICE_SEARCH_PARAMS
        {
            dwSize = Marshal.SizeOf<BLUETOOTH_DEVICE_SEARCH_PARAMS>(),
            fReturnAuthenticated = true,
            fReturnRemembered = true,
            fReturnUnknown = scan,
            fReturnConnected = true,
            fIssueInquiry = scan,
            cTimeoutMultiplier = scan ? (byte)4 : (byte)0,   // 4 x 1.28s
            hRadio = IntPtr.Zero,
        };

        var info = new BLUETOOTH_DEVICE_INFO { dwSize = Marshal.SizeOf<BLUETOOTH_DEVICE_INFO>() };

        IntPtr find = IntPtr.Zero;
        try
        {
            find = BluetoothFindFirstDevice(ref search, ref info);
            if (find == IntPtr.Zero) return devices;

            do
            {
                devices.Add(new BluetoothDeviceInfo(
                    info.Address,
                    string.IsNullOrWhiteSpace(info.szName) ? FormatAddress(info.Address) : info.szName,
                    info.fAuthenticated,
                    info.fConnected,
                    info.fRemembered));

                info = new BLUETOOTH_DEVICE_INFO { dwSize = Marshal.SizeOf<BLUETOOTH_DEVICE_INFO>() };
            }
            while (BluetoothFindNextDevice(find, ref info));
        }
        catch (DllNotFoundException)
        {
            // no Bluetooth stack on this machine
        }
        finally
        {
            if (find != IntPtr.Zero) BluetoothFindDeviceClose(find);
        }

        return devices;
    }

    public static (bool Ok, string Message) Pair(ulong address)
    {
        var info = new BLUETOOTH_DEVICE_INFO { dwSize = Marshal.SizeOf<BLUETOOTH_DEVICE_INFO>(), Address = address };

        // Keep the delegate alive for the duration of the call.
        BluetoothAuthenticationCallbackEx callback = OnAuthentication;
        IntPtr registration = IntPtr.Zero;

        try
        {
            var registerResult = BluetoothRegisterForAuthenticationEx(ref info, out registration, callback, IntPtr.Zero);
            if (registerResult != 0) return (false, $"could not register for authentication (error {registerResult})");

            var result = BluetoothAuthenticateDeviceEx(IntPtr.Zero, IntPtr.Zero, ref info, IntPtr.Zero,
                AUTHENTICATION_REQUIREMENTS.MITMProtectionNotRequired);

            return result switch
            {
                0 => (true, "paired"),
                1244 => (false, "the device wants a typed passkey, pair it from Windows Settings"),
                1219 => (true, "already paired"),
                _ => (false, $"pairing failed (error {result})"),
            };
        }
        catch (DllNotFoundException)
        {
            return (false, "no Bluetooth stack on this machine");
        }
        finally
        {
            if (registration != IntPtr.Zero) BluetoothUnregisterAuthentication(registration);
            GC.KeepAlive(callback);
        }
    }

    public static bool Remove(ulong address)
    {
        var info = new BLUETOOTH_DEVICE_INFO { dwSize = Marshal.SizeOf<BLUETOOTH_DEVICE_INFO>(), Address = address };
        try { return BluetoothRemoveDevice(ref info.Address) == 0; }
        catch (DllNotFoundException) { return false; }
    }

    private static bool OnAuthentication(IntPtr param, ref BLUETOOTH_AUTHENTICATION_CALLBACK_PARAMS parameters)
    {
        // Just Works has nothing to compare. Numeric comparison only provides
        // MITM protection if a person actually confirms the same digits on
        // both devices; auto-accepting it defeats the protocol.
        var response = new BLUETOOTH_AUTHENTICATE_RESPONSE
        {
            bthAddressRemote = parameters.deviceInfo.Address,
            authMethod = parameters.authenticationMethod,
            negativeResponse = 0,
        };

        if (parameters.authenticationMethod == AUTHENTICATION_METHOD.NumericComparison)
        {
            response.numericCompNumericValueOrPasskey = parameters.Numeric_Value_Passkey;
            var device = string.IsNullOrWhiteSpace(parameters.deviceInfo.szName)
                ? FormatAddress(parameters.deviceInfo.Address)
                : parameters.deviceInfo.szName;
            var answer = MessageBox.Show(
                $"Does {device} show this same number?\n\n{parameters.Numeric_Value_Passkey:D6}",
                "Confirm Bluetooth pairing",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes) response.negativeResponse = 1;
        }
        else if (parameters.authenticationMethod == AUTHENTICATION_METHOD.JustWorks)
        {
            response.numericCompNumericValueOrPasskey = 0;
        }
        else
        {
            // Legacy PIN or a passkey we cannot invent: refuse cleanly.
            response.negativeResponse = 1;
        }

        BluetoothSendAuthenticationResponseEx(IntPtr.Zero, ref response);
        return true;
    }

    public static string FormatAddress(ulong address)
    {
        var bytes = BitConverter.GetBytes(address);
        return string.Join(":", bytes.Take(6).Reverse().Select(b => b.ToString("X2")));
    }

    // ----- interop ----------------------------------------------------------

    private const string BthProps = "bthprops.cpl";

    [StructLayout(LayoutKind.Sequential)]
    private struct BLUETOOTH_FIND_RADIO_PARAMS { public int dwSize; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BLUETOOTH_DEVICE_SEARCH_PARAMS
    {
        public int dwSize;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnAuthenticated;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnUnknown;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct BLUETOOTH_DEVICE_INFO
    {
        public int dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)] public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEMTIME
    {
        public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds;
    }

    private enum AUTHENTICATION_REQUIREMENTS
    {
        MITMProtectionNotRequired = 0,
        MITMProtectionRequired = 1,
    }

    private enum AUTHENTICATION_METHOD
    {
        Legacy = 1,
        OobDataAvailable = 2,
        NumericComparison = 3,
        PasskeyNotification = 4,
        Passkey = 5,
        JustWorks = 6,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BLUETOOTH_AUTHENTICATION_CALLBACK_PARAMS
    {
        public BLUETOOTH_DEVICE_INFO deviceInfo;
        public AUTHENTICATION_METHOD authenticationMethod;
        public uint ioCapability;
        public uint authenticationRequirements;
        public uint Numeric_Value_Passkey;
    }

    // Native layout: address at 0, authMethod at 8, then a UNION at 12 whose
    // largest member (BLUETOOTH_OOB_DATA_INFO) is 32 bytes, so negativeResponse
    // sits at 44 and the struct is 48. Declared sequentially it landed at 48
    // instead, meaning the refusal flag was written past what the API reads:
    // a device that wanted a typed passkey got an affirmative answer with
    // passkey 0 and the call blocked until the pairing timed out.
    [StructLayout(LayoutKind.Explicit, Size = 48)]
    private struct BLUETOOTH_AUTHENTICATE_RESPONSE
    {
        [FieldOffset(0)] public ulong bthAddressRemote;
        [FieldOffset(8)] public AUTHENTICATION_METHOD authMethod;
        [FieldOffset(12)] public uint numericCompNumericValueOrPasskey;
        [FieldOffset(44)] public byte negativeResponse;
    }

    private delegate bool BluetoothAuthenticationCallbackEx(
        IntPtr pvParam, ref BLUETOOTH_AUTHENTICATION_CALLBACK_PARAMS parameters);

    [DllImport(BthProps, SetLastError = true)]
    private static extern IntPtr BluetoothFindFirstRadio(ref BLUETOOTH_FIND_RADIO_PARAMS parameters, out IntPtr radio);

    [DllImport(BthProps, SetLastError = true)]
    private static extern bool BluetoothFindRadioClose(IntPtr find);

    [DllImport(BthProps, SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr BluetoothFindFirstDevice(
        ref BLUETOOTH_DEVICE_SEARCH_PARAMS parameters, ref BLUETOOTH_DEVICE_INFO info);

    [DllImport(BthProps, SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool BluetoothFindNextDevice(IntPtr find, ref BLUETOOTH_DEVICE_INFO info);

    [DllImport(BthProps, SetLastError = true)]
    private static extern bool BluetoothFindDeviceClose(IntPtr find);

    [DllImport(BthProps, SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint BluetoothAuthenticateDeviceEx(
        IntPtr parentWindow, IntPtr radio, ref BLUETOOTH_DEVICE_INFO info,
        IntPtr oobData, AUTHENTICATION_REQUIREMENTS requirements);

    [DllImport(BthProps, SetLastError = true)]
    private static extern uint BluetoothRegisterForAuthenticationEx(
        ref BLUETOOTH_DEVICE_INFO info, out IntPtr handle,
        BluetoothAuthenticationCallbackEx callback, IntPtr param);

    [DllImport(BthProps, SetLastError = true)]
    private static extern bool BluetoothUnregisterAuthentication(IntPtr handle);

    [DllImport(BthProps, SetLastError = true)]
    private static extern uint BluetoothSendAuthenticationResponseEx(
        IntPtr radio, ref BLUETOOTH_AUTHENTICATE_RESPONSE response);

    [DllImport(BthProps, SetLastError = true)]
    private static extern uint BluetoothRemoveDevice(ref ulong address);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
