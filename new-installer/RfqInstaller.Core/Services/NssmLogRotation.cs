using System.Text.RegularExpressions;

namespace RfqInstaller.Core.Services;

internal static class NssmLogRotation
{
    internal const string DefaultMaxBytes = "314572800";

    // Keep the legacy installer/PR35 NSSM base-zero DWORD contract, including
    // zero (which disables the size threshold). Rotation archives are retained;
    // these settings do not impose a total disk-retention limit.
    internal static string ParseMaxBytes(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return DefaultMaxBytes;
        }

        if (!Regex.IsMatch(value, @"\A[ \t\r\n\v\f]*\+?(?:0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)\z", RegexOptions.CultureInvariant))
        {
            throw new ArgumentException("RFQ_LOG_CAP_MAX_BYTES must be an unsigned integer byte count (no units).", nameof(value));
        }

        var digits = value.TrimStart(' ', '\t', '\r', '\n', '\v', '\f').TrimStart('+');
        var numberBase = 10;
        if (digits.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            numberBase = 16;
            digits = digits[2..];
        }
        else if (digits.StartsWith('0'))
        {
            numberBase = 8;
        }

        try
        {
            _ = Convert.ToUInt32(digits, numberBase);
        }
        catch (Exception ex) when (ex is FormatException or OverflowException or ArgumentException)
        {
            throw new ArgumentException("RFQ_LOG_CAP_MAX_BYTES must fit an unsigned 32-bit byte count.", nameof(value), ex);
        }

        return value;
    }
}
