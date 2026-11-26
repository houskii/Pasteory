using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.CSharp.RuntimeBinder;

namespace Pasteory.Windows;

internal sealed record DesktopApplication(string Name, string Path)
{
    internal string ProcessName => System.IO.Path.GetFileNameWithoutExtension(Path);

    internal bool Matches(string query) => Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
        Path.Contains(query, StringComparison.OrdinalIgnoreCase);
}

internal static class DesktopApplicationCatalog
{
    internal static Task<DesktopApplication[]> DiscoverAsync(string[] extraPaths, CancellationToken cancellation) =>
        Task.Run(() =>
        {
            var apps = new Dictionary<string, DesktopApplication>(StringComparer.OrdinalIgnoreCase);
            ReadStartMenu(apps, cancellation);
            foreach (string path in extraPaths)
            {
                cancellation.ThrowIfCancellationRequested();
                if (!IsLocalExecutable(path) || apps.ContainsKey(path)) continue;
                if (Reference(path) is { } application) apps.TryAdd(application.Path, application);
            }
            return apps.Values.OrderBy(app => app.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(app => app.Path, StringComparer.OrdinalIgnoreCase).ToArray();
        }, cancellation);

    internal static DesktopApplication? Reference(string path, string? name = null)
    {
        if (!Path.IsPathFullyQualified(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(path)) return null;
        if (string.IsNullOrWhiteSpace(name))
        {
            try { name = FileVersionInfo.GetVersionInfo(path).FileDescription; }
            catch (Exception error) when (App.IsLocalError(error) || error is ArgumentException) { }
        }
        return new(string.IsNullOrWhiteSpace(name) ? Path.GetFileNameWithoutExtension(path) : name, Path.GetFullPath(path));
    }

    private static void ReadStartMenu(Dictionary<string, DesktopApplication> apps, CancellationToken cancellation)
    {
        object? shell = null, folder = null, items = null;
        try
        {
            if (Type.GetTypeFromProgID("Shell.Application") is not { } shellType) return;
            shell = Activator.CreateInstance(shellType);
            if (shell is null) return;
            folder = ((dynamic)shell).NameSpace("shell:AppsFolder");
            if (folder is null) return;
            items = ((dynamic)folder).Items();
            if (items is null) return;
            int count = ((dynamic)items).Count;
            for (int i = 0; i < count; i++)
            {
                cancellation.ThrowIfCancellationRequested();
                object? item = null;
                try
                {
                    item = ((dynamic)items).Item(i);
                    if (item is null) continue;
                    dynamic entry = item;
                    string? path = entry.ExtendedProperty("System.Link.TargetParsingPath") as string;
                    if (!IsLocalExecutable(path)) path = entry.Path as string;
                    if (!IsLocalExecutable(path) || apps.ContainsKey(path!)) continue;
                    if (Reference(path!, entry.Name as string) is { } application) apps.TryAdd(application.Path, application);
                }
                catch (Exception error) when (error is COMException or RuntimeBinderException or ArgumentException) { }
                finally { Release(item); }
            }
        }
        catch (Exception error) when (error is COMException or RuntimeBinderException or UnauthorizedAccessException) { }
        finally
        {
            Release(items);
            Release(folder);
            Release(shell);
        }
    }

    private static bool IsLocalExecutable(string? path) => path is { Length: > 0 } &&
        !path.StartsWith(@"\\", StringComparison.Ordinal) && Path.IsPathFullyQualified(path) &&
        path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);

    private static void Release(object? value)
    {
        if (value is not null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
    }
}
