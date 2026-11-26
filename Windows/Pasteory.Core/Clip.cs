using System.Text;
using System.Text.Json.Serialization;

namespace Pasteory.Core;

public enum ClipKind { Text, Link, Image, Files, Color, Code, Mixed, Aggregate }
public enum ClipImageFormat { Png, Jpeg, Tiff, Gif, Bmp, WebP, Heif, Avif }

public sealed record ClipboardRepresentation(Guid Id, string Uti, string Hash, int Size);
public sealed record ClipboardItem(Guid Id, int Order, ClipboardRepresentation[] Representations);
public sealed record MacClipboardIdentity(string Kind, string[] SecondaryKinds, string? ContentHash, string? IdentityKey);

public sealed record CaptureEvent(DateTimeOffset CapturedAt, string Source, string? Context = null, string? Url = null,
    Dictionary<string, string>? Details = null);
public sealed record ConversionRecord(TextTool Tool, string Original, string Source);
public sealed record LinkAttempt(string Status, DateTimeOffset At, string? Source, string? Quality,
    int? HttpStatus = null, int? DurationMilliseconds = null);
public sealed record LinkDetails(string Status, string? Title, DateTimeOffset AttemptedAt, string? Source = null,
    string? Quality = null, string? FallbackTitle = null, string? FallbackSource = null, string? Route = null,
    DateTimeOffset? LastResolvedAt = null, LinkAttempt[]? Attempts = null, int? HttpStatus = null, int? DurationMilliseconds = null);

public enum ClipPriority { None, P1, P2, P3 }

