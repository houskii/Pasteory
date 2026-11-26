using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;

namespace Pasteory.Windows;

internal sealed class LinkAccessPolicy
{
    private static readonly HashSet<string> UnsafeSegments = new(StringComparer.OrdinalIgnoreCase)
    {
        "logout", "signout", "delete", "unsubscribe", "accept-invite", "confirm-delete"
    };

    internal Uri? FixtureOrigin { get; set; }

    internal static bool IsWebAddress(Uri uri) => uri.IsAbsoluteUri && uri.Scheme is "http" or "https" &&
        uri.Host.Length != 0 && uri.UserInfo.Length == 0;

    internal bool Allows(Uri uri)
    {
        if (!IsWebAddress(uri) || Uri.UnescapeDataString(uri.AbsolutePath).Split('/').Any(UnsafeSegments.Contains)) return false;
        string host = uri.IdnHost.TrimEnd('.').Trim('[', ']');
        if (host == "127.0.0.1" && uri.Scheme == "http" && FixtureOrigin is { } fixture && uri.Port == fixture.Port) return true;
        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase) ||
            host.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) return false;
        if (!IPAddress.TryParse(host, out var address)) return true;
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any) ||
            address.IsIPv6LinkLocal || address.IsIPv6UniqueLocal) return false;
        byte[] bytes = address.GetAddressBytes();
        return bytes.Length != 4 || !(bytes[0] == 10 || bytes[0] == 192 && bytes[1] == 168 ||
            bytes[0] == 172 && bytes[1] is >= 16 and <= 31 || bytes[0] == 169 && bytes[1] == 254);
    }
}
