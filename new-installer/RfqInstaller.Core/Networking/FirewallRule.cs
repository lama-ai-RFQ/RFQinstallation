using RfqInstaller.Core.Processes;

namespace RfqInstaller.Core.Networking;

/// <summary>
/// The inbound Windows Firewall rule that lets other computers on the network open the app.
/// One rule per product, found by name: install creates it when the user allows network access,
/// repair moves it to the current port, uninstall removes it.
///
/// Uses netsh (always present, no PowerShell module needed). The rule name and every value contain
/// no spaces, so netsh's own argument parsing can't split them. It applies to the domain and private
/// profiles only, so a laptop on public Wi-Fi stays closed.
/// </summary>
public static class FirewallRule
{
    /// <summary>The rule's name in Windows Defender Firewall (no spaces; see the class remarks).</summary>
    public const string AppRuleName = "RFQ-Application-HTTPS";

    public const string Profiles = "domain,private";

    public static IReadOnlyList<string> AddArguments(string name, int port)
    {
        ValidatePort(port);
        ValidateName(name);
        return new[]
        {
            "advfirewall", "firewall", "add", "rule",
            $"name={name}", "dir=in", "action=allow", "protocol=TCP",
            $"localport={port}", $"profile={Profiles}", "enable=yes",
        };
    }

    public static IReadOnlyList<string> DeleteArguments(string name)
    {
        ValidateName(name);
        return new[] { "advfirewall", "firewall", "delete", "rule", $"name={name}" };
    }

    public static IReadOnlyList<string> ShowArguments(string name)
    {
        ValidateName(name);
        return new[] { "advfirewall", "firewall", "show", "rule", $"name={name}" };
    }

    /// <summary>
    /// netsh exits 0 when the rule exists and 1 ("No rules match...") when it doesn't. Only the exit
    /// code is used: the text is translated on non-English Windows.
    /// </summary>
    public static bool ShowOutputMeansExists(ProcessResult result) => result.ExitCode == 0;

    public static async Task<bool> ExistsAsync(string name, CancellationToken cancellationToken)
    {
        var result = await HiddenProcessRunner.RunAsync("netsh.exe", ShowArguments(name), cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        return ShowOutputMeansExists(result);
    }

    /// <summary>Replace any rule with this name by one for <paramref name="port"/>. Throws when netsh fails.</summary>
    public static async Task EnsureAsync(string name, int port, CancellationToken cancellationToken)
    {
        await RemoveAsync(name, cancellationToken).ConfigureAwait(false);
        var result = await HiddenProcessRunner.RunAsync("netsh.exe", AddArguments(name, port), cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            var output = (result.StdOut + " " + result.StdErr).Trim();
            throw new InvalidOperationException($"netsh could not add the firewall rule (exit {result.ExitCode}): {output}");
        }
    }

    /// <summary>Remove the rule if present. Never throws for a missing rule.</summary>
    public static async Task RemoveAsync(string name, CancellationToken cancellationToken)
    {
        // Exit code 1 means "no rule matched", which is fine.
        await HiddenProcessRunner.RunAsync("netsh.exe", DeleteArguments(name), cancellationToken: cancellationToken)
            .ConfigureAwait(false);
    }

    private static void ValidatePort(int port)
    {
        if (port is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port), port, "Port must be between 1 and 65535.");
        }
    }

    private static void ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Any(c => char.IsWhiteSpace(c) || c == '"'))
        {
            throw new ArgumentException("The rule name must not contain spaces or quotes.", nameof(name));
        }
    }
}
