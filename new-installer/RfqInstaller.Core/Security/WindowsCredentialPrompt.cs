using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace RfqInstaller.Core.Security;

public sealed record WindowsAccountCredentials(string AccountName, string Password);

/// <summary>
/// Shows the current-OS Windows Security dialog via credui's
/// <c>CredUIPromptForWindowsCredentials</c> (the Vista+ API, not the old
/// CredUIPromptForCredentials dialog). The password is returned only long enough
/// to pass to NSSM, which stores it in LSA.
/// </summary>
[SupportedOSPlatform("windows")]
public static class WindowsCredentialPrompt
{
    private const uint CredUiWinGeneric = 0x1;
    private const uint CredPackGenericCredentials = 0x4;
    private const int WtsCurrentSession = -1;
    private const int WtsUserName = 5;
    private const int ErrorCancelled = 1223;
    private const int MaxUserName = 513;
    private const int MaxDomain = 337;
    private const int MaxPassword = 256;

    public static WindowsAccountCredentials? Request(IntPtr ownerHwnd, string? suggestedAccount = null)
    {
        var account = string.IsNullOrWhiteSpace(suggestedAccount)
            ? CurrentLogonName()
            : suggestedAccount;

        var info = new CredUiInfo
        {
            cbSize = Marshal.SizeOf<CredUiInfo>(),
            hwndParent = ownerHwnd,
            pszMessageText = "Enter the password for this account so the service can use Windows Credential Manager.",
            pszCaptionText = "Windows Security",
            hbmBanner = IntPtr.Zero,
        };

        var inBuffer = PackUserName(account, out var inSize);
        uint authPackage = 0;
        var save = false;

        var result = CredUIPromptForWindowsCredentials(
            ref info,
            0,
            ref authPackage,
            inBuffer,
            (uint)inSize,
            out var outBuffer,
            out var outSize,
            ref save,
            CredUiWinGeneric);

        if (inBuffer != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(inBuffer);
        }

        if (result == ErrorCancelled)
        {
            return null;
        }

        if (result != 0 || outBuffer == IntPtr.Zero)
        {
            throw new InvalidOperationException($"Windows credential dialog failed (error {result}).");
        }

        try
        {
            return Unpack(outBuffer, outSize);
        }
        finally
        {
            ZeroAndFree(outBuffer, outSize);
        }
    }

    private static void ZeroAndFree(IntPtr buffer, uint size)
    {
        if (buffer == IntPtr.Zero)
        {
            return;
        }

        for (var i = 0; i < size; i++)
        {
            Marshal.WriteByte(buffer, i, 0);
        }

        Marshal.FreeCoTaskMem(buffer);
    }

    private static WindowsAccountCredentials Unpack(IntPtr buffer, uint size)
    {
        var userLen = MaxUserName;
        var domainLen = MaxDomain;
        var passwordLen = MaxPassword;
        var user = new StringBuilder(userLen);
        var domain = new StringBuilder(domainLen);
        var password = new StringBuilder(passwordLen);

        if (!CredUnPackAuthenticationBuffer(
                CredPackGenericCredentials,
                buffer,
                size,
                user,
                ref userLen,
                domain,
                ref domainLen,
                password,
                ref passwordLen))
        {
            throw new InvalidOperationException($"Could not read the Windows credentials (error {Marshal.GetLastWin32Error()}).");
        }

        var userName = user.ToString();
        var domainName = domain.ToString();
        var account = string.IsNullOrEmpty(domainName) || userName.Contains('\\', StringComparison.Ordinal)
            ? userName
            : $"{domainName}\\{userName}";

        return new WindowsAccountCredentials(ToServiceAccountName(account), password.ToString());
    }

    private static string CurrentLogonName()
    {
        var local = FirstLocalUserName(SessionUserName(), Environment.UserName);
        var domain = Environment.UserDomainName;
        return string.IsNullOrWhiteSpace(domain) ? local : $"{domain}\\{local}";
    }

