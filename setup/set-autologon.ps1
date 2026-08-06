#Requires -RunAsAdministrator
<#
Configures automatic logon the safe way (F2).

The password is stored as an LSA secret (what Sysinternals Autologon does),
NOT as the cleartext DefaultPassword registry value. Winlogon reads the
'DefaultPassword' LSA secret when the registry value is absent.

Usage:
    .\set-autologon.ps1 -UserName gamer          # prompts for the password
    .\set-autologon.ps1 -UserName gamer -Remove  # disables autologon
#>
param(
    [Parameter(Mandatory)] [string]$UserName,
    [string]$Domain = $env:COMPUTERNAME,
    # Passed by setup-console so the password is typed once for the whole setup.
    # Never a plain string: it stays a SecureString until the LSA call.
    [System.Security.SecureString]$Password,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class LsaSecret
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [DllImport("advapi32.dll")]
    private static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr policy);

    [DllImport("advapi32.dll")]
    private static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, ref LSA_UNICODE_STRING data);

    [DllImport("advapi32.dll")]
    private static extern uint LsaNtStatusToWinError(uint status);

    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr policy);

    private const uint POLICY_CREATE_SECRET = 0x00000020;

    public static void Store(string key, string value)
    {
        var attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));

        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, POLICY_CREATE_SECRET, out policy);
        if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));

        try
        {
            var k = MakeString(key);
            var d = MakeString(value);
            try
            {
                status = LsaStorePrivateData(policy, ref k, ref d);
                if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
            }
            finally
            {
                // zero the unmanaged copy of the secret before freeing it
                for (int i = 0; i < value.Length * 2; i++) Marshal.WriteByte(d.Buffer, i, 0);
                Marshal.FreeHGlobal(d.Buffer);
                Marshal.FreeHGlobal(k.Buffer);
            }
        }
        finally
        {
            LsaClose(policy);
        }
    }

    private static LSA_UNICODE_STRING MakeString(string s)
    {
        var us = new LSA_UNICODE_STRING();
        us.Buffer = Marshal.StringToHGlobalUni(s);
        us.Length = (ushort)(s.Length * 2);
        us.MaximumLength = (ushort)((s.Length + 1) * 2);
        return us;
    }
}
'@

$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if ($Remove) {
    Set-ItemProperty $wl -Name AutoAdminLogon -Value '0' -Type String
    [LsaSecret]::Store('DefaultPassword', '')
    Remove-ItemProperty $wl -Name DefaultPassword -ErrorAction SilentlyContinue
    Write-Host "Autologon disabled."
    return
}

$secure = if ($Password -and $Password.Length -gt 0) { $Password }
          else { Read-Host "Password for $Domain\$UserName" -AsSecureString }
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

[LsaSecret]::Store('DefaultPassword', $plain)
$plain = $null

Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty $wl -Name DefaultUserName -Value $UserName -Type String
Set-ItemProperty $wl -Name DefaultDomainName -Value $Domain -Type String
# kill any cleartext leftover from other tools (GamesDows and friends)
Remove-ItemProperty $wl -Name DefaultPassword -ErrorAction SilentlyContinue

Write-Host "Autologon set for $Domain\$UserName (password stored as LSA secret, not plaintext)."
