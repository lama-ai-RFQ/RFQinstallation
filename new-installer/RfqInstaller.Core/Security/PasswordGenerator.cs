using System.Security.Cryptography;

namespace RfqInstaller.Core.Security;

/// <summary>Generates strong random passwords so nothing ever prompts for one on install.</summary>
public static class PasswordGenerator
{
    private const string Lower = "abcdefghijkmnopqrstuvwxyz";
    private const string Upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
    private const string Digits = "23456789";
    private const string Special = "!@#$%^&*-_=+";

    /// <summary>24 characters, guaranteed at least one of each character class, no ambiguous glyphs (0/O, 1/l/I).</summary>
    public static string Generate(int length = 24)
    {
        const string all = Lower + Upper + Digits + Special;
        var chars = new char[length];

        chars[0] = PickFrom(Lower);
        chars[1] = PickFrom(Upper);
        chars[2] = PickFrom(Digits);
        chars[3] = PickFrom(Special);
        for (var i = 4; i < length; i++)
        {
            chars[i] = PickFrom(all);
        }

        Shuffle(chars);
        return new string(chars);
    }

    private static char PickFrom(string alphabet) => alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];

    private static void Shuffle(char[] chars)
    {
        for (var i = chars.Length - 1; i > 0; i--)
        {
            var j = RandomNumberGenerator.GetInt32(i + 1);
            (chars[i], chars[j]) = (chars[j], chars[i]);
        }
    }
}
