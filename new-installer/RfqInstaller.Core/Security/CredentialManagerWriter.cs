using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace RfqInstaller.Core.Security;

/// <summary>
/// Best-effort convenience copy of generated secrets into the installing admin's own Windows
/// Credential Manager (via the CredWrite Win32 API), so they can inspect them via Control Panel
/// exactly as validated by the existing test_credential_manager.ps1 script. This is NOT the
/// authoritative store — the app reads secrets.dat (see SecretStore) at runtime, because the
/// service normally runs as LocalSystem, which cannot access a user's Credential Manager. A
/// failure here is logged and ignored; it never blocks install.
/// </summary>
[SupportedOSPlatform("windows")]
public static class CredentialManagerWriter
{
    private const int CRED_TYPE_GENERIC = 1;
    private const int CRED_PERSIST_LOCAL_MACHINE = 2;

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

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite([In] ref CREDENTIAL credential, uint flags);

    /// <summary>Returns true on success; never throws — callers should treat this as best-effort.</summary>
    public static bool TryWrite(string targetName, string userName, string password)
    {
        var passwordBytes = System.Text.Encoding.Unicode.GetBytes(password);
        var blobPtr = Marshal.AllocHGlobal(passwordBytes.Length);
        try
        {
            Marshal.Copy(passwordBytes, 0, blobPtr, passwordBytes.Length);

            var credential = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = targetName,
                CredentialBlobSize = (uint)passwordBytes.Length,
                CredentialBlob = blobPtr,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = userName,
            };

            return CredWrite(ref credential, 0);
        }
        catch
        {
            return false;
        }
        finally
        {
            Marshal.FreeHGlobal(blobPtr);
        }
    }
}
