using System.Text;

namespace Pasteory.Core;

internal static class ImageNotes
{
    private const string Marker = "[OCR:";

    internal static string Wrap(string text) => Marker + text + "]";

    internal static string Append(string note, string block) => note.Length == 0 ? block : note + "\n\n" + block;

    internal static (int Start, int End, string Text)? Find(string note, string? original)
    {
        // The original result can contain unbalanced literal brackets.
        if (original is { Length: > 0 })
        {
            string block = Wrap(original);
            int exact = note.LastIndexOf(block, StringComparison.Ordinal);
            if (exact >= 0) return (exact, exact + block.Length, original);
        }

        int start = note.LastIndexOf(Marker, StringComparison.Ordinal);
        if (start < 0) return null;
        int body = start + Marker.Length;
        int depth = 1;
        for (int index = body; index < note.Length; index++)
        {
            if (note[index] == '[') depth++;
            if (note[index] == ']' && --depth == 0) return (start, index + 1, note[body..index]);
        }
        return (start, note.Length, note[body..]);
    }

    internal static string Unwrap(string note)
    {
        if (!note.Contains(Marker, StringComparison.Ordinal)) return note;
        var text = new StringBuilder(note.Length);
        var brackets = new Stack<bool>();
        for (int index = 0; index < note.Length; index++)
        {
            if (note.AsSpan(index).StartsWith(Marker, StringComparison.Ordinal))
            {
                brackets.Push(true);
                index += Marker.Length - 1;
                continue;
            }
            char character = note[index];
            if (character == '[') brackets.Push(false);
            if (character != ']' || !brackets.TryPop(out bool wrapper) || !wrapper) text.Append(character);
        }
        return text.ToString();
    }
}
