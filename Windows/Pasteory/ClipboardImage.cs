using System;
using System.Buffers.Binary;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed record ClipboardImage(ClipImageFormat Format, byte[] Bytes, int Width, int Height)
{
    internal static ClipboardImage? Read(byte[] bytes, long maxPixels)
    {
        var format = Detect(bytes);
        if (format is null) return null;
        var (width, height) = Dimensions(bytes);
        if (width <= 0 || height <= 0)
        {
            // Optional Windows codecs can be unavailable while the encoded bytes are still usable.
            return format is ClipImageFormat.Heif or ClipImageFormat.Avif or ClipImageFormat.WebP
                ? new(format.Value, bytes, 0, 0) : null;
        }
        return (long)width * height <= maxPixels ? new(format.Value, bytes, width, height) : null;
    }

    internal static (int Width, int Height) Dimensions(byte[] bytes)
    {
        if (Detect(bytes) == ClipImageFormat.Png &&
            bytes.Length >= 24 && bytes.AsSpan(12, 4).SequenceEqual("IHDR"u8))
            return (Math.Max(0, BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(16))),
                Math.Max(0, BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(20))));
        try
        {
            using var stream = new MemoryStream(bytes, writable: false);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
            var frame = decoder.Frames[0];
            return (frame.PixelWidth, frame.PixelHeight);
        }
        catch (Exception error) when (DecoderFailure(error)) { return (0, 0); }
    }

    internal static BitmapSource? ClipboardBitmap(byte[] bytes)
    {
        try
        {
            using var stream = new MemoryStream(bytes, writable: false);
            return BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        }
        catch (Exception error) when (DecoderFailure(error)) { return null; }
    }

    internal static BitmapSource Preview(byte[] bytes, int maximumDimension, int width, int height)
    {
        using var stream = new MemoryStream(bytes, writable: false);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        if (width >= height && width > maximumDimension) image.DecodePixelWidth = maximumDimension;
        else if (height > maximumDimension) image.DecodePixelHeight = maximumDimension;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }

    internal static byte[] EncodePng(BitmapSource bitmap)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    internal static bool DecoderFailure(Exception error) =>
        error is IOException or COMException or NotSupportedException or ArgumentException or FileFormatException;

    private static ClipImageFormat? Detect(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 12) return null;
        if (bytes[0] == 137 && bytes.Slice(1, 7).SequenceEqual("PNG\r\n\x1a\n"u8)) return ClipImageFormat.Png;
        if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return ClipImageFormat.Jpeg;
        if (bytes.StartsWith("II*\0"u8) || bytes.StartsWith("MM\0*"u8)) return ClipImageFormat.Tiff;
        if (bytes.StartsWith("GIF87a"u8) || bytes.StartsWith("GIF89a"u8)) return ClipImageFormat.Gif;
        if (bytes.StartsWith("BM"u8)) return ClipImageFormat.Bmp;
        if (bytes.StartsWith("RIFF"u8) && bytes.Slice(8, 4).SequenceEqual("WEBP"u8)) return ClipImageFormat.WebP;
        if (bytes.Slice(4, 4).SequenceEqual("ftyp"u8))
        {
            var brand = bytes.Slice(8, 4);
            if (brand.SequenceEqual("avif"u8) || brand.SequenceEqual("avis"u8)) return ClipImageFormat.Avif;
            if (brand.SequenceEqual("heic"u8) || brand.SequenceEqual("heix"u8) || brand.SequenceEqual("mif1"u8) ||
                brand.SequenceEqual("msf1"u8)) return ClipImageFormat.Heif;
        }
        return null;
    }
}
