using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace Pasteory.Windows;

internal static class ImageOcr
{
    private static readonly SemaphoreSlim SingleImage = new(1);

    internal static async Task<string?> ReadAsync(byte[] image, string language, CancellationToken cancellation)
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
            if (engine is null) return null;

            stage = "image input";
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(image);
                await writer.StoreAsync().AsTask(cancellation).ConfigureAwait(false);
                writer.DetachStream();
            }
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellation).ConfigureAwait(false);
            stage = "bitmap conversion";
            uint longest = Math.Max(decoder.PixelWidth, decoder.PixelHeight);
            double ratio = longest > OcrEngine.MaxImageDimension ? (double)OcrEngine.MaxImageDimension / longest : 1;
            var transform = new BitmapTransform
            {
                ScaledWidth = Math.Max(1, (uint)(decoder.PixelWidth * ratio)),
                ScaledHeight = Math.Max(1, (uint)(decoder.PixelHeight * ratio))
            };
            using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)
                .AsTask(cancellation).ConfigureAwait(false);
            stage = "recognition";
            var result = await engine.RecognizeAsync(bitmap).AsTask(cancellation).ConfigureAwait(false);
            return string.IsNullOrWhiteSpace(result.Text) ? null : result.Text[..Math.Min(result.Text.Length, 64_000)];
        }
        catch (Exception error) when (error is COMException or ArgumentException or NotSupportedException)
        {
            System.Diagnostics.Trace.TraceWarning("Windows OCR unavailable during {0}: {1} (0x{2:X8})", stage,
                error.GetType().Name, error.HResult);
            return null;
        }
        finally { SingleImage.Release(); }
    }
}
