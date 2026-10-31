using System;
using System.Diagnostics;
using System.IO;

namespace BackupSyncGui.Services;

/// <summary>
/// Creates the same three shortcuts Setup-BackupSync.ps1 creates, through the
/// Windows Script Host COM object so icon and description metadata match.
/// </summary>
internal static class ShortcutService
{
    public const string LauncherShortcutName = "Launcher.backup-sync.lnk";

    public const string SyncOnlyShortcutName = "Sync only.backup-sync.lnk";

    public const string FolderShortcutName = "Backup folder.backup-sync.lnk";

    public static string GetLauncherPath(string sourceFolder)
    {
        return Path.Combine(sourceFolder, LauncherShortcutName);
    }

    public static string GetSyncOnlyPath(string sourceFolder)
    {
        return Path.Combine(sourceFolder, SyncOnlyShortcutName);
    }

    public static string GetFolderShortcutPath(string sourceFolder)
    {
        return Path.Combine(sourceFolder, FolderShortcutName);
    }

    public static void CreateShortcuts(string sourceFolder, string destinationFolder, string executablePath, string powerShellFolder)
    {
        string startScript = ScriptLocator.GetScriptPath(powerShellFolder, ScriptLocator.StartScriptFileName);
        string powerShellExecutable = BackupSyncProcessRunner.PowerShellExecutablePath;
        string baseArguments = "-NoProfile -ExecutionPolicy Bypass -File " +
                               BackupSyncProcessRunner.Quote(startScript) +
                               " -Source " + BackupSyncProcessRunner.Quote(sourceFolder);

        Type? shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType is null)
        {
            throw new InvalidOperationException(
                "The Windows Script Host (WScript.Shell) is not available on this system, so shortcuts cannot be created.");
        }
        object shellObject = Activator.CreateInstance(shellType)
                             ?? throw new InvalidOperationException("Could not create the Windows Script Host object.");

        WriteActionShortcut(
            shellObject,
            Path.Combine(sourceFolder, LauncherShortcutName),
            powerShellExecutable,
            baseArguments,
            sourceFolder,
            "Launch configured application, wait, then synchronize",
            executablePath);

        WriteActionShortcut(
            shellObject,
            Path.Combine(sourceFolder, SyncOnlyShortcutName),
            powerShellExecutable,
            baseArguments + " -SyncOnly",
            sourceFolder,
            "Synchronize now without launching the application",
            executablePath);

        dynamic shell = shellObject;
        dynamic folderShortcut = shell.CreateShortcut(Path.Combine(sourceFolder, FolderShortcutName));
        folderShortcut.TargetPath = destinationFolder;
        folderShortcut.WorkingDirectory = destinationFolder;
        folderShortcut.Description = "Open the backup destination folder";
        folderShortcut.Save();
    }

    /// <summary>Files this application creates or manages inside a source folder.</summary>
    public static int CountApplicationFiles(string sourceFolder)
    {
        return GetApplicationFiles(sourceFolder).Count;
    }

    public static System.Collections.Generic.IReadOnlyList<string> GetApplicationFiles(string sourceFolder)
    {
        System.Collections.Generic.List<string> files = new System.Collections.Generic.List<string>();
        if (!Directory.Exists(sourceFolder))
        {
            return files;
        }
        try
        {
            foreach (string file in Directory.EnumerateFiles(sourceFolder, "*", SearchOption.TopDirectoryOnly))
            {
                if (Path.GetFileName(file).Contains("backup-sync", StringComparison.OrdinalIgnoreCase))
                {
                    files.Add(file);
                }
            }
        }
        catch (Exception)
        {
            return files;
        }
        files.Sort(StringComparer.OrdinalIgnoreCase);
        return files;
    }

    private static void WriteActionShortcut(
        object shellObject,
        string shortcutPath,
        string targetPath,
        string arguments,
        string workingDirectory,
        string description,
        string executablePath)
    {
        dynamic shell = shellObject;
        dynamic shortcut = shell.CreateShortcut(shortcutPath);
        shortcut.TargetPath = targetPath;
        shortcut.Arguments = arguments;
        shortcut.WorkingDirectory = workingDirectory;
        shortcut.Description = description;
        if (!string.IsNullOrWhiteSpace(executablePath) && File.Exists(executablePath))
        {
            shortcut.IconLocation = executablePath + ",0";
        }
        shortcut.Save();
    }
}
