using System.Runtime.InteropServices;

namespace Consolize.SessionManager.Interop;

/// <summary>Saved Wi-Fi profiles through wlanapi.dll. Unlike parsing netsh,
/// these structures do not change when Windows is installed in Portuguese,
/// Spanish, German or any other display language.</summary>
internal static class Wifi
{
    public static List<string> GetProfiles()
    {
        var profiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (WlanOpenHandle(2, IntPtr.Zero, out _, out var handle) != 0) return profiles.ToList();

        try
        {
            if (WlanEnumInterfaces(handle, IntPtr.Zero, out var list) != 0) return profiles.ToList();
            try
            {
                var count = Marshal.ReadInt32(list);
                var first = IntPtr.Add(list, 8);
                var interfaceSize = Marshal.SizeOf<WlanInterfaceInfo>();
                for (var i = 0; i < count; i++)
                {
                    var info = Marshal.PtrToStructure<WlanInterfaceInfo>(IntPtr.Add(first, i * interfaceSize));
                    if (WlanGetProfileList(handle, ref info.InterfaceGuid, IntPtr.Zero, out var profileList) != 0)
                        continue;
                    try
                    {
                        var profileCount = Marshal.ReadInt32(profileList);
                        var profileFirst = IntPtr.Add(profileList, 8);
                        var profileSize = Marshal.SizeOf<WlanProfileInfo>();
                        for (var p = 0; p < profileCount; p++)
                        {
                            var profile = Marshal.PtrToStructure<WlanProfileInfo>(
                                IntPtr.Add(profileFirst, p * profileSize));
                            if (!string.IsNullOrWhiteSpace(profile.ProfileName)) profiles.Add(profile.ProfileName);
                        }
                    }
                    finally { WlanFreeMemory(profileList); }
                }
            }
            finally { WlanFreeMemory(list); }
        }
        finally { WlanCloseHandle(handle, IntPtr.Zero); }

        return profiles.OrderBy(name => name).ToList();
    }

    public static (bool Ok, string Message) Connect(string profileName)
    {
        if (WlanOpenHandle(2, IntPtr.Zero, out _, out var handle) != 0)
            return (false, "Windows Wi-Fi service is unavailable");

        var profile = Marshal.StringToHGlobalUni(profileName);
        try
        {
            if (WlanEnumInterfaces(handle, IntPtr.Zero, out var list) != 0)
                return (false, "no Wi-Fi interface found");
            try
            {
                var count = Marshal.ReadInt32(list);
                var first = IntPtr.Add(list, 8);
                var size = Marshal.SizeOf<WlanInterfaceInfo>();
                for (var i = 0; i < count; i++)
                {
                    var info = Marshal.PtrToStructure<WlanInterfaceInfo>(IntPtr.Add(first, i * size));
                    var parameters = new WlanConnectionParameters
                    {
                        ConnectionMode = 0, // wlan_connection_mode_profile
                        Profile = profile,
                        Dot11BssType = 3,   // dot11_BSS_type_any
                    };
                    if (WlanConnect(handle, ref info.InterfaceGuid, ref parameters, IntPtr.Zero) == 0)
                        return (true, $"asked Windows to connect to {profileName}");
                }
                return (false, $"Windows could not connect to {profileName}");
            }
            finally { WlanFreeMemory(list); }
        }
        finally
        {
            Marshal.FreeHGlobal(profile);
            WlanCloseHandle(handle, IntPtr.Zero);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WlanInterfaceInfo
    {
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
        public uint State;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WlanProfileInfo
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProfileName;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WlanConnectionParameters
    {
        public uint ConnectionMode;
        public IntPtr Profile;
        public IntPtr Dot11Ssid;
        public IntPtr DesiredBssidList;
        public uint Dot11BssType;
        public uint Flags;
    }

    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved,
        out uint negotiatedVersion, out IntPtr clientHandle);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(IntPtr clientHandle, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanEnumInterfaces(IntPtr clientHandle, IntPtr reserved, out IntPtr interfaceList);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanGetProfileList(IntPtr clientHandle, ref Guid interfaceGuid,
        IntPtr reserved, out IntPtr profileList);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanConnect(IntPtr clientHandle, ref Guid interfaceGuid,
        ref WlanConnectionParameters connectionParameters, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr memory);
}