public sealed record Clip
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public DateTimeOffset CapturedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? CreatedAt { get; init; }
    public DateTimeOffset? LastPastedAt { get; init; }
    public DateTimeOffset? ArchivedAt { get; init; }
    public DateTimeOffset? TrashedAt { get; init; }
    public ClipKind Kind { get; init; }
    public string Source { get; init; } = "";
    public string SourceConfidence { get; init; } = "High";
    public string? SourceIdentifier { get; init; }
    public string? SourcePath { get; init; }
    public string? Text { get; init; }
    public string? Html { get; init; }
    public string? Rtf { get; init; }
    public string[] Files { get; init; } = [];
    public string? FileIdentity { get; init; }
    public string? ImageHash { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public ClipImageFormat ImageFormat { get; init; }
    public int ImageSize { get; init; }
    public int ImageWidth { get; init; }
    public int ImageHeight { get; init; }
    public string? RecognizedText { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool OcrInNote { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool OcrPending { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? RecognizedAt { get; init; }
    public string? CodeLanguage { get; init; }
    public LinkDetails? LinkDetails { get; init; }
    public string Title { get; init; } = "";
    public string Note { get; init; } = "";
    public string Group { get; init; } = "";
    public Guid[] CollectionIds { get; init; } = [];
    public bool Favorite { get; init; }
    public bool Pinned { get; init; }
    public ClipPriority Priority { get; init; }
    public int CopyCount { get; init; } = 1;
    public int PasteCount { get; init; }
    public CaptureEvent[] Captures { get; init; } = [];
    public ConversionRecord[] Conversions { get; init; } = [];
    public Guid[] Members { get; init; } = [];
    public Guid? LastSelectedMember { get; init; }
    public string? AggregationOrigin { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool AggregationFromSearch { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? AggregationUpdatedAt { get; init; }
    public bool ExcludeFromAi { get; init; }
    public bool IsManual { get; init; }
    public ClipUse[] Uses { get; init; } = [];
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ClipboardItem[]? OriginalItems { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public MacClipboardIdentity? OriginalMacIdentity { get; init; }

    [JsonIgnore]
    public IEnumerable<ClipboardRepresentation> OriginalRepresentations =>
        (OriginalItems ?? []).SelectMany(item => item.Representations);

    [JsonIgnore]
    public string? PlainText => Text ?? (Files.Length > 0 ? string.Join(Environment.NewLine, Files) : null);

    [JsonIgnore]
    public string? PlainClipboardText
    {
        get
        {
            if (Kind is ClipKind.Image or ClipKind.Files or ClipKind.Mixed)
            {
                string note = OcrInNote && ImageNotes.Find(Note, RecognizedText) is { } block
                    ? ImageNotes.Unwrap(Note[..block.Start]) + block.Text + ImageNotes.Unwrap(Note[block.End..])
                    : ImageNotes.Unwrap(Note);
                if (!string.IsNullOrWhiteSpace(note)) return note;
                if (RecognizedImageText is { } recognized && !string.IsNullOrWhiteSpace(recognized)) return recognized;
            }
            return PlainText;
        }
    }

    [JsonIgnore]
    public bool HasImage => ImageSize > 0 || Kind == ClipKind.Image;

    [JsonIgnore]
    public string? RecognizedImageText => HasImage
        ? ImageNotes.Find(Note, OcrInNote ? RecognizedText : null)?.Text ?? (OcrInNote ? "" : RecognizedText)
        : null;

    [JsonIgnore]
    public string NoteWithoutImageOcr => (HasImage || OcrInNote) && ImageNotes.Find(Note, OcrInNote ? RecognizedText : null) is { } block
        ? Note.Remove(block.Start, block.End - block.Start).Trim() : Note;

    public Clip WithImageRecognition(string result, DateTimeOffset recognizedAt)
    {
        string text = result.Trim();
        string note = OcrInNote ? NoteWithoutImageOcr : Note;
        if (text.Length > 0) note = ImageNotes.Append(note, ImageNotes.Wrap(text));
        return this with { Note = note, RecognizedText = text, RecognizedAt = recognizedAt, OcrInNote = text.Length > 0, OcrPending = false };
    }

    public Clip WithNoteEdit(Clip opened, string editedNote)
    {
        if (editedNote == opened.Note) return this;
        if (!opened.OcrInNote && OcrInNote && ImageNotes.Find(editedNote, null) is null &&
            ImageNotes.Find(Note, RecognizedText) is { } newBlock)
            editedNote = ImageNotes.Append(editedNote, Note[newBlock.Start..newBlock.End]);
        return this with { Note = editedNote };
    }

    [JsonIgnore]
    public string ImageExtension => ImageFormat switch
    {
        ClipImageFormat.Jpeg => "jpeg", ClipImageFormat.Tiff => "tiff", ClipImageFormat.Gif => "gif",
        ClipImageFormat.Bmp => "bmp", ClipImageFormat.WebP => "webp", ClipImageFormat.Heif => "heic",
        ClipImageFormat.Avif => "avif", _ => "png"
    };

    [JsonIgnore]
    public string ImageFileName => $"{Id:N}.{ImageExtension}";

    [JsonIgnore]
    public string DisplayTitle => Title.Length > 0 ? Title : LinkDetails?.Title ?? LinkDetails?.FallbackTitle ?? "";

    [JsonIgnore]
    public string? LinkResourceKey => Kind == ClipKind.Link ? LinkKey(Text) : null;

    internal bool SameContent(Clip other)
    {
        if (Kind != other.Kind || Kind == ClipKind.Aggregate) return false;
        if (OriginalItems is not null || other.OriginalItems is not null)
            return OriginalItems is not null && other.OriginalItems is not null &&
                OriginalItems.OrderBy(item => item.Order).SelectMany(item => item.Representations
                    .Select(rep => (item.Order, rep.Uti, rep.Hash)))
                .SequenceEqual(other.OriginalItems.OrderBy(item => item.Order).SelectMany(item => item.Representations
                    .Select(rep => (item.Order, rep.Uti, rep.Hash))));
        return Kind switch
        {
            ClipKind.Link when LinkKey(Text) is { } link => link == LinkKey(other.Text),
            ClipKind.Image => ImageHash == other.ImageHash,
            ClipKind.Files when FileIdentity is not null && other.FileIdentity is not null => FileIdentity == other.FileIdentity,
            ClipKind.Files => SamePaths(other),
            ClipKind.Text or ClipKind.Color or ClipKind.Code when Text is not null && other.Text is not null =>
                Text.Trim().Equals(other.Text.Trim(), StringComparison.Ordinal),
            _ => Text == other.Text && Html == other.Html && Rtf == other.Rtf &&
                ImageHash == other.ImageHash && SamePaths(other)
        };
    }

    internal static string? LinkKey(string? text) => Uri.TryCreate(text?.Trim(), UriKind.Absolute, out var uri) &&
        uri.Scheme is "http" or "https" && uri.Host.Length != 0 && uri.UserInfo.Length == 0
        ? uri.IdnHost.ToLowerInvariant() + uri.AbsolutePath.TrimEnd('/') : null;

    private bool SamePaths(Clip other) => Files.SequenceEqual(other.Files, StringComparer.OrdinalIgnoreCase);

    internal long Size => IndexSize + ImageSize + OriginalRepresentations.DistinctBy(rep => rep.Hash).Sum(rep => (long)rep.Size);

    internal long IndexSize => 256L + Encoding.UTF8.GetByteCount(Title) + Encoding.UTF8.GetByteCount(Note) +
        Encoding.UTF8.GetByteCount(Group) + Encoding.UTF8.GetByteCount(Source) + Bytes(Text) + Bytes(Html) + Bytes(Rtf) +
        Bytes(RecognizedText) + Bytes(LinkDetails?.Title) + Bytes(LinkDetails?.FallbackTitle) +
        (LinkDetails?.Attempts?.Length ?? 0) * 96L + Files.Sum(path => (long)Encoding.UTF8.GetByteCount(path)) +
        Uses.Length * 32L +
        Captures.Sum(capture => 48L + Bytes(capture.Source) + Bytes(capture.Context) + Bytes(capture.Url) +
            (capture.Details?.Sum(detail => Bytes(detail.Key) + Bytes(detail.Value)) ?? 0)) +
        Conversions.Sum(conversion => 32L + Bytes(conversion.Original) + Bytes(conversion.Source));

    private static int Bytes(string? text) => text is null ? 0 : Encoding.UTF8.GetByteCount(text);

    public bool Matches(string query, IEnumerable<string>? collections = null) =>
        query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
        .All(term => Contains(Title, term) || Contains(Text, term) || Contains(Note, term) ||
            Contains(Source, term) || Contains(Group, term) || Contains(RecognizedImageText, term) ||
            Contains(LinkDetails?.Title, term) || Contains(LinkDetails?.FallbackTitle, term) || Files.Any(path => Contains(path, term)) ||
            Captures.Any(capture => Contains(capture.Source, term) || Contains(capture.Context, term) || Contains(capture.Url, term) ||
                capture.Details?.Values.Any(value => Contains(value, term)) == true) ||
            collections?.Any(name => Contains(name, term)) == true);

    private static bool Contains(string? value, string term) =>
        value?.Contains(term, StringComparison.OrdinalIgnoreCase) == true;
}
