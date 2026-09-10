using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace RfqInstaller.Core.Security;

/// <summary>
/// Grants SeServiceLogonRight so a named user account can be used as a Windows service logon.
/// Best-effort: if this fails, NSSM's ObjectName set may still fail with a clear error.
/// </summary>
[SupportedOSPlatform("windows")]
public static class ServiceLogonRight
{
    private const int ErrorInsufficientBuffer = 122;
    private const uint PolicyCreateAccount = 0x0010;
    private const uint PolicyLookupNames = 0x0800;

    public static void TryGrant(string accountName)
    {
        if (string.IsNullOrWhiteSpace(accountName))
        {
            return;
        }

        var sidLen = 0;
        var domainLen = 0;
        LookupAccountNameW(null, accountName, IntPtr.Zero, ref sidLen, null, ref domainLen, out _);
        if (Marshal.GetLastWin32Error() != ErrorInsufficientBuffer || sidLen <= 0)
        {
            return;
        }

        var sid = Marshal.AllocHGlobal(sidLen);
        var domain = new StringBuilder(Math.Max(domainLen, 1));
        var access = new LsaObjectAttributes();
        var policy = IntPtr.Zero;
        var rightBuffer = IntPtr.Zero;
        try
        {
            if (!LookupAccountNameW(null, accountName, sid, ref sidLen, domain, ref domainLen, out _))
            {
                return;
            }

            if (LsaOpenPolicy(IntPtr.Zero, ref access, PolicyCreateAccount | PolicyLookupNames, out policy) != 0)
            {
                return;
            }

            var right = new LsaUnicodeString
            {
                Length = (ushort)("SeServiceLogonRight".Length * 2),
                MaximumLength = (ushort)(("SeServiceLogonRight".Length + 1) * 2),
                Buffer = Marshal.StringToHGlobalUni("SeServiceLogonRight"),
            };
            rightBuffer = right.Buffer;
            _ = LsaAddAccountRights(policy, sid, ref right, 1);
        }
        finally
        {
            if (rightBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(rightBuffer);
            }

            if (policy != IntPtr.Zero)
            {
                LsaClose(policy);
            }

            Marshal.FreeHGlobal(sid);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaObjectAttributes
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaUnicodeString
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LookupAccountNameW(
        string? lpSystemName,
        string lpAccountName,
        IntPtr Sid,
        ref int cbSid,
        StringBuilder? ReferencedDomainName,
        ref int cchReferencedDomainName,
        out int peUse);

    [DllImport("advapi32.dll")]
    private static extern uint LsaOpenPolicy(IntPtr systemName, ref LsaObjectAttributes objectAttributes, uint desiredAccess, out IntPtr policyHandle);

    [DllImport("advapi32.dll")]
    private static extern uint LsaAddAccountRights(IntPtr policyHandle, IntPtr accountSid, ref LsaUnicodeString userRights, uint countOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr policyHandle);
}
