using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using Microsoft.Win32;

namespace RfqInstaller.Core.Security;

/// <summary>The account signed in to the Windows session Setup was started from.</summary>
public sealed record SignedInAccount(string Sid, string Name, string? DesktopDirectory);

/// <summary>
/// Who is signed in to this Windows session, which is not always who Setup runs as. When a
/// standard user starts Setup and another account approves the administrator prompt, Setup runs
/// as that other account: its desktop, Credential Manager and profile are not the signed-in
/// user's. The session's user is the person who will use RFQ Application.
/// </summary>
[SupportedOSPlatform("windows")]
public static class SignedInUser
{
    private const int WtsUserName = 5;
    private const int WtsDomainName = 7;
    private static readonly IntPtr WtsCurrentServerHandle = IntPtr.Zero;
    private const int WtsCurrentSession = -1;

    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(
        IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    /// <summary>
    /// The session's signed-in account, with its desktop folder: this process's own desktop when
    /// it is also the account Setup runs as, otherwise the one in that account's profile. Falls
    /// back to the account Setup runs as when the session can't be queried.
    /// </summary>
    public static SignedInAccount Detect()
    {
        var current = AccountIdentity.CurrentSid();
        var sessionSid = AccountIdentity.TryResolve(SessionAccountName()) ?? current;
        var desktop = sessionSid.Equals(current)
            ? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory)
            : DesktopFromProfile(sessionSid);
        return new SignedInAccount(sessionSid.Value, AccountIdentity.DisplayName(sessionSid), desktop);
    }

    public static bool IsSetupAccount(string? sid) =>
        string.IsNullOrWhiteSpace(sid) || AccountIdentity.CurrentSid().Value.Equals(sid, StringComparison.OrdinalIgnoreCase);

    private static string? SessionAccountName()
    {
        var user = Query(WtsUserName);
        if (string.IsNullOrWhiteSpace(user))
        {
            return null;
        }

        var domain = Query(WtsDomainName);
        return string.IsNullOrWhiteSpace(domain) ? user : $@"{domain}\{user}";
    }

    private static string? Query(int infoClass)
    {
        try
        {
            if (!WTSQuerySessionInformationW(WtsCurrentServerHandle, WtsCurrentSession, infoClass, out var buffer, out _))
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
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            return null;
        }
    }

    /// <summary>
    /// Another account's Desktop folder, from its profile. A desktop moved into OneDrive is found
    /// through the user's shell folders only while their registry hive is loaded, which it is
    /// while they are signed in.
    /// </summary>
    private static string? DesktopFromProfile(SecurityIdentifier sid)
    {
        try
        {
            using (var shellFolders = Registry.Users.OpenSubKey(
                       $@"{sid.Value}\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"))
            {
                if (shellFolders?.GetValue("Desktop", null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string raw &&
                    raw.Length > 0)
                {
                    var profile = ProfilePath(sid);
                    var expanded = profile is null
                        ? raw
                        : raw.Replace("%USERPROFILE%", profile, StringComparison.OrdinalIgnoreCase);
                    if (!expanded.Contains('%') && Directory.Exists(expanded))
                    {
                        return expanded;
                    }
                }
            }

            var profilePath = ProfilePath(sid);
            var desktop = profilePath is null ? null : Path.Combine(profilePath, "Desktop");
            return desktop is not null && Directory.Exists(desktop) ? desktop : null;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    private static string? ProfilePath(SecurityIdentifier sid)
    {
        using var profile = Registry.LocalMachine.OpenSubKey(
            $@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{sid.Value}");
        return profile?.GetValue("ProfileImagePath") is string path ? Environment.ExpandEnvironmentVariables(path) : null;
    }
}
