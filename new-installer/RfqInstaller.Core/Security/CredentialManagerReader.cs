using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace RfqInstaller.Core.Security;

/// <summary>
/// Reads a generic credential back out of Windows Credential Manager (CredRead Win32 API) — the
/// counterpart to CredentialManagerWriter. Needed so an admin running as Current User can recover
/// a stored DB password later (manual pgAdmin work, backups, ...), the same way Windows' own
/// Credential Manager Control Panel applet already lets them do via "Show" + re-authentication —
/// this exists so StoredCredentialsResolver can offer a single "view stored credentials" experience
/// without sending the admin to a different UI for the Credential Manager case specifically.
/// </summary>
[SupportedOSPlatform("windows")]
public static class CredentialManagerReader
{
    private const int CRED_TYPE_GENERIC = 1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string targetName, uint type, uint reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredFree")]
    private static extern void CredFree(IntPtr credentialPtr);

    /// <summary>Returns the stored password, or null if not found/unreadable. Never throws.</summary>
    public static string? TryRead(string targetName)
    {
        if (!CredRead(targetName, CRED_TYPE_GENERIC, 0, out var credentialPtr))
        {
            return null;
        }

        try
        {
            var credential = Marshal.PtrToStructure<CREDENTIAL>(credentialPtr);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return null;
            }

            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return System.Text.Encoding.Unicode.GetString(bytes);
        }
        catch
        {
            return null;
        }
        finally
        {
            CredFree(credentialPtr);
        }
    }
}
