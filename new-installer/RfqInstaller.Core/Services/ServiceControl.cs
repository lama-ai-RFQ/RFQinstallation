using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using RfqInstaller.Core.Processes;

namespace RfqInstaller.Core.Services;

public enum ServiceState
{
    NotInstalled,
    Stopped,
    StartPending,
    StopPending,
    Running,
    ContinuePending,
    PausePending,
    Paused,
    Unknown,
}

public sealed record ServiceStatus(ServiceState State, int? Win32ExitCode, int? ServiceExitCode);

/// <summary>
/// Starts Windows services and waits until they really run. <c>sc start</c> and <c>nssm start</c>
/// both return while a slow app is still starting, and report that as a failure; RFQ Application
/// takes long enough to start that this failed installs which were actually fine. When a service
/// does fail, the error says why: Windows' exit codes, its Service Control Manager events, and the
/// end of the service's own error log, instead of only an exit code.
/// </summary>
public sealed partial class ServiceControl
{
    public static readonly TimeSpan DefaultStartTimeout = TimeSpan.FromMinutes(3);

    /// <summary>One-second checks a service must stay running for before it counts as started.</summary>
    public int SettlePolls { get; init; } = 8;

    private const int ErrorServiceAlreadyRunning = 1056;
    private const int ErrorServiceDoesNotExist = 1060;
    private const int ErrorServiceLogonFailed = 1069;

    private readonly Func<string, IReadOnlyList<string>, CancellationToken, Task<ProcessResult>> _run;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;

    public ServiceControl() : this(
        (file, args, token) => HiddenProcessRunner.RunAsync(file, args, cancellationToken: token),
        Task.Delay)
    {
    }

    internal ServiceControl(
        Func<string, IReadOnlyList<string>, CancellationToken, Task<ProcessResult>> run,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _run = run;
        _delay = delay ?? Task.Delay;
    }

    public async Task<ServiceStatus> QueryAsync(string serviceName, CancellationToken cancellationToken)
    {
        var result = await _run("sc.exe", new[] { "query", serviceName }, cancellationToken).ConfigureAwait(false);
        if (result.ExitCode == ErrorServiceDoesNotExist)
        {
            return new ServiceStatus(ServiceState.NotInstalled, null, null);
        }
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException($"Could not query service '{serviceName}' (exit code {result.ExitCode}).");
        }

