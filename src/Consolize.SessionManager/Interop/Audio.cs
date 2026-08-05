using System.Runtime.InteropServices;

namespace Consolize.SessionManager.Interop;

internal sealed record AudioDevice(string Id, string Name, bool IsDefault);

/// <summary>
/// Output device switching and master volume through Core Audio.
///
/// Enumeration and volume use documented interfaces. Setting the default device
/// does not have one: Microsoft never shipped a public API for it, so every
/// audio switcher on Windows uses IPolicyConfig, undocumented but unchanged
/// since Vista. If it ever breaks, the panel degrades to volume only rather
/// than taking the shell down.
/// </summary>
internal static class Audio
{
    private const uint DeviceStateActive = 0x00000001;

    public static List<AudioDevice> GetOutputs()
    {
        var result = new List<AudioDevice>();
        IMMDeviceEnumerator? enumerator = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

            string? defaultId = null;
            if (enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, ERole.Multimedia, out var defaultDevice) == 0
                && defaultDevice is not null)
            {
                defaultDevice.GetId(out defaultId);
                Marshal.ReleaseComObject(defaultDevice);
            }

            if (enumerator.EnumAudioEndpoints(EDataFlow.Render, DeviceStateActive, out var collection) != 0
                || collection is null)
            {
                return result;
            }

            collection.GetCount(out var count);
            for (uint i = 0; i < count; i++)
            {
                if (collection.Item(i, out var device) != 0 || device is null) continue;
                try
                {
                    device.GetId(out var id);
                    var name = GetFriendlyName(device) ?? id;
                    result.Add(new AudioDevice(id, name, id == defaultId));
                }
                finally
                {
                    Marshal.ReleaseComObject(device);
                }
            }

            Marshal.ReleaseComObject(collection);
        }
        catch (Exception)
        {
            // A machine with no audio endpoints at all is a valid state.
        }
        finally
        {
            if (enumerator is not null) Marshal.ReleaseComObject(enumerator);
        }

        return result;
    }

    public static bool SetDefaultOutput(string deviceId)
    {
        object? policyConfig = null;
        try
        {
            policyConfig = new PolicyConfigClient();
            var config = (IPolicyConfig)policyConfig;
            // All three roles, otherwise communications apps keep the old device.
            foreach (var role in new[] { ERole.Console, ERole.Multimedia, ERole.Communications })
            {
                if (config.SetDefaultEndpoint(deviceId, role) != 0) return false;
            }
            return true;
        }
        catch (Exception)
        {
            return false;
        }
        finally
        {
            if (policyConfig is not null) Marshal.ReleaseComObject(policyConfig);
        }
    }

    /// <summary>Master volume of the current output, 0 to 100. Null if unavailable.</summary>
    public static int? GetVolume()
    {
        return WithEndpointVolume(v =>
        {
            v.GetMasterVolumeLevelScalar(out var scalar);
            return (int)Math.Round(scalar * 100);
        });
    }

    public static void SetVolume(int percent)
    {
        percent = Math.Clamp(percent, 0, 100);
        WithEndpointVolume(v =>
        {
            v.SetMasterVolumeLevelScalar(percent / 100f, Guid.Empty);
            if (percent > 0) v.SetMute(false, Guid.Empty);
            return 0;
        });
    }

    public static bool? GetMute()
    {
        return WithEndpointVolume<bool?>(v =>
        {
            v.GetMute(out var muted);
            return muted;
        });
    }

    public static void ToggleMute()
    {
        WithEndpointVolume(v =>
        {
            v.GetMute(out var muted);
            v.SetMute(!muted, Guid.Empty);
            return 0;
        });
    }

    private static T? WithEndpointVolume<T>(Func<IAudioEndpointVolume, T> action)
    {
        IMMDeviceEnumerator? enumerator = null;
        IMMDevice? device = null;
        object? volumeObject = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            if (enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, ERole.Multimedia, out device) != 0
                || device is null)
            {
                return default;
            }

            var iid = typeof(IAudioEndpointVolume).GUID;
            if (device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out volumeObject) != 0
                || volumeObject is null)
            {
                return default;
            }

            return action((IAudioEndpointVolume)volumeObject);
        }
        catch (Exception)
        {
            return default;
        }
        finally
        {
            if (volumeObject is not null) Marshal.ReleaseComObject(volumeObject);
            if (device is not null) Marshal.ReleaseComObject(device);
            if (enumerator is not null) Marshal.ReleaseComObject(enumerator);
        }
    }

    private static string? GetFriendlyName(IMMDevice device)
    {
        // PKEY_Device_FriendlyName
        var key = new PropertyKey
        {
            FormatId = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
            PropertyId = 14,
        };

        IPropertyStore? store = null;
        try
        {
            if (device.OpenPropertyStore(0 /* STGM_READ */, out store) != 0 || store is null) return null;
            if (store.GetValue(ref key, out var variant) != 0) return null;
            try
            {
                return variant.Vt == 31 /* VT_LPWSTR */ ? Marshal.PtrToStringUni(variant.Pointer) : null;
            }
            finally
            {
                PropVariantClear(ref variant);
            }
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            if (store is not null) Marshal.ReleaseComObject(store);
        }
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant pvar);

    // ----- COM plumbing -----------------------------------------------------

    internal enum EDataFlow { Render = 0, Capture = 1, All = 2 }
    internal enum ERole { Console = 0, Multimedia = 1, Communications = 2 }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey
    {
        public Guid FormatId;
        public int PropertyId;
    }

    // PROPVARIANT is 24 bytes on x64; the explicit size keeps the callee from
    // writing past the end of our stack slot.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    internal struct PropVariant
    {
        [FieldOffset(0)] public ushort Vt;
        [FieldOffset(8)] public IntPtr Pointer;
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator { }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    private class PolicyConfigClient { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask,
            [MarshalAs(UnmanagedType.Interface)] out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role,
            [MarshalAs(UnmanagedType.Interface)] out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id,
            [MarshalAs(UnmanagedType.Interface)] out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, [MarshalAs(UnmanagedType.Interface)] out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(uint access,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("f8679f50-850a-410c-9c3e-db31319fe5e8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat(string device, IntPtr format);
        [PreserveSig] int GetDeviceFormat(string device, bool isDefault, IntPtr format);
        [PreserveSig] int ResetDeviceFormat(string device);
        [PreserveSig] int SetDeviceFormat(string device, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod(string device, bool isDefault, IntPtr defaultPeriod, IntPtr minimumPeriod);
        [PreserveSig] int SetProcessingPeriod(string device, IntPtr period);
        [PreserveSig] int GetShareMode(string device, IntPtr mode);
        [PreserveSig] int SetShareMode(string device, IntPtr mode);
        [PreserveSig] int GetPropertyValue(string device, bool state, ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetPropertyValue(string device, bool state, ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string device, ERole role);
        [PreserveSig] int SetEndpointVisibility(string device, bool visible);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, Guid eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, Guid eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, Guid eventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, Guid eventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, Guid eventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        [PreserveSig] int GetVolumeStepInfo(out uint step, out uint stepCount);
        [PreserveSig] int VolumeStepUp(Guid eventContext);
        [PreserveSig] int VolumeStepDown(Guid eventContext);
        [PreserveSig] int QueryHardwareSupport(out uint hardwareSupportMask);
        [PreserveSig] int GetVolumeRange(out float minDb, out float maxDb, out float incrementDb);
    }
}
