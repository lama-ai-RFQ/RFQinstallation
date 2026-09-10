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
    private const int ErrorLogonFailure = 1326;
    private const int Logon32LogonInteractive = 2;
    private const int Logon32LogonNetwork = 3;
    private const int Logon32LogonBatch = 4;
    private const int Logon32LogonService = 5;
    private const int Logon32LogonNetworkCleartext = 8;
    private const int Logon32ProviderDefault = 0;
    private const int Logon32ProviderWinNt50 = 3;
    private const int MaxUserName = 513;
    private const int MaxDomain = 337;
    private const int MaxPassword = 512;

    public static WindowsAccountCredentials? Request(IntPtr ownerHwnd, string? suggestedAccount = null)
    {
        var account = AccountForPrompt(string.IsNullOrWhiteSpace(suggestedAccount)
            ? CurrentLogonName()
            : suggestedAccount);

        var previousFailed = false;
        while (true)
        {
            var entered = PromptOnce(ownerHwnd, account, previousFailed);
            if (entered is null)
            {
                return null;
            }

            // Keep the local Windows user on the next prompt. Do not pack
            // MicrosoftAccount\email, and do not rewrite ANASTASIA\anast to .\anast
            // until the password has been accepted.
            account = AccountForPrompt(entered.AccountName);
            if (TryValidateLogon(entered, out var logonError))
            {
                return entered with { AccountName = ToServiceAccountName(entered.AccountName) };
            }

            DiagnoseFailedLogon(entered, logonError);
            previousFailed = true;
        }
    }

    private static WindowsAccountCredentials? PromptOnce(IntPtr ownerHwnd, string account, bool previousFailed)
    {
        var info = new CredUiInfo
        {
            cbSize = Marshal.SizeOf<CredUiInfo>(),
            hwndParent = ownerHwnd,
            pszMessageText = previousFailed
                ? $"The password was not accepted. Enter the Windows password for {account} (not a PIN)."
                : $"Enter the Windows password for {account} (not a PIN).",
            pszCaptionText = "Windows Security",
            hbmBanner = IntPtr.Zero,
        };

        var inBuffer = PackUserName(account, out var inSize);
        uint authPackage = 0;
        var save = false;

        // dwAuthError must stay 0. A real Win32 error makes this dialog drop the user
        // tile and replace our message with Windows's Microsoft-account error text.
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

    private static bool TryValidateLogon(WindowsAccountCredentials credentials, out int win32Error)
    {
        win32Error = ErrorLogonFailure;
        SplitAccount(credentials.AccountName, out var domain, out var user);

        foreach (var logonType in new[]
                 {
                     Logon32LogonNetworkCleartext,
                     Logon32LogonInteractive,
                     Logon32LogonService,
                     Logon32LogonBatch,
                     Logon32LogonNetwork,
                 })
        {
            foreach (var provider in new[] { Logon32ProviderDefault, Logon32ProviderWinNt50 })
            {
                foreach (var (tryDomain, tryUser) in LogonIdentities(domain, user))
                {
                    if (LogonUser(tryUser, tryDomain, credentials.Password, logonType, provider, out var token))
                    {
                        CloseHandle(token);
                        win32Error = 0;
                        return true;
                    }

                    win32Error = Marshal.GetLastWin32Error();
                }
            }
        }

        return false;
    }

    private static IEnumerable<(string? Domain, string User)> LogonIdentities(string domain, string user)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        bool Take(string? tryDomain, string tryUser)
        {
            return !string.IsNullOrEmpty(tryUser) && seen.Add($"{tryDomain ?? "<null>"}\\{tryUser}");
        }

        foreach (var email in MicrosoftAccountProbe.Emails())
        {
            if (Take("MicrosoftAccount", email))
            {
                yield return ("MicrosoftAccount", email);
            }

            if (Take(null, email))
            {
                yield return (null, email);
            }
        }

        foreach (var tryDomain in new[] { domain, ".", Environment.MachineName, "MicrosoftAccount" })
        {
            if (string.IsNullOrEmpty(tryDomain) || !Take(tryDomain, user))
            {
                continue;
            }

            yield return (tryDomain, user);
        }
    }

    /// <summary>
    /// Pack the local Windows user for the dialog. MicrosoftAccount\email is only used
    /// inside LogonUser, never as the name shown/prefilled in Windows Security.
    /// </summary>
    private static string AccountForPrompt(string account)
    {
        SplitAccount(account, out var domain, out var user);
        if (user.Contains('@', StringComparison.Ordinal)
            || domain.Equals("MicrosoftAccount", StringComparison.OrdinalIgnoreCase)
            || domain.Equals("AzureAD", StringComparison.OrdinalIgnoreCase))
        {
            return CurrentLogonName();
        }

        return string.IsNullOrWhiteSpace(account) ? CurrentLogonName() : account.Trim();
    }

    private static void SplitAccount(string account, out string domain, out string user)
    {
        var slash = account.LastIndexOf('\\');
        if (slash > 0 && slash < account.Length - 1)
        {
            domain = account[..slash];
            user = account[(slash + 1)..];
            if (domain == ".")
            {
                domain = Environment.MachineName;
            }

            return;
        }

        domain = Environment.UserDomainName;
        user = account;
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
        foreach (var flags in new[] { CredPackGenericCredentials, 0u })
        {
            if (TryUnpack(buffer, size, flags, out var credentials) &&
                credentials is not null &&
                !string.IsNullOrEmpty(credentials.Password))
            {
                return credentials;
            }
        }

        throw new InvalidOperationException($"Could not read the Windows credentials (error {Marshal.GetLastWin32Error()}).");
    }

    private static bool TryUnpack(IntPtr buffer, uint size, uint flags, out WindowsAccountCredentials? credentials)
    {
        credentials = null;
        var user = new StringBuilder(MaxUserName);
        var domain = new StringBuilder(MaxDomain);
        var password = new StringBuilder(MaxPassword);
        var userLen = user.Capacity;
        var domainLen = domain.Capacity;
        var passwordLen = password.Capacity;

        if (!CredUnPackAuthenticationBuffer(
                flags,
                buffer,
                size,
                user,
                ref userLen,
                domain,
                ref domainLen,
                password,
                ref passwordLen))
        {
            return false;
        }

        var userName = user.ToString();
        var domainName = domain.ToString();
        var packed = string.IsNullOrEmpty(domainName) || userName.Contains('\\', StringComparison.Ordinal)
            ? userName
            : $"{domainName}\\{userName}";

        credentials = new WindowsAccountCredentials(packed.Trim(), password.ToString());
        return true;
    }

    private static string CurrentLogonName()
    {
        var local = FirstLocalUserName(SessionUserName(), Environment.UserName);
        var domain = Environment.UserDomainName;
        return string.IsNullOrWhiteSpace(domain) ? $".\\{local}" : $"{domain}\\{local}";
    }

    /// <summary>
    /// Matches the old installer: local / Microsoft-linked accounts become ".\user" (NSSM's
    /// preferred form). Domain accounts stay "DOMAIN\user".
    /// </summary>
    private static string ToServiceAccountName(string account)
    {
        var trimmed = account.Trim();
        SplitAccount(trimmed, out var domain, out var user);

        if (string.IsNullOrWhiteSpace(user) || user.Contains('@', StringComparison.Ordinal))
        {
            user = FirstLocalUserName(SessionUserName(), Environment.UserName);
            domain = Environment.MachineName;
        }

        if (domain.Equals("MicrosoftAccount", StringComparison.OrdinalIgnoreCase)
            || domain.Equals("AzureAD", StringComparison.OrdinalIgnoreCase)
            || domain.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase)
            || domain == ".")
        {
            return $".\\{user}";
        }

        return $"{domain}\\{user}";
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

    private static void DiagnoseFailedLogon(WindowsAccountCredentials credentials, int win32Error)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "RFQ Application Setup");
            Directory.CreateDirectory(dir);
            var emails = string.Join(", ", MicrosoftAccountProbe.Emails());
            var line =
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] service-account: typed={credentials.AccountName}; " +
                $"passwordChars={credentials.Password.Length}; emails=[{emails}]; win32={win32Error} {FormatWin32(win32Error)}" +
                Environment.NewLine;
            File.AppendAllText(Path.Combine(dir, "installer.log"), line);
        }
        catch
        {
            // Diagnostics must never break the prompt.
        }
    }

    private static string FormatWin32(int error)
    {
        var buffer = new StringBuilder(512);
        var length = FormatMessage(
            0x00001000 /* FORMAT_MESSAGE_FROM_SYSTEM */,
            IntPtr.Zero,
            (uint)error,
            0,
            buffer,
            buffer.Capacity,
            IntPtr.Zero);
        return length == 0 ? string.Empty : buffer.ToString().Trim();
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

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(
        string lpszUsername,
        string? lpszDomain,
        string lpszPassword,
        int dwLogonType,
        int dwLogonProvider,
        out IntPtr phToken);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int FormatMessage(
        uint dwFlags,
        IntPtr lpSource,
        uint dwMessageId,
        uint dwLanguageId,
        StringBuilder lpBuffer,
        int nSize,
        IntPtr arguments);
}
