using System;
using System.Collections.Generic;
using System.IO;
using BackupSyncGui.Services;

namespace BackupSyncGui.Models;

/// <summary>
/// Parsed representation of one source folder's backup_setup.txt.
/// </summary>
internal sealed class BackupConfiguration
{
    public string SourcePath { get; set; } = string.Empty;

    /// <summary>Destination exactly as written on line 1.</summary>
    public string RawDestinationLine { get; set; } = string.Empty;

    /// <summary>Destination with environment variables expanded and made absolute.</summary>
    public string DestinationPath { get; set; } = string.Empty;

    /// <summary>Executable exactly as written on line 2, empty for manual sync.</summary>
    public string ExecutableLine { get; set; } = string.Empty;

    /// <summary>Executable with environment variables expanded and made absolute.</summary>
    public string ResolvedExecutablePath { get; set; } = string.Empty;

    public int DelaySeconds { get; set; } = 10;

    /// <summary>Everything after the positional settings, minus the "# Script:" comment.</summary>
    public List<string> RuleLines { get; set; } = new List<string>();

    public string? ScriptComment { get; set; }

    public bool HasExecutable => !string.IsNullOrWhiteSpace(ExecutableLine);

    public string ExecutableDisplayName =>
        HasExecutable ? Path.GetFileName(ResolvedExecutablePath) : "Manual sync only";

    public int SelectionRuleCount => ConfigurationFileService.CountSelectionRules(RuleLines);
}
