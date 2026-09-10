using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RfqInstaller.Core.Licensing;

public sealed class DeviceCredentialState
{
    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("device_uuid")]
    public required string DeviceUuid { get; set; }

    [JsonPropertyName("device_private_key")]
    public required string DevicePrivateKey { get; set; }

    [JsonPropertyName("refresh_generation")]
    public int RefreshGeneration { get; set; }

    [JsonPropertyName("refresh_token")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RefreshToken { get; set; }

    [JsonPropertyName("broker_device_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BrokerDeviceId { get; set; }

    // This marker is also used by the Python client to prevent replay after an
    // ambiguous refresh request outcome.
    [JsonPropertyName("refresh_pending_generation")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? RefreshPendingGeneration { get; set; }
}

public interface ILicenseCredentialStore
{
    Task<IDisposable> AcquireLockAsync(CancellationToken cancellationToken);
    DeviceCredentialState? Load();
    void Save(DeviceCredentialState state);
}

/// <summary>
/// Python-client-compatible machine credential storage. The on-disk value is
/// base64(DPAPI-LocalMachine(UTF8-JSON)).
/// </summary>
public sealed class WindowsDpapiCredentialStore : ILicenseCredentialStore
{
    private const uint CryptprotectLocalMachine = 0x4;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
    };

    private readonly string _path;
    private readonly string _lockPath;
    private readonly SemaphoreSlim _processLock = new(1, 1);

    public WindowsDpapiCredentialStore(string? path = null)
    {
        var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        _path = path ?? Path.Combine(programData, "RFQ", "license-client.dat");
        _lockPath = _path + ".lock";
    }

    public async Task<IDisposable> AcquireLockAsync(CancellationToken cancellationToken)
    {
        await _processLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        FileStream? stream = null;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            stream = new FileStream(_lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite);
            if (stream.Length == 0)
            {
                stream.WriteByte(0);
                stream.Flush(flushToDisk: true);
            }

            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    stream.Lock(0, 1);
                    return new StoreLock(stream, _processLock);
                }
                catch (IOException)
                {
                    await Task.Delay(100, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch
        {
            stream?.Dispose();
            _processLock.Release();
            throw;
        }
    }

    public DeviceCredentialState? Load()
    {
        if (!File.Exists(_path))
        {
            return null;
        }

        try
        {
            var encoded = File.ReadAllBytes(_path);
            var encrypted = Convert.FromBase64String(Encoding.ASCII.GetString(encoded));
            var plaintext = Unprotect(encrypted);
            var state = JsonSerializer.Deserialize<DeviceCredentialState>(plaintext, JsonOptions)
                ?? throw new InvalidDataException("Credential state is empty.");
            if (state.SchemaVersion != 1 || string.IsNullOrWhiteSpace(state.DeviceUuid) ||
                string.IsNullOrWhiteSpace(state.DevicePrivateKey))
            {
                throw new InvalidDataException("Credential state has an unsupported or incomplete schema.");
            }
            return state;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or FormatException or
                                   JsonException or CryptographicException)
        {
            throw new CredentialStoreException("Encrypted license state could not be read.", ex);
        }
    }

    public void Save(DeviceCredentialState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        try
        {
            var directory = Path.GetDirectoryName(_path)!;
            Directory.CreateDirectory(directory);
            var plaintext = JsonSerializer.SerializeToUtf8Bytes(state, JsonOptions);
            var encoded = Convert.ToBase64String(Protect(plaintext));
            var temporary = _path + ".tmp";

            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                var bytes = Encoding.ASCII.GetBytes(encoded);
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, _path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
        {
            throw new CredentialStoreException("Encrypted license state could not be persisted.", ex);
        }
    }

    private static byte[] Protect(byte[] plaintext) =>
        Transform(plaintext, decrypt: false, CryptprotectLocalMachine);

    private static byte[] Unprotect(byte[] encrypted) =>
        Transform(encrypted, decrypt: true, 0);

    private static byte[] Transform(byte[] input, bool decrypt, uint flags)
    {
        var inputPointer = Marshal.AllocHGlobal(input.Length);
        IntPtr description = IntPtr.Zero;
        try
        {
            Marshal.Copy(input, 0, inputPointer, input.Length);
            var inputBlob = new DataBlob { Size = input.Length, Data = inputPointer };
            DataBlob outputBlob;
            bool succeeded;
            if (decrypt)
            {
                succeeded = CryptUnprotectData(
                    ref inputBlob,
                    out description,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    flags,
                    out outputBlob);
            }
            else
            {
                succeeded = CryptProtectData(
                    ref inputBlob,
                    "RFQ License Client",
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    flags,
                    out outputBlob);
            }
            if (!succeeded)
            {
                throw new CryptographicException("Windows DPAPI operation failed.", new Win32Exception(Marshal.GetLastWin32Error()));
            }

            try
            {
                var output = new byte[outputBlob.Size];
                Marshal.Copy(outputBlob.Data, output, 0, output.Length);
                return output;
            }
            finally
            {
                if (outputBlob.Data != IntPtr.Zero)
                {
                    LocalFree(outputBlob.Data);
                }
            }
        }
        finally
        {
            if (description != IntPtr.Zero)
            {
                LocalFree(description);
            }
            CryptographicOperations.ZeroMemory(input);
            Marshal.Copy(input, 0, inputPointer, input.Length);
            Marshal.FreeHGlobal(inputPointer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob input,
        string? description,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        uint flags,
        out DataBlob output);

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(
        ref DataBlob input,
        out IntPtr description,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        uint flags,
        out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    private sealed class StoreLock(FileStream stream, SemaphoreSlim processLock) : IDisposable
    {
        public void Dispose()
        {
            try
            {
                stream.Unlock(0, 1);
            }
            finally
            {
                try
                {
                    stream.Dispose();
                }
                finally
                {
                    processLock.Release();
                }
            }
        }
    }
}

public sealed class CredentialStoreException(string message, Exception? innerException = null)
    : Exception(message, innerException);
