using System.Runtime.Versioning;
using System.Security.Principal;

namespace RfqInstaller.Core.Security;

/// <summary>
/// Which Windows account is which. Setup can run as a different account than the one signed in
/// (a standard user approving the admin prompt with another account's password), and the RFQ
/// services can run as a third. Names like ".\JT" or "MicrosoftAccount\name@example.com" are
/// compared by SID, never as strings.
/// </summary>
[SupportedOSPlatform("windows")]
public static class AccountIdentity
{
    public static SecurityIdentifier LocalSystem { get; } = new(WellKnownSidType.LocalSystemSid, null);

    public static SecurityIdentifier NetworkService { get; } = new(WellKnownSidType.NetworkServiceSid, null);

    public static SecurityIdentifier Administrators { get; } = new(WellKnownSidType.BuiltinAdministratorsSid, null);

    public static SecurityIdentifier AuthenticatedUsers { get; } = new(WellKnownSidType.AuthenticatedUserSid, null);

    /// <summary>The account this process runs as: after elevation, the account that approved the prompt.</summary>
    public static SecurityIdentifier CurrentSid()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return identity.User ?? throw new InvalidOperationException("The current Windows account has no SID.");
    }

    public static string CurrentName()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return identity.Name;
    }

    /// <summary>
    /// The SID for an account name as the wizard or NSSM writes it, or null if Windows can't
    /// resolve it. A leading ".\" means this computer.
    /// </summary>
    public static SecurityIdentifier? TryResolve(string? accountName)
    {
        if (string.IsNullOrWhiteSpace(accountName))
        {
            return null;
        }

        var name = accountName.Trim();
        if (name.StartsWith(@".\", StringComparison.Ordinal))
        {
            name = Environment.MachineName + name[1..];
        }

        if (string.Equals(name, "LocalSystem", StringComparison.OrdinalIgnoreCase))
        {
            return LocalSystem;
        }

        try
        {
            return (SecurityIdentifier)new NTAccount(name).Translate(typeof(SecurityIdentifier));
        }
        catch (Exception ex) when (ex is IdentityNotMappedException or SystemException)
        {
            return null;
        }
    }

    /// <summary>A readable DOMAIN\name for a SID, falling back to the SID itself.</summary>
    public static string DisplayName(SecurityIdentifier sid)
    {
        try
        {
            return sid.Translate(typeof(NTAccount)).Value;
        }
        catch (Exception ex) when (ex is IdentityNotMappedException or SystemException)
        {
            return sid.Value;
        }
    }
}