    /// <summary>
    /// Preserves whatever the admin actually entered/confirmed in the dialog — "DOMAIN\user",
    /// ".\user", or a bare "user" (treated as local, same convention the old installer's
    /// "DOMAIN\User (or .\User)" prompt used) — instead of collapsing every account to a local
    /// one. A real domain account must stay a domain account, or the service logon will fail on
    /// a domain-joined machine. Only Microsoft Account / Azure AD / UPN identities are rejected
    /// here, since those genuinely cannot be used as a classic Windows service logon account at
    /// all (falling back silently to *some* account would be worse than being explicit about it).
    /// </summary>
    private static string ToServiceAccountName(string account)
    {
        var trimmed = account.Trim();

        if (IsIncompatibleIdentity(trimmed))
        {
            return FallbackAccountName();
        }

        if (trimmed.Contains('\\', StringComparison.Ordinal))
        {
            return trimmed; // "DOMAIN\user" or ".\user" exactly as entered.
        }

        return $".\\{trimmed}"; // bare "user" -- assume local, matching the old ".\User" convention.
    }

    private static string FallbackAccountName()
    {
        var local = FirstLocalUserName(SessionUserName(), Environment.UserName);
        var domain = Environment.UserDomainName;
        return string.IsNullOrWhiteSpace(domain) ? $".\\{local}" : $"{domain}\\{local}";
    }

    private static bool IsIncompatibleIdentity(string account)
    {
        var slash = account.LastIndexOf('\\');
        var domain = slash > 0 ? account[..slash] : null;
        var name = slash >= 0 ? account[(slash + 1)..] : account;

        return name.Contains('@', StringComparison.Ordinal)
            || (domain is not null &&
                (domain.Equals("MicrosoftAccount", StringComparison.OrdinalIgnoreCase)
                 || domain.Equals("AzureAD", StringComparison.OrdinalIgnoreCase)));
    }

    private static string FirstLocalUserName(params string?[] candidates)
    {
        foreach (var candidate in candidates)
        {
            var name = LocalUserPart(candidate);
            if (!string.IsNullOrWhiteSpace(name))
            {
                return name;
            }
        }

        return Environment.UserName;
    }

    private static string? LocalUserPart(string? account)
    {
        if (string.IsNullOrWhiteSpace(account))
        {
            return null;
        }

        var name = account.Trim();
        var slash = name.LastIndexOf('\\');
        if (slash >= 0 && slash < name.Length - 1)
        {
            name = name[(slash + 1)..];
        }

        return name.Contains('@', StringComparison.Ordinal) || string.IsNullOrWhiteSpace(name) ? null : name;
    }

    private static string? SessionUserName()
    {
        if (!WTSQuerySessionInformation(IntPtr.Zero, WtsCurrentSession, WtsUserName, out var buffer, out _))
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStringUni(buffer);
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }

    private static IntPtr PackUserName(string account, out int size)
    {
        size = 0;
        if (string.IsNullOrWhiteSpace(account))
        {
            return IntPtr.Zero;
        }

        if (!CredPackAuthenticationBuffer(CredPackGenericCredentials, account, string.Empty, IntPtr.Zero, ref size))
        {
            var error = Marshal.GetLastWin32Error();
            if (error is not 122 and not 234 || size <= 0)
            {
                return IntPtr.Zero;
            }
        }

        var buffer = Marshal.AllocHGlobal(size);
        if (!CredPackAuthenticationBuffer(CredPackGenericCredentials, account, string.Empty, buffer, ref size))
        {
            Marshal.FreeHGlobal(buffer);
            size = 0;
            return IntPtr.Zero;
        }

        return buffer;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CredUiInfo
    {
        public int cbSize;
        public IntPtr hwndParent;
        public string pszMessageText;
        public string pszCaptionText;
        public IntPtr hbmBanner;
    }

    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WTSQuerySessionInformation(
        IntPtr hServer,
        int sessionId,
        int wtsInfoClass,
        out IntPtr ppBuffer,
        out int pBytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr pMemory);

    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    private static extern uint CredUIPromptForWindowsCredentials(
        ref CredUiInfo pUiInfo,
        uint dwAuthError,
        ref uint pulAuthPackage,
        IntPtr pvInAuthBuffer,
        uint ulInAuthBufferSize,
        out IntPtr ppvOutAuthBuffer,
        out uint pulOutAuthBufferSize,
        ref bool pfSave,
        uint dwFlags);

    [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredUnPackAuthenticationBuffer(
        uint dwFlags,
        IntPtr pAuthBuffer,
        uint cbAuthBuffer,
        StringBuilder pszUserName,
        ref int pcchMaxUserName,
        StringBuilder pszDomain,
        ref int pcchMaxDomain,
        StringBuilder pszPassword,
        ref int pcchMaxPassword);

    [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredPackAuthenticationBuffer(
        uint dwFlags,
        string pszUserName,
        string pszPassword,
        IntPtr pPackedCredentials,
        ref int pcbPackedCredentials);
}
