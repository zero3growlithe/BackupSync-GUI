using System;
using System.IO;

namespace BackupSyncGui.Services;

/// <summary>
/// Finds the folder holding the BackupSync PowerShell scripts.
/// </summary>
internal static class ScriptLocator
{
    public const string EngineFileName = "BackupSync.ps1";

    public const string CommonFileName = "BackupSync.Common.ps1";

    public const string StartScriptFileName = "Start-BackupSync.ps1";

    public const string SetupScriptFileName = "Setup-BackupSync.ps1";

    public const string InitializationScriptFileName = "Initialize-BackupSync.ps1";

    public static bool IsValidFolder(string? folder)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Directory.Exists(folder))
        {
            return false;
        }
        string[] required = { EngineFileName, CommonFileName, StartScriptFileName };
        foreach (string name in required)
        {
            if (!File.Exists(Path.Combine(folder, name)))
            {
                return false;
            }
        }
        return true;
    }

    public static string? ResolveFolder(string? configuredFolder)
    {
        if (IsValidFolder(configuredFolder))
        {
            return Path.GetFullPath(configuredFolder!);
        }
        return FindDefaultCandidate();
    }

    /// <summary>Look for the shipped "PowerShell" payload beside the executable first.</summary>
    public static string? FindDefaultCandidate()
    {
        string baseDirectory = AppContext.BaseDirectory;
        string[] candidates =
        {
            Path.Combine(baseDirectory, "PowerShell"),
            baseDirectory,
            Path.Combine(baseDirectory, "..", "PowerShell"),
            Path.Combine(baseDirectory, ".."),
            Path.Combine(baseDirectory, "..", ".."),
        };
        foreach (string candidate in candidates)
        {
            if (IsValidFolder(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }
        return null;
    }

    public static string GetScriptPath(string folder, string fileName)
    {
        return Path.Combine(folder, fileName);
    }
}
