using System;
using System.Collections.Generic;
using System.IO;

namespace BackupSyncGui.Services;

/// <summary>
/// Port of the executable scan in Setup-BackupSync.ps1: depth-first over the
/// source folder, skipping reparse points and the recovery directory.
/// </summary>
internal static class ExecutableDiscovery
{
    private const string RecoveryDirectoryName = ".backup_sync_recovery";

    public static IReadOnlyList<string> Find(string sourceFolder)
    {
        List<string> found = new List<string>();
        if (!Directory.Exists(sourceFolder))
        {
            return found;
        }

        Stack<string> pending = new Stack<string>();
        pending.Push(sourceFolder);
        while (pending.Count > 0)
        {
            string current = pending.Pop();
            IEnumerable<string> entries;
            try
            {
                entries = Directory.EnumerateFileSystemEntries(current);
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }
            catch (IOException)
            {
                continue;
            }

            foreach (string entry in entries)
            {
                FileAttributes attributes;
                try
                {
                    attributes = File.GetAttributes(entry);
                }
                catch (Exception)
                {
                    continue;
                }
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    continue;
                }
                string name = Path.GetFileName(entry);
                if (string.Equals(name, RecoveryDirectoryName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    pending.Push(entry);
                    continue;
                }
                if (string.Equals(Path.GetExtension(entry), ".exe", StringComparison.OrdinalIgnoreCase))
                {
                    found.Add(entry);
                }
            }
        }

        found.Sort(StringComparer.OrdinalIgnoreCase);
        return found;
    }

    /// <summary>Path relative to the source root when inside it, otherwise absolute.</summary>
    public static string ToConfigurationValue(string sourceFolder, string executablePath)
    {
        string prefix = ConfigurationFileService.NormalizePath(sourceFolder) + "\\";
        string normalized = ConfigurationFileService.NormalizePath(executablePath);
        if (normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return normalized.Substring(prefix.Length);
        }
        return normalized;
    }
}
