using System;
using System.IO;
using System.Windows.Media;
using BackupSyncGui.Services;

namespace BackupSyncGui.Models;

/// <summary>
/// Immutable snapshot of one configured backup pair, built for the main list.
/// </summary>
public sealed class ConfigurationListItem
{
    public string SourcePath { get; init; } = string.Empty;

    public string DisplayName { get; init; } = string.Empty;

    public string DestinationPath { get; init; } = string.Empty;

    public string ExecutablePath { get; init; } = string.Empty;

    public string ExecutableDisplayName { get; init; } = "Manual sync only";

    public int DelaySeconds { get; init; } = 10;

    public int SelectionRuleCount { get; init; }

    public string LauncherPath { get; init; } = string.Empty;

    public bool HasLauncher { get; init; }

    public bool HasConfigurationFile { get; init; }

    public bool CanSync => HasConfigurationFile && IsValid;

    public bool IsValid => string.IsNullOrEmpty(ErrorMessage);

    public string? ErrorMessage { get; init; }

    public string StatusText { get; init; } = string.Empty;

    public bool IsStatusWarning { get; init; }

    public ImageSource? Icon { get; init; }

    public string DetailsText
    {
        get
        {
            string rules = SelectionRuleCount == 0 ? "all files" : SelectionRuleCount + " rule(s)";
            return ExecutableDisplayName + "   •   " + DelaySeconds + " s   •   " + rules;
        }
    }

    public static ConfigurationListItem Load(string sourcePath)
    {
        string displayName;
        try
        {
            displayName = new DirectoryInfo(sourcePath).Name;
        }
        catch (Exception)
        {
            displayName = sourcePath;
        }
        if (string.IsNullOrWhiteSpace(displayName))
        {
            displayName = sourcePath;
        }

        string launcherPath = ShortcutService.GetLauncherPath(sourcePath);
        bool hasLauncher = File.Exists(launcherPath);

        bool sourceExists = Directory.Exists(sourcePath);
        bool hasConfiguration = ConfigurationFileService.Exists(sourcePath);

        if (!sourceExists)
        {
            return new ConfigurationListItem
            {
                SourcePath = sourcePath,
                DisplayName = displayName,
                LauncherPath = launcherPath,
                HasLauncher = hasLauncher,
                HasConfigurationFile = hasConfiguration,
                ErrorMessage = "The source folder is not available.",
                StatusText = "Source folder not found",
                IsStatusWarning = true,
                Icon = ShellInterop.LoadShellIcon(null) ?? ShellInterop.LoadShellIcon(Environment.SystemDirectory),
            };
        }

        if (!hasConfiguration)
        {
            return new ConfigurationListItem
            {
                SourcePath = sourcePath,
                DisplayName = displayName,
                LauncherPath = launcherPath,
                HasLauncher = hasLauncher,
                HasConfigurationFile = false,
                ErrorMessage = "backup_setup.txt is missing from the source folder.",
                StatusText = "Configuration missing",
                IsStatusWarning = true,
                Icon = ShellInterop.LoadShellIcon(sourcePath),
            };
        }

        try
        {
            BackupConfiguration configuration = ConfigurationFileService.Read(sourcePath);
            string iconPath = sourcePath;
            if (configuration.HasExecutable && File.Exists(configuration.ResolvedExecutablePath))
            {
                iconPath = configuration.ResolvedExecutablePath;
            }
            else if (hasLauncher)
            {
                iconPath = launcherPath;
            }

            bool destinationExists = Directory.Exists(configuration.DestinationPath);
            return new ConfigurationListItem
            {
                SourcePath = sourcePath,
                DisplayName = displayName,
                DestinationPath = configuration.DestinationPath,
                ExecutablePath = configuration.ResolvedExecutablePath,
                ExecutableDisplayName = configuration.ExecutableDisplayName,
                DelaySeconds = configuration.DelaySeconds,
                SelectionRuleCount = configuration.SelectionRuleCount,
                LauncherPath = launcherPath,
                HasLauncher = hasLauncher,
                HasConfigurationFile = true,
                StatusText = destinationExists ? "Ready" : "Destination not available",
                IsStatusWarning = !destinationExists,
                Icon = ShellInterop.LoadShellIcon(iconPath),
            };
        }
        catch (Exception exception)
        {
            return new ConfigurationListItem
            {
                SourcePath = sourcePath,
                DisplayName = displayName,
                LauncherPath = launcherPath,
                HasLauncher = hasLauncher,
                HasConfigurationFile = true,
                ErrorMessage = exception.Message,
                StatusText = "Configuration is invalid",
                IsStatusWarning = true,
                Icon = ShellInterop.LoadShellIcon(sourcePath),
            };
        }
    }
}
