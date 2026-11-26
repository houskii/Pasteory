using System;
using System.Linq;
using System.Threading.Tasks;

namespace Pasteory.Windows;

public partial class App
{
    private bool recognizingImages;

    private async Task RecognizePendingImagesAsync()
    {
        if (recognizingImages || !Settings.RecognizeImages || Exiting) return;
        recognizingImages = true;
        try
        {
            while (!Exiting && Settings.RecognizeImages &&
                Clips.FirstOrDefault(clip => clip.OcrPending && clip.HasImage && clip.TrashedAt is null) is { } clip)
            {
                string? text = null;
                try
                {
                    var image = await Task.Run(() => history.ReadImage(clip), lifetime.Token);
                    text = await ImageOcr.ReadAsync(image, Settings.Language, lifetime.Token);
                }
                catch (Exception error) when (IsLocalError(error))
                {
                    System.Diagnostics.Trace.TraceWarning("The saved image could not be read for OCR: {0}", error.GetType().Name);
                }

                if (Exiting || !Settings.RecognizeImages) return;
                if (!Clips.Any(current => current.Id == clip.Id && current.OcrPending &&
                    current.TrashedAt is null && current.ImageHash == clip.ImageHash)) continue;
                var recognizedAt = DateTimeOffset.UtcNow;
                if (!UpdateClip(clip.Id, current => text is null ? current with { OcrPending = false } :
                    current.WithImageRecognition(text, recognizedAt))) return;
            }
        }
        catch (OperationCanceledException) when (Exiting) { }
        finally { recognizingImages = false; }
    }
}
