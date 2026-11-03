using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Markup;

namespace RfqInstaller.Logging;

/// <summary>
/// Append-only installer log. Unexpected failures always go here so a silent UI crash
/// cannot happen again without a record on disk.
/// </summary>
public static class InstallerLog
{
    /// <summary>
    /// C:\ProgramData\RFQ Application Setup, the same for every account. Setup's first window runs
    /// as the signed-in user and its elevated one possibly as another account (whoever approved the
    /// administrator prompt), so a per-user folder splits one run's log across two profiles. Falls
    /// back to the per-user folder if the shared one can't be written.
    /// </summary>
    public static string LogDirectory { get; } = PickLogDirectory();

    public static string LogPath { get; } = Path.Combine(LogDirectory, "installer.log");

    public static string Write(string context, Exception? exception = null, string? extra = null)
    {
        Directory.CreateDirectory(LogDirectory);

        var body = BuildEntry(context, exception, extra);
        File.AppendAllText(LogPath, body);

        try
        {
            File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "crash.log"), body);
        }
        catch
        {
            // BaseDirectory may be locked or read-only; LocalAppData is the canonical copy.
        }

        return LogPath;
    }

    private static string PickLogDirectory()
    {
        var shared = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "RFQ Application Setup");
        try
        {
            var created = !Directory.Exists(shared);
            Directory.CreateDirectory(shared);
            if (created)
            {
                // Whoever creates it first, the other window's account must be able to append.
                TryOpenToAllUsers(shared);
            }

            File.AppendAllText(Path.Combine(shared, "installer.log"), string.Empty);
            return shared;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "RFQ Application Setup");
        }
    }

    private static void TryOpenToAllUsers(string directory)
    {
        try
        {
            RfqInstaller.Core.Security.FolderAccess.Grant(
                directory,
                System.Security.AccessControl.FileSystemRights.Modify,
                new[] { RfqInstaller.Core.Security.AccountIdentity.AuthenticatedUsers });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException
                                       or System.Security.Principal.IdentityNotMappedException)
        {
            // The log still works for this account; the other one falls back to its own folder.
        }
    }

    public static string FormatUserDetail(Exception exception)
    {
        var root = Unwrap(exception);
        var detail = $"{root.GetType().Name}: {root.Message}";

        if (!ReferenceEquals(root, exception) && !string.IsNullOrWhiteSpace(exception.Message)
            && !string.Equals(exception.Message, root.Message, StringComparison.Ordinal))
        {
            detail += $"{Environment.NewLine}{Environment.NewLine}{exception.GetType().Name}: {exception.Message}";
        }

        return detail;
    }

    public static Exception Unwrap(Exception exception)
    {
        var current = exception;
        while (current.InnerException is not null && current is XamlParseException or TargetInvocationException or AggregateException)
        {
            current = current is AggregateException aggregate
                ? aggregate.InnerException ?? aggregate.Flatten().InnerExceptions[0]
                : current.InnerException;
        }

        return current;
    }

    public static void TryOpenLog()
    {
        try
        {
            if (!File.Exists(LogPath))
            {
                return;
            }

            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(LogPath)
            {
                UseShellExecute = true
            });
        }
        catch
        {
            // Opening the log is best-effort; the path is still shown on the error page.
        }
    }

    private static string BuildEntry(string context, Exception? exception, string? extra)
    {
        var sb = new StringBuilder();
        sb.AppendLine("============================================================");
        sb.AppendLine($"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}");
        sb.AppendLine($"Context: {context}");
        sb.AppendLine($"App: {AppContext.BaseDirectory}");
        sb.AppendLine($"Version: {Assembly.GetExecutingAssembly().GetName().Version}");
        sb.AppendLine($"OS: {Environment.OSVersion}");
        sb.AppendLine($"64-bit process: {Environment.Is64BitProcess}");

        if (!string.IsNullOrWhiteSpace(extra))
        {
            sb.AppendLine();
            sb.AppendLine(extra);
        }

        if (exception is not null)
        {
            sb.AppendLine();
            sb.AppendLine(exception.ToString());
        }

        sb.AppendLine();
        return sb.ToString();
    }
}
