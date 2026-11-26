using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Pasteory.Core;

namespace Pasteory.Windows;

internal sealed class FileCommandRunner
{
    internal sealed record Run(string Path, DateTimeOffset StartedAt, int? ExitCode = null, string? Error = null);
    private readonly Dictionary<string, Run> recent = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> active = new(StringComparer.OrdinalIgnoreCase);
    internal event Action<string>? Changed;
    internal Run? Latest(string extension) => recent.GetValueOrDefault(extension);
    internal static string LogFolder(string root) => Path.Combine(root, "logs", "file-commands");

    internal async Task<Run?> RunAsync(string root, FileOpenRule rule, string file)
    {
        string logPath = "";
        var started = DateTimeOffset.UtcNow;
        try
        {
            string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            var start = new ProcessStartInfo(shell)
            {
                WorkingDirectory = Path.GetDirectoryName(file)!, UseShellExecute = false,
                CreateNoWindow = !rule.ShowTerminal, RedirectStandardOutput = !rule.ShowTerminal,
                RedirectStandardError = !rule.ShowTerminal, RedirectStandardInput = !rule.ShowTerminal
            };
            start.ArgumentList.Add("-NoLogo");
            start.ArgumentList.Add("-NoProfile");
            if (!rule.ShowTerminal) start.ArgumentList.Add("-NonInteractive");
            start.ArgumentList.Add("-EncodedCommand");
            string code = "$file = $env:file\n" + rule.Command + (rule.ShowTerminal ? "\nStart-Sleep -Seconds 3" : "");
            start.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(code)));
            start.Environment["file"] = file;
            if (!rule.ShowTerminal)
            {
                Directory.CreateDirectory(LogFolder(root));
                logPath = Path.Combine(LogFolder(root), $"{started:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.log");
                active.Add(logPath);
                Publish(rule.Extension, new(logPath, started));
            }
            using var process = Process.Start(start) ?? throw new IOException("Could not start PowerShell.");
            if (rule.ShowTerminal) return null;
            process.StandardInput.Close();
            await using var log = new FileStream(logPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read,
                bufferSize: 8192, useAsync: false);
            var gate = new object();
            await Task.WhenAll(CopyLog(process.StandardOutput.BaseStream, log, gate, 512 * 1024),
                CopyLog(process.StandardError.BaseStream, log, gate, 512 * 1024), process.WaitForExitAsync());
            var complete = new Run(logPath, started, process.ExitCode);
            if (recent[rule.Extension].Path == logPath) Publish(rule.Extension, complete);
            return complete;
        }
        catch (Exception error) when (App.IsLocalError(error) || error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            var failed = new Run(logPath, started, Error: error.Message);
            if (!recent.TryGetValue(rule.Extension, out var latest) || latest.Path == logPath)
                Publish(rule.Extension, failed);
            return failed;
        }
        finally
        {
            if (logPath.Length > 0)
            {
                active.Remove(logPath);
                try
                {
                    foreach (var old in Directory.EnumerateFiles(LogFolder(root), "*.log")
                        .OrderDescending(StringComparer.OrdinalIgnoreCase).Skip(20).Where(path => !active.Contains(path)))
                        File.Delete(old);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }

    private void Publish(string extension, Run run)
    {
        recent[extension] = run;
        Changed?.Invoke(extension);
    }

    private static async Task CopyLog(Stream source, FileStream log, object gate, int limit)
    {
        var buffer = new byte[8192];
        int remaining = limit;
        int count;
        while ((count = await source.ReadAsync(buffer).ConfigureAwait(false)) > 0)
        {
            int length = Math.Min(count, remaining);
            if (length == 0) continue;
            lock (gate)
            {
                log.Write(buffer, 0, length);
                log.Flush();
            }
            remaining -= length;
        }
    }
}
