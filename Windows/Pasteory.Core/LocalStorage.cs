using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Pasteory.Core;

public static class LocalStorage
{
    internal readonly record struct FileSize(long Length, long AllocatedBytes, uint Links, DateTime LastWrite)
    {
        internal long ReclaimableBytes => Links == 1 ? AllocatedBytes : 0;
    }

    public static long AllocatedBytes(string path) => Inspect(path)?.AllocatedBytes ?? 0;

    public static long? VolumeCapacity(string directory)
    {
        if (OperatingSystem.IsWindows() && GetDiskFreeSpaceEx(directory, out _, out ulong capacity, out _) &&
            capacity is > 0 and <= long.MaxValue)
            return (long)capacity;
        return null;
    }

    internal static bool IsOrdinaryDirectory(string path) =>
        Attributes(path) is { } flags && (flags & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == FileAttributes.Directory;

    internal static FileSize? Inspect(string path)
    {
        if (Attributes(path) is not { } flags ||
            (flags & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0) return null;
        try
        {
            var file = new FileInfo(path);
            if (!OperatingSystem.IsWindows()) return new(file.Length, file.Length, 1, file.LastWriteTimeUtc);
            using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (!GetStandardInfo(handle, 1, out var info, (uint)Marshal.SizeOf<StandardInfo>()) ||
                info.Directory != 0 || info.DeletePending != 0) return null;
            long allocated = info.AllocationSize;
            if ((flags & (FileAttributes.Compressed | FileAttributes.SparseFile)) != 0)
            {
                if (GetCompressionInfo(handle, 8, out var compression, (uint)Marshal.SizeOf<CompressionInfo>()))
                    allocated = compression.CompressedSize;
            }
            return new(info.EndOfFile, allocated, info.NumberOfLinks, file.LastWriteTimeUtc);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    internal static FileAttributes? Attributes(string path)
    {
        try { return File.GetAttributes(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    internal static bool TryCompressFile(string path)
    {
        if (!OperatingSystem.IsWindows()) return false;
        const FileAttributes excluded = FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Offline |
            FileAttributes.Encrypted | FileAttributes.Compressed | FileAttributes.SparseFile;
        if (Attributes(path) is not { } flags || (flags & excluded) != 0) return false;

        const uint readWrite = 0xC0000000, shareRead = 1, openExisting = 3, openReparsePoint = 0x00200000;
        using var handle = CreateFile(path, readWrite, shareRead, IntPtr.Zero, openExisting, openReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid || !GetAttributeInfo(handle, 9, out var attributes, (uint)Marshal.SizeOf<AttributeTagInfo>()) ||
            (attributes.Attributes & excluded) != 0 ||
            !GetStandardInfo(handle, 1, out var info, (uint)Marshal.SizeOf<StandardInfo>()) || info.NumberOfLinks != 1 ||
            info.EndOfFile <= 4096 || info.DeletePending != 0) return false;

        const uint setCompression = 0x0009C040;
        ushort defaultCompression = 1;
        return DeviceIoControl(handle, setCompression, ref defaultCompression, sizeof(ushort), IntPtr.Zero, 0, out _, IntPtr.Zero);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AttributeTagInfo
    {
        internal FileAttributes Attributes;
        internal uint ReparseTag;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StandardInfo
    {
        internal long AllocationSize;
        internal long EndOfFile;
        internal uint NumberOfLinks;
        internal byte DeletePending;
        internal byte Directory;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CompressionInfo
    {
        internal long CompressedSize;
        internal ushort Format;
        internal byte UnitShift;
        internal byte ChunkShift;
        internal byte ClusterShift;
        internal byte Reserved1;
        internal byte Reserved2;
        internal byte Reserved3;
    }

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetStandardInfo(SafeFileHandle handle, int code, out StandardInfo info, uint size);

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCompressionInfo(SafeFileHandle handle, int code, out CompressionInfo info, uint size);

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetAttributeInfo(SafeFileHandle handle, int code, out AttributeTagInfo info, uint size);

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, ref ushort input, uint inputSize,
        IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);

    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceExW", CharSet = CharSet.Unicode, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceEx(string directory, out ulong available, out ulong capacity, out ulong free);
}