        return ParseQuery(result.StdOut);
    }

    /// <summary>
    /// Starts <paramref name="serviceName"/> (already running is fine) and waits until Windows
    /// reports it running. Throws with the reason if it stops, pauses (NSSM pauses an app that
    /// keeps exiting) or is still starting at the timeout.
    /// </summary>
    public async Task StartAndWaitAsync(
        string serviceName,
        CancellationToken cancellationToken,
        TimeSpan? timeout = null,
        string? stderrLogPath = null)
    {
        var start = await _run("sc.exe", new[] { "start", serviceName }, cancellationToken).ConfigureAwait(false);
        if (start.ExitCode == ErrorServiceLogonFailed)
        {
            // The app never ran, so neither its log nor NSSM has anything to add to the message.
            var account = await StartNameAsync(serviceName, cancellationToken).ConfigureAwait(false);
            throw await FailureAsync(
                    $"Windows couldn't sign the {serviceName} service in as {account ?? "its account"}: the user name or " +
                    "password is wrong, or the account isn't allowed to run services. For a Microsoft account, use the " +
                    "account's password, not the PIN.",
                    serviceName, stderrLogPath, withReason: false, cancellationToken)
                .ConfigureAwait(false);
        }
        if (start.ExitCode is not (0 or ErrorServiceAlreadyRunning))
        {
            throw await FailureAsync(
                    $"Could not start service '{serviceName}' (exit code {start.ExitCode}: {FirstLine(start.StdOut + start.StdErr)}).",
                    serviceName, stderrLogPath, withReason: true, cancellationToken)
                .ConfigureAwait(false);
        }

        // Counted in one-second polls rather than wall-clock time, so the wait is the same however
        // long each query takes, and tests can replace the delay.
        var limit = timeout ?? DefaultStartTimeout;
        var pollsLeft = Math.Max(1, (int)Math.Ceiling(limit.TotalSeconds));
        var stablePolls = 0;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var status = await QueryAsync(serviceName, cancellationToken).ConfigureAwait(false);
            switch (status.State)
            {
                case ServiceState.Running:
                    // NSSM reports RUNNING as soon as it launches the app, before the app has had a
                    // chance to fail. One that exits at once is restarted and soon paused, so only a
                    // service still running after the settle time counts as started.
                    if (++stablePolls > SettlePolls)
                    {
                        return;
                    }
                    break;
                case ServiceState.Stopped:
                case ServiceState.Paused:
                case ServiceState.NotInstalled:
                    throw await FailureAsync(
                            $"The {serviceName} service {(status.State == ServiceState.Paused ? "keeps exiting, so Windows paused it" : stablePolls > 0 ? "stopped soon after starting" : "stopped right after starting")}.",
                            serviceName, stderrLogPath, withReason: true, cancellationToken)
                        .ConfigureAwait(false);
                default:
                    stablePolls = 0;
                    break;
            }

            if (stablePolls == 0 && --pollsLeft <= 0)
            {
                throw await FailureAsync(
                        $"The {serviceName} service was still starting after {limit.TotalMinutes:0.#} minutes.",
                        serviceName, stderrLogPath, withReason: true, cancellationToken)
                    .ConfigureAwait(false);
            }

            await _delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task StopIfExistsAsync(string serviceName, CancellationToken cancellationToken)
    {
        if ((await QueryAsync(serviceName, cancellationToken).ConfigureAwait(false)).State == ServiceState.NotInstalled)
        {
            return;
        }

        var stop = await _run("sc.exe", new[] { "stop", serviceName }, cancellationToken).ConfigureAwait(false);
        if (stop.ExitCode is not (0 or 1062))
        {
            throw new InvalidOperationException($"Could not stop service '{serviceName}' (exit code {stop.ExitCode}).");
        }

        for (var i = 0; i < 30; i++)
        {
            var query = await _run("sc.exe", new[] { "query", serviceName }, cancellationToken)
                .ConfigureAwait(false);
            if (query.ExitCode == ErrorServiceDoesNotExist ||
                (query.ExitCode == 0 && query.StdOut.Contains("STOPPED", StringComparison.OrdinalIgnoreCase)))
            {
                return;
            }
            if (query.ExitCode != 0)
            {
                throw new InvalidOperationException($"Could not query service '{serviceName}' while stopping (exit code {query.ExitCode}).");
            }

            await _delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }
        throw new TimeoutException($"Service '{serviceName}' did not stop within 30 seconds.");
    }

    /// <summary>
    /// Windows only deletes a service once nothing holds it open (Services console, a query in
    /// flight); until then it stays "marked for deletion".
    /// </summary>
    public async Task WaitUntilRemovedAsync(string serviceName, CancellationToken cancellationToken)
    {
        for (var i = 0; i < 30; i++)
        {
            if ((await QueryAsync(serviceName, cancellationToken).ConfigureAwait(false)).State == ServiceState.NotInstalled)
            {
                return;
            }
            await _delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }
        throw new TimeoutException(
            $"Service '{serviceName}' was not removed within 30 seconds. Close the Services window if it is open, then try again.");
    }

    /// <summary>
    /// A short message, with NSSM's own reason when it logged one ("CreateProcess() failed: Access
    /// is denied"), and the full report as the exception's details.
    /// </summary>
    private async Task<ServiceStartException> FailureAsync(
        string summary,
        string serviceName,
        string? stderrLogPath,
        bool withReason,
        CancellationToken cancellationToken)
    {
        var reason = withReason ? await NssmReasonAsync(serviceName, cancellationToken).ConfigureAwait(false) : null;
        var message = reason is null ? summary : $"{summary}{Environment.NewLine}{Environment.NewLine}Windows said: {reason}";
        return new ServiceStartException(
            message,
            await FailureReportAsync(serviceName, stderrLogPath, cancellationToken).ConfigureAwait(false));
    }

    /// <summary>
    /// NSSM's newest error about this service in the last ten minutes. NSSM writes why it couldn't
    /// launch the app to the Application log, not the System log the Service Control Manager uses.
    /// </summary>
    internal async Task<string?> NssmReasonAsync(string serviceName, CancellationToken cancellationToken)
    {
        try
        {
            var events = await NssmErrorsAsync(serviceName, 600000, 1, cancellationToken).ConfigureAwait(false);
            return events.Count > 0 ? events[0].Text : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null;
        }
    }

    private async Task<IReadOnlyList<ServiceEvent>> NssmErrorsAsync(
        string serviceName,
        int withinMilliseconds,
        int max,
        CancellationToken cancellationToken)
    {
        var query = await _run(
                "wevtutil.exe",
                new[]
                {
                    "qe", "Application",
                    $"/q:*[System[Provider[@Name='nssm'] and Level=2 and TimeCreated[timediff(@SystemTime) <= {withinMilliseconds}]]]",
                    "/rd:true", "/c:20", "/f:text",
                },
                cancellationToken)
            .ConfigureAwait(false);
        return query.ExitCode == 0 ? ParseServiceEvents(query.StdOut, serviceName, null, max) : Array.Empty<ServiceEvent>();
    }

    /// <summary>
    /// Everything Windows knows about why a service isn't running, as text for an error message.
    /// Never throws: a part it can't read is left out.
    /// </summary>
    public async Task<string> FailureReportAsync(string serviceName, string? stderrLogPath, CancellationToken cancellationToken)
    {
        var report = new StringBuilder();
        try
        {
            var query = await _run("sc.exe", new[] { "query", serviceName }, cancellationToken).ConfigureAwait(false);
            if (query.ExitCode == 0)
            {
                var status = ParseQuery(query.StdOut);
                report.AppendLine($"Service state: {status.State}" +
                                  (status.Win32ExitCode is { } win32 && win32 != 0 ? $", Windows exit code {win32}" : "") +
                                  (status.ServiceExitCode is { } service && service != 0 ? $", service exit code {service}" : ""));
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Diagnostics are best effort.
        }

        string? displayName = null;
        try
        {
            var config = await _run("sc.exe", new[] { "qc", serviceName }, cancellationToken).ConfigureAwait(false);
            if (config.ExitCode == 0)
            {
                displayName = Field(config.StdOut, "DISPLAY_NAME");
                if (Field(config.StdOut, "SERVICE_START_NAME") is { } startName)
                {
                    report.AppendLine($"Runs as: {startName}");
                }
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
        }

        try
        {
            var events = await RecentEventsAsync(serviceName, displayName, cancellationToken).ConfigureAwait(false);
            if (events.Count > 0)
            {
                report.AppendLine();
                report.AppendLine("Windows Service Control Manager events (newest first):");
                foreach (var entry in events)
                {
                    report.AppendLine("  " + entry);
                }
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
        }

        var logPath = stderrLogPath ?? AppStderrPath(serviceName);
        if (logPath is not null)
        {
            var tail = TailLines(logPath, 25);
            if (tail.Count > 0)
            {
                report.AppendLine();
                report.AppendLine($"Last lines of {logPath}:");
                foreach (var line in tail)
                {
                    report.AppendLine("  " + line);
                }
            }
        }

        return report.ToString().TrimEnd();
    }

    internal static ServiceStatus ParseQuery(string scQueryOutput)
    {
        var state = StateRegex().Match(scQueryOutput) is { Success: true } match
            ? int.Parse(match.Groups[1].Value) switch
            {
                1 => ServiceState.Stopped,
                2 => ServiceState.StartPending,
                3 => ServiceState.StopPending,
                4 => ServiceState.Running,
                5 => ServiceState.ContinuePending,
                6 => ServiceState.PausePending,
                7 => ServiceState.Paused,
                _ => ServiceState.Unknown,
            }
            : ServiceState.Unknown;
        return new ServiceStatus(state, NumberField(scQueryOutput, "WIN32_EXIT_CODE"), NumberField(scQueryOutput, "SERVICE_EXIT_CODE"));
    }

    /// <summary>
    /// The Service Control Manager names a service by its display name in event text
    /// ("The RFQ Application Service service terminated..."), so match either name.
    /// </summary>
    public async Task<IReadOnlyList<string>> RecentEventsAsync(string serviceName, string? displayName, CancellationToken cancellationToken)
    {
        var query = await _run(
                "wevtutil.exe",
                new[]
                {
                    "qe", "System",
                    "/q:*[System[Provider[@Name='Service Control Manager'] and TimeCreated[timediff(@SystemTime) <= 3600000]]]",
                    "/rd:true", "/c:40", "/f:text",
                },
                cancellationToken)
            .ConfigureAwait(false);
        var events = query.ExitCode == 0
            ? ParseServiceEvents(query.StdOut, serviceName, displayName, 6).ToList()
            : new List<ServiceEvent>();
        try
        {
            events.AddRange(await NssmErrorsAsync(serviceName, 3600000, 3, cancellationToken).ConfigureAwait(false));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The System log's events still stand.
        }

        return events
            .OrderByDescending(e => e.Date, StringComparer.Ordinal)
            .Select(e => e.ToString())
            .ToList();
    }

    internal sealed record ServiceEvent(string? Date, string? Id, string Text)
    {
        public override string ToString() => $"{Date} event {Id}: {Text}";
    }

    internal static IReadOnlyList<string> ParseEvents(string wevtutilText, string serviceName, string? displayName, int max) =>
        ParseServiceEvents(wevtutilText, serviceName, displayName, max).Select(e => e.ToString()).ToList();

    internal static IReadOnlyList<ServiceEvent> ParseServiceEvents(string wevtutilText, string serviceName, string? displayName, int max)
    {
        var results = new List<ServiceEvent>();
        foreach (var block in EventSplitRegex().Split(wevtutilText))
        {
            var description = DescriptionRegex().Match(block) is { Success: true } d ? d.Groups[1].Value : null;
            if (description is null)
            {
                continue;
            }

            var mentions = description.Contains(serviceName, StringComparison.OrdinalIgnoreCase) ||
                           (!string.IsNullOrWhiteSpace(displayName) &&
                            description.Contains(displayName, StringComparison.OrdinalIgnoreCase));
            if (!mentions)
            {
                continue;
            }

            var date = Field(block, "Date");
            var id = Field(block, "Event ID");
            var text = string.Join(" ", description.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
            results.Add(new ServiceEvent(date, id, text));
            if (results.Count >= max)
            {
                break;
            }
        }

        return results;
    }

    private async Task<string?> StartNameAsync(string serviceName, CancellationToken cancellationToken)
    {
        try
        {
            var config = await _run("sc.exe", new[] { "qc", serviceName }, cancellationToken).ConfigureAwait(false);
            return config.ExitCode == 0 ? Field(config.StdOut, "SERVICE_START_NAME") : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null;
        }
    }

    private static string? AppStderrPath(string serviceName)
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{serviceName}\Parameters");
            return key?.GetValue("AppStderr") as string;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    internal static IReadOnlyList<string> TailLines(string path, int count)
    {
        try
        {
            if (!File.Exists(path))
            {
                return Array.Empty<string>();
            }

            // The app may still hold the log open; read without blocking it.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            const int maxBytes = 64 * 1024;
            if (stream.Length > maxBytes)
            {
                stream.Seek(-maxBytes, SeekOrigin.End);
            }

            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            var lines = reader.ReadToEnd()
                .Replace("\0", "", StringComparison.Ordinal)
                .Split('\n')
                .Select(line => line.TrimEnd('\r'))
                .Where(line => line.Length > 0)
                .ToList();
            return lines.Skip(Math.Max(0, lines.Count - count)).ToList();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<string>();
        }
    }

    private static string? Field(string text, string name)
    {
        var match = Regex.Match(text, $@"^\s*{Regex.Escape(name)}\s*:\s*(.*?)\s*$", RegexOptions.Multiline);
        return match.Success && match.Groups[1].Value.Length > 0 ? match.Groups[1].Value : null;
    }

    private static int? NumberField(string text, string name) =>
        Field(text, name) is { } value && Regex.Match(value, @"^-?\d+") is { Success: true } number
            ? int.Parse(number.Value)
            : null;

    private static string FirstLine(string text) =>
        text.Replace("\0", "", StringComparison.Ordinal)
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault() ?? "no output";

    [GeneratedRegex(@"STATE\s*:\s*(\d+)")]
    private static partial Regex StateRegex();

    // Some Windows versions write "Event[1]:", others "Event[1]" alone; missing one merged every
    // event after it into the first one's description.
    [GeneratedRegex(@"^[ \t]*Event\[\d+\]:?", RegexOptions.Multiline)]
    private static partial Regex EventSplitRegex();

    // The description is the rest of the event's block and may contain blank lines.
    [GeneratedRegex(@"^\s*Description:\s*(.*)\z", RegexOptions.Multiline | RegexOptions.Singleline)]
    private static partial Regex DescriptionRegex();
}
