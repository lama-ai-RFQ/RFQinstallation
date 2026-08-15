using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Markup;

namespace RfqInstaller.Demo.Logging;

/// <summary>
/// Append-only installer log. Unexpected failures always go here so a silent UI crash
/// cannot happen again without a record on disk.
/// </summary>
public static class InstallerLog
{
    public static string LogDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RFQ Application Setup");

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
