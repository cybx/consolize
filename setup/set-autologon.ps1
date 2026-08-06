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
    [string]$UserName,
    [string]$Domain = $env:COMPUTERNAME,
    # Passed by setup-console so the password is typed once for the whole setup.
    # Never a plain string: it stays a SecureString until the LSA call.
    [System.Security.SecureString]$Password,
    # Fallback for machines where the LSA route does not take. Windows 11 24H2,
    # which IoT Enterprise LTSC 2024 is built on, has reported cases of LogonUI
    # clearing AutoAdminLogon on sign-out, tied to LSA protection and Credential
    # Guard. This writes the password as a plain registry string instead, the
    # way every autologon guide on the internet does it: anyone who can read the
    # registry as administrator can read the password. Opt in knowingly.
    [switch]$AllowPlaintext,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'

if (-not ('ConsolizeLsaSecret' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ConsolizeLsaSecret
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

    [DllImport("advapi32.dll", EntryPoint = "LsaStorePrivateData")]
    private static extern uint LsaDeletePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr data);

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

    public static void Delete(string key)
    {
        var attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));

        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, POLICY_CREATE_SECRET, out policy);
        if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));

        try
        {
            var k = MakeString(key);
            try
            {
                status = LsaDeletePrivateData(policy, ref k, IntPtr.Zero);
                if (status != 0)
                {
                    var error = LsaNtStatusToWinError(status);
                    if (error != 2) throw new Win32Exception((int)error); // already absent is success
                }
            }
            finally
            {
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
}

$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if ($Remove) {
    Set-ItemProperty $wl -Name AutoAdminLogon -Value '0' -Type String
    [ConsolizeLsaSecret]::Delete('DefaultPassword')
    foreach ($name in @('DefaultPassword', 'DefaultUserName', 'DefaultDomainName')) {
        Remove-ItemProperty $wl -Name $name -ErrorAction SilentlyContinue
    }
    Write-Host "Autologon disabled."
    return
}

if ([string]::IsNullOrWhiteSpace($UserName)) {
    throw 'UserName is required unless -Remove is used.'
}

$secure = if ($Password -and $Password.Length -gt 0) { $Password }
          else { Read-Host "Password for $Domain\$UserName" -AsSecureString }
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

[ConsolizeLsaSecret]::Store('DefaultPassword', $plain)

Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty $wl -Name DefaultUserName -Value $UserName -Type String
Set-ItemProperty $wl -Name DefaultDomainName -Value $Domain -Type String

if ($AllowPlaintext) {
    Set-ItemProperty $wl -Name DefaultPassword -Value $plain -Type String
    Write-Warning 'The password is also written to the registry in the clear (-AllowPlaintext).'
    Write-Warning 'Anyone who can read HKLM as administrator can read it.'
} else {
    # kill any cleartext leftover from other tools (GamesDows and friends)
    Remove-ItemProperty $wl -Name DefaultPassword -ErrorAction SilentlyContinue
}
$plain = $null

# Read back rather than assume: a wrong DefaultUserName looks configured and
# still leaves the machine sitting at a logon screen.
$check = Get-ItemProperty $wl
$problems = @()
if ($check.AutoAdminLogon -ne '1') { $problems += 'AutoAdminLogon is not 1' }
if ($check.DefaultUserName -ne $UserName) { $problems += "DefaultUserName is '$($check.DefaultUserName)', expected '$UserName'" }
if ($check.PSObject.Properties.Name -contains 'DefaultPassword') { $problems += 'a plaintext DefaultPassword is still present' }

$account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($account -and -not $account.PasswordLastSet) {
    $problems += "$UserName has never had a password set, so Windows will demand one at sign-in and autologon cannot happen"
}

if ($problems) {
    Write-Warning "Autologon may not work for $Domain\$UserName :"
    foreach ($p in $problems) { Write-Warning "  - $p" }
    Write-Warning 'If it still stops at the logon screen after a reboot, this build may be'
    Write-Warning 'clearing the setting (reported on 24H2, tied to LSA protection). Retry with:'
    Write-Warning "  .\set-autologon.ps1 -UserName $UserName -AllowPlaintext"
} else {
    Write-Host "Autologon set for $Domain\$UserName (password stored as LSA secret, not plaintext)."
    Write-Host 'Verified: AutoAdminLogon=1, DefaultUserName matches, no plaintext password.'
}
