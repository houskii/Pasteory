using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Pasteory.Core;

public enum AggregationClaimKind { Fact, Inference, Action }

public sealed record AggregationEvidence(Guid ClipId, string Quote);
public sealed record AggregationClaim(AggregationClaimKind Kind, string Text, AggregationEvidence[] Evidence);
public sealed record AggregationSourceRevision(Guid ClipId, string Revision);

public sealed record AggregationSummary(AggregationClaim[] Claims, AggregationSourceRevision[] Sources, DateTimeOffset GeneratedAt)
{
    [JsonIgnore]
    public bool HasReferences
    {
        get
        {
            if (Sources is not { Length: > 0 } || Claims is not { Length: > 0 } ||
                Sources.Any(source => source is null || source.ClipId == Guid.Empty || source.Revision is not { Length: 64 })) return false;
            var sourceIds = Sources.Select(source => source.ClipId).ToHashSet();
            return Claims.All(claim => claim is not null && Enum.IsDefined(claim.Kind) && !string.IsNullOrWhiteSpace(claim.Text) &&
                claim.Evidence is { Length: > 0 } && claim.Evidence.All(evidence => evidence is not null &&
                    !string.IsNullOrWhiteSpace(evidence.Quote) && sourceIds.Contains(evidence.ClipId)));
        }
    }

    public bool IsCurrent(IReadOnlyDictionary<Guid, Clip> originals) => HasReferences && Sources.All(source =>
        originals.TryGetValue(source.ClipId, out var clip) && clip.Kind != ClipKind.Aggregate && clip.TrashedAt is null &&
        RevisionFor(clip).Equals(source.Revision, StringComparison.OrdinalIgnoreCase));

    public static string RevisionFor(Clip clip) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new
    {
        clip.Kind, clip.Title, clip.Text, clip.Html, clip.Rtf, clip.Files, clip.Note, clip.ImageHash,
        automaticTitle = clip.LinkDetails?.Title ?? clip.LinkDetails?.FallbackTitle,
        recognizedText = clip.RecognizedImageText, deleted = clip.TrashedAt is not null,
        originals = (clip.OriginalItems ?? []).OrderBy(item => item.Order).Select(item => item.Representations.Select(rep => new { rep.Uti, rep.Hash }))
    })));

    internal AggregationSummary RemapSources(IReadOnlyDictionary<Guid, Guid> mapping)
    {
        Guid Resolve(Guid id) => mapping.GetValueOrDefault(id, id);
        return this with
        {
            Sources = Sources.Select(source => source with { ClipId = Resolve(source.ClipId) }).Distinct().ToArray(),
            Claims = Claims.Select(claim => claim with
            {
                Evidence = claim.Evidence.Select(evidence => evidence with { ClipId = Resolve(evidence.ClipId) }).Distinct().ToArray()
            }).ToArray()
        };
    }
}
