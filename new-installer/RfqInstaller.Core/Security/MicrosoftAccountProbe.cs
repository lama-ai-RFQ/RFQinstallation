using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32;

namespace RfqInstaller.Core.Security;

/// <summary>
/// Detects a local SAM user linked to a Microsoft account, and the email Windows uses for that
/// account. The service is still configured as .\localuser (same as the old installer); the email
/// is only needed so LogonUser can check the password against MicrosoftAccount\email rather than
/// against the local SAM name, which rejects a correct Microsoft password.
/// </summary>
[SupportedOSPlatform("windows")]
public static class MicrosoftAccountProbe
{
    private const int UserInfoLevel24 = 24;

    public static bool IsCurrentUserMicrosoftAccount()
    {
        return IsMicrosoftAccount(LocalSamName());
    }

    public static bool IsMicrosoftAccount(string localUserName)
    {
        return TryGetInternetIdentity(localUserName, out _) || Emails().Any();
    }

    public static IReadOnlyList<string> Emails()
    {
        var emails = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void Add(string? value)
        {
            var email = value?.Trim();
            if (string.IsNullOrWhiteSpace(email) || !email.Contains('@', StringComparison.Ordinal) || !seen.Add(email))
            {
                return;
            }

            emails.Add(email);
        }

        if (TryGetInternetIdentity(LocalSamName(), out var principal))
        {
            Add(principal);
        }

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Microsoft\IdentityCRL\UserExtendedProperties");
            if (key is not null)
            {
                foreach (var name in key.GetSubKeyNames())
                {
                    Add(name);
                }
            }
        }
        catch (Exception)
        {
            // Registry may be missing or unreadable when elevated as a different user.
        }

        return emails;
    }

    private static string LocalSamName()
    {
        var user = Environment.UserName;
        var slash = user.LastIndexOf('\\');
        return slash >= 0 && slash < user.Length - 1 ? user[(slash + 1)..] : user;
    }

    private static bool TryGetInternetIdentity(string localUserName, out string? principal)
    {
        principal = null;
        if (string.IsNullOrWhiteSpace(localUserName))
        {
            return false;
        }

        if (NetUserGetInfo(null, localUserName, UserInfoLevel24, out var buffer) != 0 || buffer == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            var info = Marshal.PtrToStructure<UserInfo24>(buffer);
            if (info.InternetIdentity == 0)
            {
                return false;
            }

            principal = Marshal.PtrToStringUni(info.InternetPrincipalName);
            return true;
        }
        finally
        {
            NetApiBufferFree(buffer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct UserInfo24
    {
        public int InternetIdentity;
        public uint Flags;
        public IntPtr InternetProviderName;
        public IntPtr InternetPrincipalName;
        public IntPtr UserSid;
    }

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetUserGetInfo(string? serverName, string userName, int level, out IntPtr bufPtr);

    [DllImport("netapi32.dll")]
    private static extern int NetApiBufferFree(IntPtr buffer);
}
