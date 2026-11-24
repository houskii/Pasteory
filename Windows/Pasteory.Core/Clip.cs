using System.Text;
using System.Text.Json.Serialization;

namespace Pasteory.Core;

public enum ClipKind { Text, Link, Image, Files }

public sealed record Clip
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public DateTimeOffset CapturedAt { get; init; } = DateTimeOffset.UtcNow;
    public ClipKind Kind { get; init; }
    public string Source { get; init; } = "";
    public string? Text { get; init; }
    public string? Html { get; init; }
    public string? Rtf { get; init; }
    public string[] Files { get; init; } = [];
    public string? ImageHash { get; init; }
    public int ImageSize { get; init; }
    public string Title { get; init; } = "";
    public string Note { get; init; } = "";
    public string Group { get; init; } = "";
    public bool Favorite { get; init; }
    public bool Pinned { get; init; }

    [JsonIgnore]
    public string? PlainText => Kind == ClipKind.Files ? string.Join(Environment.NewLine, Files) : Text;

    internal bool SameContent(Clip other) =>
        Kind == other.Kind && Text == other.Text && Html == other.Html && Rtf == other.Rtf &&
        ImageHash == other.ImageHash && Files.SequenceEqual(other.Files, StringComparer.OrdinalIgnoreCase);

    internal long Size => IndexSize + ImageSize;

    internal long IndexSize => 256L + Encoding.UTF8.GetByteCount(Title) + Encoding.UTF8.GetByteCount(Note) +
        Encoding.UTF8.GetByteCount(Group) + Encoding.UTF8.GetByteCount(Source) + Bytes(Text) + Bytes(Html) + Bytes(Rtf) +
        Files.Sum(path => (long)Encoding.UTF8.GetByteCount(path));

    private static int Bytes(string? text) => text is null ? 0 : Encoding.UTF8.GetByteCount(text);

    public bool Matches(string query) => query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
        .All(term => Contains(Title, term) || Contains(Text, term) || Contains(Note, term) ||
            Contains(Source, term) || Contains(Group, term) || Files.Any(path => Contains(path, term)));

    private static bool Contains(string? value, string term) =>
        value?.Contains(term, StringComparison.OrdinalIgnoreCase) == true;
}
