using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Pasteory.Core;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace Pasteory.Windows;

internal static class ImageOcr
{
    private static readonly SemaphoreSlim SingleImage = new(1);

    internal static async Task<string> ReadClipAsync(HistoryStore history, Clip clip, string language, CancellationToken cancellation)
    {
        var mode = clip.OcrMode ?? ImageOcrMode.Accurate;
        if (clip.OriginalItems is null)
            return await ReadAsync(history.ReadImage(clip), language, mode, cancellation).ConfigureAwait(false);

        var texts = new List<string>();
        foreach (var item in clip.OriginalItems.OrderBy(item => item.Order))
        {
            Exception? failure = null;
            foreach (var image in MacClipboardFormats.Images(item))
            {
                cancellation.ThrowIfCancellationRequested();
                try
                {
                    string text = await ReadAsync(history.ReadRepresentation(image), language, mode, cancellation).ConfigureAwait(false);
                    texts.Add(text);
                    failure = null;
                    break;
                }
                catch (Exception error) when (App.IsLocalError(error) || error is InvalidDataException) { failure = error; }
            }
            if (failure is not null) throw new InvalidDataException(Labels.Get("Could not read a saved image for OCR."), failure);
        }
        if (texts.Count == 0 && clip.HasImage)
            return await ReadAsync(history.ReadImage(clip), language, mode, cancellation).ConfigureAwait(false);
        return string.Join('\n', texts.Where(text => text.Length > 0));
    }

    internal static async Task<string> ReadAsync(byte[] image, string language, ImageOcrMode mode, CancellationToken cancellation)
    {
        await SingleImage.WaitAsync(cancellation).ConfigureAwait(false);
        string stage = "language selection";
        try
        {
            string? desired = language switch
            {
                "简体中文" => "zh-Hans",
                "English" => "en",
                _ => null
            };
            var installed = OcrEngine.AvailableRecognizerLanguages;
            var preferred = desired is null ? null : installed.FirstOrDefault(item => item.LanguageTag.Equals(desired, StringComparison.OrdinalIgnoreCase) ||
                item.LanguageTag.StartsWith(desired + "-", StringComparison.OrdinalIgnoreCase));
            var engine = preferred is not null ? OcrEngine.TryCreateFromLanguage(preferred) : OcrEngine.TryCreateFromUserProfileLanguages();
            if (engine is null && installed.FirstOrDefault() is { } fallback) engine = OcrEngine.TryCreateFromLanguage(fallback);
            if (engine is null) throw new InvalidOperationException(Labels.Get("Windows OCR could not start. Check the installed recognition languages."));

            stage = "bitmap conversion";
            using var bitmap = await DecodeAsync(image, mode, cancellation).ConfigureAwait(false);
            stage = "recognition";
            var result = await engine.RecognizeAsync(bitmap).AsTask(cancellation).ConfigureAwait(false);
            return string.Join('\n', result.Lines.Select(line => line.Text));
        }
        catch (Exception error) when (error is COMException or ArgumentException or NotSupportedException)
        {
            System.Diagnostics.Trace.TraceWarning("Windows OCR unavailable during {0}: {1} (0x{2:X8})", stage,
                error.GetType().Name, error.HResult);
            throw new InvalidDataException(Labels.Get("Windows couldn't recognize text in this image."), error);
        }
        finally { SingleImage.Release(); }
    }

    internal static async Task<SoftwareBitmap> DecodeAsync(byte[] image, ImageOcrMode mode, CancellationToken cancellation)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(image);
            await writer.StoreAsync().AsTask(cancellation).ConfigureAwait(false);
            writer.DetachStream();
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellation).ConfigureAwait(false);
        uint limit = OcrEngine.MaxImageDimension;
        if (mode == ImageOcrMode.Fast) limit = Math.Min(1280, limit);
        uint longest = Math.Max(decoder.PixelWidth, decoder.PixelHeight);
        var transform = new BitmapTransform();
        if (longest > limit)
        {
            double ratio = (double)limit / longest;
            transform.ScaledWidth = Math.Max(1, (uint)Math.Round(decoder.PixelWidth * ratio));
            transform.ScaledHeight = Math.Max(1, (uint)Math.Round(decoder.PixelHeight * ratio));
        }
        return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage)
            .AsTask(cancellation).ConfigureAwait(false);
    }
}
