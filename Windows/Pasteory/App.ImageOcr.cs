using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Pasteory.Core;

namespace Pasteory.Windows;

public partial class App
{
    private readonly Queue<Guid> pendingImageOcr = new();
    private readonly HashSet<Guid> queuedImageOcr = [];
    private CancellationTokenSource? imageOcrWorker;
    internal bool ImageOcrRunning => imageOcrWorker is { IsCancellationRequested: false };
    internal int ImageOcrCompleted { get; private set; }
    internal string? ImageOcrError { get; private set; }

    private static bool HasPendingImageOcr(Clip clip) => clip.OcrPending && clip.RecognizedText is null && clip.TrashedAt is null &&
        (clip.HasImage || clip.OriginalRepresentations.Any(item => MacClipboardFormats.IsImage(item.Uti)));

    private void ResumePendingImageOcr()
    {
        if (!Settings.RecognizeImages || Exiting) return;
        foreach (var clip in Clips.Where(HasPendingImageOcr).Reverse())
            if (queuedImageOcr.Add(clip.Id)) pendingImageOcr.Enqueue(clip.Id);
        StartImageOcrWorker();
    }

    private void EnqueueImageOcr(Clip clip)
    {
        if (!Settings.RecognizeImages || Exiting || !HasPendingImageOcr(clip) || !queuedImageOcr.Add(clip.Id)) return;
        pendingImageOcr.Enqueue(clip.Id);
        StartImageOcrWorker();
    }

    private void StopImageOcr()
    {
        pendingImageOcr.Clear();
        queuedImageOcr.Clear();
        imageOcrWorker?.Cancel();
    }

    private void StartImageOcrWorker()
    {
        if (imageOcrWorker is not null || pendingImageOcr.Count == 0 || !Settings.RecognizeImages || Exiting) return;
        imageOcrWorker = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        ImageOcrError = null;
        settingsWindow?.RefreshImageOcrStatus();
        _ = RecognizeImagesAsync(imageOcrWorker);
    }

    private async Task RecognizeImagesAsync(CancellationTokenSource worker)
    {
        var cancellation = worker.Token;
        try
        {
            while (!cancellation.IsCancellationRequested && pendingImageOcr.TryDequeue(out Guid id))
            {
                queuedImageOcr.Remove(id);
                if (Clips.FirstOrDefault(item => item.Id == id) is not { } clip || !HasPendingImageOcr(clip)) continue;
                await RecognizeImageAsync(clip, cancellation);
                settingsWindow?.RefreshImageOcrStatus();
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally
        {
            imageOcrWorker = null;
            worker.Dispose();
            settingsWindow?.RefreshImageOcrStatus();
            StartImageOcrWorker();
        }
    }

    private async Task RecognizeImageAsync(Clip clip, CancellationToken cancellation)
    {
        string language = Settings.Language;
        string text;
        try
        {
            text = await Task.Run(() => ImageOcr.ReadClipAsync(history, clip, language, cancellation), cancellation);
        }
        catch (Exception error) when (IsLocalError(error) || error is InvalidDataException or InvalidOperationException)
        {
            cancellation.ThrowIfCancellationRequested();
            ImageOcrError = IsLocalError(error) ? Labels.Get("Could not read a saved image for OCR.") : error.Message;
            return;
        }

        cancellation.ThrowIfCancellationRequested();
        if (Clips.FirstOrDefault(item => item.Id == clip.Id) is not { } current || !HasPendingImageOcr(current)) return;
        if (current.ImageHash != clip.ImageHash || current.OriginalItems != clip.OriginalItems || current.OcrMode != clip.OcrMode)
        {
            EnqueueImageOcr(current);
            return;
        }

        var mode = clip.OcrMode ?? ImageOcrMode.Accurate;
        if (UpdateClip(clip.Id, item => item.WithImageRecognition(text, DateTimeOffset.UtcNow, mode))) ImageOcrCompleted++;
        else ImageOcrError = Labels.Get("Could not save changes to this clip.");
    }
}
