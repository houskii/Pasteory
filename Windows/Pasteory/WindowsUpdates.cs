using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Pasteory.Windows;

internal sealed record SignedUpdateIndex(string Payload, string Signature);
internal sealed record UpdateIndex(int FormatVersion, UpdateOffer[] Releases);
internal sealed record UpdateOffer(string Version, string Architecture, string DownloadUrl, string Sha256, long Length, string Notes);
internal sealed record UpdatePointer(SignedUpdateIndex Index, string Version, string ExecutableHash);

internal sealed class WindowsUpdates(string dataRoot)
{
    private static readonly Uri Feed = new("https://raw.githubusercontent.com/houskii/Pasteory/main/release/windows/appcast.json");
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        UseCookies = false, MaxAutomaticRedirections = 4, MaxResponseHeadersLength = 32
    }) { Timeout = Timeout.InfiniteTimeSpan };
    private const long MaxPackage = 300L * 1024 * 1024;
    private readonly string root = Path.Combine(dataRoot, "windows-updates");
    private SignedUpdateIndex? availableIndex;
    internal UpdateOffer? Available { get; private set; }
    internal static Version CurrentVersion => Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 1, 57);
    private static string? ArchitectureName => RuntimeInformation.ProcessArchitecture switch
    { Architecture.X64 => "x64", Architecture.Arm64 => "arm64", _ => null };

    internal async Task<UpdateOffer?> CheckAsync(CancellationToken cancel)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        using var response = await Client.GetAsync(Feed, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            availableIndex = null;
            return Available = null;
        }
        response.EnsureSuccessStatusCode();
        if (response.RequestMessage?.RequestUri != Feed) throw new InvalidDataException("The update feed address changed.");
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        byte[] bytes = new byte[256 * 1024];
        int read = await stream.ReadAtLeastAsync(bytes, bytes.Length, false, timeout.Token);
        if (read == bytes.Length) throw new InvalidDataException("The update feed is too large.");
        var index = JsonSerializer.Deserialize<SignedUpdateIndex>(bytes.AsSpan(0, read), AiFile.Json) ??
            throw new InvalidDataException("The Windows update feed is empty.");
        var releases = Verify(index, Key()).Releases;
        availableIndex = index;
        return Available = releases.Where(offer => offer.Architecture == ArchitectureName && Newer(offer.Version))
            .OrderByDescending(offer => Version.Parse(offer.Version)).FirstOrDefault();
    }

    internal async Task<string> StageAsync(UpdateOffer offer, IProgress<double> progress, CancellationToken cancel)
    {
        var index = availableIndex ?? throw new InvalidDataException("An update check is required.");
        if (!Equals(Available, offer) || !Verify(index, Key()).Releases.Contains(offer) ||
            offer.Architecture != ArchitectureName || !Newer(offer.Version)) throw new InvalidDataException("Update details changed.");
        Directory.CreateDirectory(root);
        string stage = Path.Combine(root, ".stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            string archive = Path.Combine(stage, "package.zip");
            await DownloadAsync(offer, archive, progress, cancel);
            cancel.ThrowIfCancellationRequested();
            string ready = Path.Combine(stage, "app");
            Directory.CreateDirectory(ready);
            await Task.Run(() => Extract(archive, ready, cancel), cancel);
            string next = VersionDirectory(offer);
            string exe = Path.Combine(ready, "Pasteory.exe");
            if (!File.Exists(exe)) throw new InvalidDataException("The update package is missing Pasteory.exe.");
            string digest;
            using (var file = File.OpenRead(exe)) digest = Convert.ToHexString(SHA256.HashData(file));
            cancel.ThrowIfCancellationRequested();
            Directory.CreateDirectory(Path.GetDirectoryName(next)!);
            if (Directory.Exists(next))
            {
                var pointer = AiFile.Load<UpdatePointer>(Path.Combine(root, "current.json"));
                string path = Path.Combine(next, "Pasteory.exe");
                if (pointer?.Version == offer.Version && pointer.Index == index && CheckFile(path, digest)) return path;
                throw new IOException("An existing update installation has different contents.");
            }
            Directory.Move(ready, next);
            try { AiFile.Save(Path.Combine(root, "current.json"), new UpdatePointer(index, offer.Version, digest)); }
            catch
            {
                // Roll back an unactivated installation while the running version is still available.
                Directory.Move(next, ready);
                throw;
            }
            return Path.Combine(next, "Pasteory.exe");
        }
        finally
        {
            try { Directory.Delete(stage, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    internal string? InstalledNewer()
    {
        try
        {
            var pointer = AiFile.Load<UpdatePointer>(Path.Combine(root, "current.json"));
            if (pointer is null || !Newer(pointer.Version)) return null;
            var offer = Verify(pointer.Index, Key()).Releases.SingleOrDefault(item =>
                item.Architecture == ArchitectureName && item.Version == pointer.Version);
            if (offer is null) return null;
            string path = Path.Combine(VersionDirectory(offer), "Pasteory.exe");
            return CheckFile(path, pointer.ExecutableHash) ? path : null;
        }
        catch (Exception error) when (IsUpdateError(error)) { return null; }
    }

    internal static UpdateIndex Verify(SignedUpdateIndex index, byte[] key)
    {
        byte[] payload = Convert.FromBase64String(index.Payload);
        byte[] signature = Convert.FromBase64String(index.Signature);
        if (key.Length != 32 || signature.Length != 64 || payload.Length > 128 * 1024)
            throw new InvalidDataException("Invalid update signature.");
        var verifier = new Ed25519Signer();
        verifier.Init(false, new Ed25519PublicKeyParameters(key, 0));
        verifier.BlockUpdate(payload, 0, payload.Length);
        if (!verifier.VerifySignature(signature)) throw new InvalidDataException("Invalid update signature.");
        var result = JsonSerializer.Deserialize<UpdateIndex>(payload, AiFile.Json);
        if (result is not { FormatVersion: 1, Releases.Length: <= 60 } ||
            result.Releases.Select(offer => (offer.Version, offer.Architecture)).Distinct().Count() != result.Releases.Length ||
            result.Releases.Any(offer => !ValidOffer(offer))) throw new InvalidDataException("Invalid Windows release index.");
        return result;
    }

    private static bool ValidOffer(UpdateOffer offer)
    {
        if (offer.Architecture is not ("x64" or "arm64") || !Version.TryParse(offer.Version, out var version) || version.Build < 0 ||
            version.Revision >= 0 || offer.Version != version.ToString(3) || offer.Length is < 1 or > MaxPackage ||
            offer.Sha256 is not { Length: 64 } || !offer.Sha256.All(char.IsAsciiHexDigit) ||
            offer.Notes is null || offer.Notes.Length > 15000) return false;
        string expected = $"https://github.com/houskii/Pasteory/releases/download/windows-v{offer.Version}/Pasteory-win-{offer.Architecture}.zip";
        return offer.DownloadUrl.Equals(expected, StringComparison.Ordinal);
    }

    private static async Task DownloadAsync(UpdateOffer offer, string path, IProgress<double> progress, CancellationToken cancel)
    {
        using var response = await Client.GetAsync(offer.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancel);
        response.EnsureSuccessStatusCode();
        var actual = response.RequestMessage?.RequestUri;
        if (actual?.Scheme != "https" || actual.Host is not ("github.com" or "release-assets.githubusercontent.com" or "objects.githubusercontent.com"))
            throw new InvalidDataException("Windows update download used an unexpected server.");
        await using var stream = await response.Content.ReadAsStreamAsync(cancel);
        await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[65536];
        long total = 0;
        int read;
        while ((read = await stream.ReadAsync(buffer, cancel)) > 0)
        {
            total += read;
            if (total > offer.Length) throw new InvalidDataException("The update package is larger than expected.");
            await file.WriteAsync(buffer.AsMemory(0, read), cancel);
            hash.AppendData(buffer, 0, read);
            progress.Report((double)total / offer.Length);
        }
        if (total != offer.Length || !Convert.ToHexString(hash.GetHashAndReset()).Equals(offer.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The Windows update checksum does not match.");
    }

    private static void Extract(string archive, string directory, CancellationToken cancel)
    {
        using var zip = ZipFile.OpenRead(archive);
        long expanded = 0;
        foreach (var entry in zip.Entries)
        {
            cancel.ThrowIfCancellationRequested();
            string relative = entry.FullName.Replace('\\', '/').TrimEnd('/');
            string[] parts = relative.Split('/');
            if (parts.Any(part => part.Length == 0 || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' ') ||
                part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                System.Text.RegularExpressions.Regex.IsMatch(part, @"^(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)", System.Text.RegularExpressions.RegexOptions.IgnoreCase)))
                throw new InvalidDataException("Invalid path inside Windows update.");
            string target = Path.Combine(directory, Path.Combine(parts));
            if (entry.Name.Length == 0) { Directory.CreateDirectory(target); continue; }
            expanded += entry.Length;
            if (expanded > 1024L * 1024 * 1024) throw new InvalidDataException("The expanded Windows update is too large.");
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            using var input = entry.Open();
            using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            input.CopyTo(output);
        }
    }

    private string VersionDirectory(UpdateOffer offer) => Path.Combine(root, offer.Architecture, offer.Version);

    private static bool Newer(string candidate) => Version.TryParse(candidate, out var value) &&
        value > new Version(CurrentVersion.Major, CurrentVersion.Minor, CurrentVersion.Build);

    private static bool CheckFile(string file, string hash)
    {
        if (!File.Exists(file) || hash.Length != 64) return false;
        using var stream = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(stream)).Equals(hash, StringComparison.OrdinalIgnoreCase);
    }

    private static byte[] Key()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Pasteory.UpdatePublicKey.txt") ??
            throw new InvalidDataException("The Windows update public key is missing.");
        using var reader = new StreamReader(stream);
        return Convert.FromBase64String(reader.ReadToEnd().Trim());
    }

    internal static bool IsUpdateError(Exception error) => App.IsLocalError(error) || error is IOException or
        JsonException or FormatException or ArgumentException or HttpRequestException or InvalidDataException or
        InvalidOperationException or System.ComponentModel.Win32Exception;
}
