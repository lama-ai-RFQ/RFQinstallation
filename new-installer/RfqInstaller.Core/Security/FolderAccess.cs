using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace RfqInstaller.Core.Security;

/// <summary>
/// Folder permissions the install needs but Windows doesn't give it by default.
///
/// initdb and the PostgreSQL service drop administrator rights before they touch any file: they
/// run with a restricted token in which the Administrators group no longer grants access. So a
/// folder only administrators can write, such as anything under Program Files, or another user's
/// profile, is closed to them even when Setup itself runs elevated. Access has to be granted to
/// the account itself.
/// </summary>
[SupportedOSPlatform("windows")]
public static class FolderAccess
{
    /// <summary>
    /// Creates <paramref name="path"/> (if missing) with only the given accounts on its access
    /// list, nothing inherited from its parent. Used for pgdata, which holds the password hashes of
    /// every database login and must not inherit, say, read access for all users of the machine.
    /// The directory must be empty or new: an existing folder's contents keep their own ACLs.
    /// </summary>
    public static void CreatePrivateDirectory(string path, IEnumerable<SecurityIdentifier> fullControl)
    {
        var directory = new DirectoryInfo(path);
        if (!directory.Exists)
        {
            directory.Create();
        }

        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in fullControl.Distinct())
        {
            security.AddAccessRule(Rule(sid, FileSystemRights.FullControl));
        }

        directory.SetAccessControl(security);
    }

    /// <summary>Adds an inheritable allow rule for each account, keeping everything already on the folder.</summary>
    public static void Grant(string path, FileSystemRights rights, IEnumerable<SecurityIdentifier> accounts)
    {
        var directory = new DirectoryInfo(path);
        var security = directory.GetAccessControl(AccessControlSections.Access);
        var changed = false;
        foreach (var sid in accounts.Distinct())
        {
            if (!HasRights(security, sid, rights))
            {
                security.AddAccessRule(Rule(sid, rights));
                changed = true;
            }
        }

        if (changed)
        {
            directory.SetAccessControl(security);
        }
    }

    /// <summary>One line per allow/deny rule, for diagnostics.</summary>
    public static IReadOnlyList<string> Describe(string path)
    {
        var security = new DirectoryInfo(path).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        var lines = new List<string>();
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        lines.Add($"owner: {(owner is null ? "unknown" : AccountIdentity.DisplayName(owner))}" +
                  (security.AreAccessRulesProtected ? ", not inherited" : ""));
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            var sid = (SecurityIdentifier)rule.IdentityReference;
            lines.Add($"{rule.AccessControlType}: {AccountIdentity.DisplayName(sid)} {rule.FileSystemRights}" +
                      (rule.IsInherited ? " (inherited)" : ""));
        }

        return lines;
    }

    private static FileSystemAccessRule Rule(SecurityIdentifier sid, FileSystemRights rights) => new(
        sid,
        rights,
        InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
        PropagationFlags.None,
        AccessControlType.Allow);

    private static bool HasRights(DirectorySecurity security, SecurityIdentifier sid, FileSystemRights rights)
    {
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType == AccessControlType.Allow &&
                sid.Equals(rule.IdentityReference) &&
                (rule.FileSystemRights & rights) == rights &&
                rule.InheritanceFlags.HasFlag(InheritanceFlags.ContainerInherit) &&
                rule.InheritanceFlags.HasFlag(InheritanceFlags.ObjectInherit))
            {
                return true;
            }
        }

        return false;
    }
}
