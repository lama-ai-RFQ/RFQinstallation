namespace RfqInstaller.Core.Services;

/// <summary>
/// A service that wouldn't start. The message is what the person installing reads: what failed and,
/// when Windows said, why. <see cref="Details"/> holds everything else Windows knows (service state,
/// its events, the end of the app's error log) for the installer log and support.
/// </summary>
public sealed class ServiceStartException : InvalidOperationException
{
    public ServiceStartException(string message, string details) : base(message)
    {
        Details = details;
    }

    public string Details { get; }

    /// <summary>The installer log writes exceptions with ToString, so the details reach it.</summary>
    public override string ToString() =>
        string.IsNullOrWhiteSpace(Details)
            ? base.ToString()
            : $"{base.ToString()}{Environment.NewLine}{Environment.NewLine}{Details}";
}
