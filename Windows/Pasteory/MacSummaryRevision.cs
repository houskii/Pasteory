using System;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Pasteory.Windows;

internal static class MacSummaryRevision
{
    internal static string Compute(Guid id, string contentHash, string title, string automaticTitle, string note,
        string kind, string preview, bool deleted, string recognizedText)
    {
        string[] fields = [id.ToString("D").ToUpperInvariant(), contentHash, title, automaticTitle, note, kind, preview,
            deleted ? "deleted" : "present"];
        // Foundation hashes the compact JSON array with literal UTF-8 and escaped forward slashes.
        var json = new StringBuilder("[");
        foreach (string field in fields) Append(field);
        if (recognizedText.Length > 0) Append(recognizedText);
        json.Append(']');
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(json.ToString())));

        void Append(string value)
        {
            if (json.Length > 1) json.Append(',');
            json.Append('"');
            foreach (char ch in value)
            {
                string? escaped = ch switch
                {
                    '"' => "\\\"", '\\' => "\\\\", '/' => "\\/", '\b' => "\\b", '\f' => "\\f",
                    '\n' => "\\n", '\r' => "\\r", '\t' => "\\t", _ => null
                };
                if (escaped is not null) json.Append(escaped);
                else if (ch < ' ') json.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                else json.Append(ch);
            }
            json.Append('"');
        }
    }

    internal static string RecognizedText(string note, string? text, bool inNote)
    {
        if (!inNote) return text ?? "";
        const string marker = "[OCR:";
        int start = note.LastIndexOf(marker, StringComparison.Ordinal);
        if (start < 0) return "";
        start += marker.Length;
        int end = note.LastIndexOf(']');
        return end < start ? note[start..] : note[start..end];
    }
}
