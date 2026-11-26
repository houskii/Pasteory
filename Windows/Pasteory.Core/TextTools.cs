using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Pasteory.Core;

public enum TextTool { Base64Encode, Base64Decode, Md5, RgbaToHex, HexToRgba, UrlEncode, UrlDecode }

public static partial class TextTools
{
    private static readonly UTF8Encoding Utf8 = new(false, true);

    public static string ConvertText(TextTool tool, string input) => tool switch
    {
        TextTool.Base64Encode => Convert.ToBase64String(Utf8.GetBytes(input)),
        TextTool.Base64Decode => DecodeBase64(input),
        TextTool.Md5 => Convert.ToHexStringLower(MD5.HashData(Utf8.GetBytes(input))),
        TextTool.RgbaToHex when Rgb().IsMatch(input.Trim()) && TryColor(input, out var rgba) => rgba.Hex,
        TextTool.HexToRgba when input.TrimStart().StartsWith('#') && TryColor(input, out var hex) =>
            FormattableString.Invariant($"rgba({hex.R}, {hex.G}, {hex.B}, {hex.A / 255d:0.###})"),
        TextTool.UrlEncode => Uri.EscapeDataString(input),
        TextTool.UrlDecode => DecodeUrl(input),
        _ => throw new FormatException("Invalid color.")
    };

    public readonly record struct ColorValue(byte R, byte G, byte B, byte A, bool HasAlpha)
    {
        public string Hex => $"#{R:X2}{G:X2}{B:X2}" + (HasAlpha ? $"{A:X2}" : "");
    }

    public static bool TryColor(string? input, out ColorValue color)
    {
        color = default;
        string text = input?.Trim() ?? "";
        if (text.StartsWith('#') && text.Length is 4 or 5 or 7 or 9 &&
            text.AsSpan(1).IndexOfAnyExcept("0123456789abcdefABCDEF") < 0)
        {
            bool alpha = text.Length is 5 or 9;
            bool shortHex = text.Length <= 5;
            byte Component(int index) => shortHex
                ? (byte)(byte.Parse(text.AsSpan(1 + index, 1), NumberStyles.HexNumber) * 17)
                : byte.Parse(text.AsSpan(1 + index * 2, 2), NumberStyles.HexNumber);
            color = new(Component(0), Component(1), Component(2), alpha ? Component(3) : (byte)255, alpha);
            return true;
        }

        if (text.Length > 128) return false;
        var match = Rgb().Match(text);
        if (!match.Success || !byte.TryParse(match.Groups[2].Value, out byte r) ||
            !byte.TryParse(match.Groups[3].Value, out byte g) || !byte.TryParse(match.Groups[4].Value, out byte b))
            return false;
        bool hasAlpha = match.Groups[5].Success;
        if (match.Groups[1].Success != hasAlpha) return false;
        double opacity = 1;
        if (hasAlpha && (!double.TryParse(match.Groups[5].Value, NumberStyles.AllowDecimalPoint,
            CultureInfo.InvariantCulture, out opacity) || opacity is < 0 or > 1)) return false;
        color = new(r, g, b, (byte)Math.Round(opacity * 255, MidpointRounding.AwayFromZero), hasAlpha);
        return true;
    }

    public static (ClipKind Kind, string? Language) Classify(string? text)
    {
        if (Clip.LinkKey(text) is not null) return (ClipKind.Link, null);
        if (TryColor(text, out _)) return (ClipKind.Color, null);
        string value = text?.Trim() ?? "";
        if (value.Length == 0) return (ClipKind.Text, null);

        string sample = value[..Math.Min(2048, value.Length)];
        string? language = sample switch
        {
            _ when sample.StartsWith("<?xml", StringComparison.OrdinalIgnoreCase) => "xml",
            _ when sample.StartsWith("<!DOCTYPE", StringComparison.OrdinalIgnoreCase) ||
                sample.StartsWith("<html", StringComparison.OrdinalIgnoreCase) => "html",
            _ when (value[0] is '{' or '[') && IsJson(value) => "json",
            _ when Python().IsMatch(sample) => "py",
            _ when Swift().IsMatch(sample) => "swift",
            _ when CSharp().IsMatch(sample) => "cs",
            _ when Shell().IsMatch(sample) => "sh",
            _ when JavaScript().IsMatch(sample) => "js",
            _ when Sql().IsMatch(sample) => "sql",
            _ => null
        };
        return (language is null ? ClipKind.Text : ClipKind.Code, language);
    }

    private static bool IsJson(string value)
    {
        try { using var parsed = System.Text.Json.JsonDocument.Parse(value); return true; }
        catch (System.Text.Json.JsonException) { return false; }
    }

    private static string DecodeBase64(string input)
    {
        string normalized = string.Concat(input.Where(character => !char.IsWhiteSpace(character)))
            .Replace('-', '+').Replace('_', '/');
        if (!normalized.Contains('=')) normalized = normalized.PadRight((normalized.Length + 3) / 4 * 4, '=');
        return Utf8.GetString(Convert.FromBase64String(normalized));
    }

    private static string DecodeUrl(string input)
    {
        if (InvalidEscape().IsMatch(input)) throw new FormatException("Invalid URL escape.");
        return Escapes().Replace(input, run =>
        {
            var bytes = new byte[run.Length / 3];
            for (int index = 0; index < bytes.Length; index++)
                bytes[index] = byte.Parse(run.Value.AsSpan(index * 3 + 1, 2), NumberStyles.HexNumber);
            return Utf8.GetString(bytes);
        });
    }

    [GeneratedRegex(@"^rgb(a)?\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)$", RegexOptions.IgnoreCase)]
    private static partial Regex Rgb();
    [GeneratedRegex(@"%(?![0-9a-fA-F]{2})")]
    private static partial Regex InvalidEscape();
    [GeneratedRegex(@"(?:%[0-9a-fA-F]{2})+")]
    private static partial Regex Escapes();
    [GeneratedRegex(@"(?m)^\s*(?:async\s+)?def\s+\w+\([^)]*\)\s*:|^from\s+[\w.]+\s+import\s+|^if\s+__name__\s*==")]
    private static partial Regex Python();
    [GeneratedRegex(@"(?m)^\s*(?:import (?:Foundation|SwiftUI|AppKit)|(?:public )?func\s+\w+\([^)]*\)|let\s+\w+\s*=.*\n\s*\.(?:map|filter|sorted))")]
    private static partial Regex Swift();
    [GeneratedRegex(@"(?m)^\s*(?:using\s+System(?:\.[\w.]+)?;|namespace\s+[\w.]+[;{]|(?:public|private)\s+(?:sealed\s+)?(?:class|record)\s+\w+)")]
    private static partial Regex CSharp();
    [GeneratedRegex(@"^(?:#!|(?:git|dotnet|npm|cargo|swift|make|docker|kubectl)\s+[\w-]+)")]
    private static partial Regex Shell();
    [GeneratedRegex(@"(?m)^\s*(?:(?:const|let|var)\s+\w+\s*=.+;|(?:export\s+)?(?:async\s+)?function\s+\w+\([^)]*\)|import\s+.+\s+from\s+['""])")]
    private static partial Regex JavaScript();
    [GeneratedRegex(@"(?is)^(?:select\b.+\bfrom\b|insert\s+into\b|create\s+table\b|update\b.+\bset\b)")]
    private static partial Regex Sql();
}
