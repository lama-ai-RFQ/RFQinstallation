namespace RfqInstaller.Core.Security;

public enum PasswordStrength
{
    VeryWeak,
    Weak,
    Fair,
    Good,
    Strong,
}

public record PasswordCriteria(
    bool HasMinLength,
    bool HasUpper,
    bool HasLower,
    bool HasDigit,
    bool HasSpecial,
    bool IsNotCommon,
    bool ClassCountMet);

public record PasswordEvaluation(PasswordStrength Strength, bool MeetsMinimum, PasswordCriteria Criteria);

/// <summary>
/// Settings-password rules. The hard pass/fail gate is exactly the old installer's rule
/// (setup.iss ValidatePassword: length >= 8, at least 3 of {upper, lower, digit, special}) --
/// never loosened, only ever added to. The one addition is a common/breached-password blocklist,
/// which the old installer didn't have; NIST SP 800-63B treats this as more valuable than
/// character-class mandates, and it's purely additive (a password can only fail *more* often, so
/// it cannot make anything less secure than before). The strength meter goes further and rewards
/// length beyond the 8-character floor, as modern guidance recommends, but that's advisory only —
/// it never relaxes the hard gate.
/// </summary>
public static class PasswordPolicy
{
    public const int MinLength = 8;

    private const string SpecialChars = "!@#$%^&*()_+-=[]{}|;:,.<>?/\\~`\"'";

    // A short, representative slice of the most commonly breached/guessed passwords (per
    // widely-published breach-corpus frequency lists) plus obvious product-specific guesses.
    // This is a floor, not an exhaustive denylist -- it exists to catch the worst, most
    // predictable choices, not to replace the complexity/length checks above.
    private static readonly HashSet<string> CommonPasswords = new(StringComparer.OrdinalIgnoreCase)
    {
        "password", "password1", "password123", "12345678", "123456789", "1234567890",
        "qwerty123", "qwertyuiop", "letmein123", "welcome123", "admin1234", "iloveyou1",
        "sunshine1", "princess1", "football1", "baseball1", "dragon123", "monkey123",
        "trustno1", "abc123456", "111111111", "000000000", "123123123", "aaaaaaaa",
        "rfqapplication", "settings123", "rfqsettings", "changeme123", "letmein1234",
    };

    public static string? StorageProblem(string password)
    {
        if (string.IsNullOrEmpty(password)) return "Enter a password.";
        // The installed app trims boundary whitespace. Its dotenv reader also treats a space
        // before # as a comment and expands ${...}; the updater strips boundary quotes.
        if (char.IsWhiteSpace(password[0]) || char.IsWhiteSpace(password[^1]) ||
            password.Any(char.IsControl) ||
            password[0] is '\'' or '"' || password[^1] is '\'' or '"' ||
            System.Text.RegularExpressions.Regex.IsMatch(password, @"\s#") ||
            password.Contains("${", StringComparison.Ordinal))
            return "Remove leading or trailing whitespace or quotes, control characters, whitespace before #, and ${ sequences.";
        if (password == CredentialManagerWriter.Sentinel)
            return "Choose a password other than the reserved Credential Manager marker.";
        return null;
    }

    public static PasswordEvaluation Evaluate(string password)
    {
        password ??= string.Empty;

        var hasMinLength = password.Length >= MinLength;
        var hasUpper = password.Any(char.IsUpper);
        var hasLower = password.Any(char.IsLower);
        var hasDigit = password.Any(char.IsDigit);
        var hasSpecial = password.Any(c => SpecialChars.Contains(c));
        var isNotCommon = password.Length == 0 || !CommonPasswords.Contains(password);

        var classCount = new[] { hasUpper, hasLower, hasDigit, hasSpecial }.Count(x => x);
        var classCountMet = classCount >= 3;

        var criteria = new PasswordCriteria(hasMinLength, hasUpper, hasLower, hasDigit, hasSpecial, isNotCommon, classCountMet);
        var storable = StorageProblem(password) is null;
        var meetsMinimum = hasMinLength && classCountMet && isNotCommon && storable;

        return new PasswordEvaluation(storable ? Score(password, criteria) : PasswordStrength.VeryWeak, meetsMinimum, criteria);
    }

    private static PasswordStrength Score(string password, PasswordCriteria criteria)
    {
        if (!criteria.IsNotCommon)
        {
            return PasswordStrength.VeryWeak;
        }

        if (!criteria.HasMinLength)
        {
            return password.Length == 0 ? PasswordStrength.VeryWeak : PasswordStrength.Weak;
        }

        if (!criteria.ClassCountMet)
        {
            return PasswordStrength.Weak;
        }

        // Meets the hard gate -- from here, reward length, matching modern guidance that length
        // matters more than squeezing in a 4th character class.
        return password.Length switch
        {
            >= 20 => PasswordStrength.Strong,
            >= 14 => PasswordStrength.Good,
            _ => PasswordStrength.Fair,
        };
    }
}
