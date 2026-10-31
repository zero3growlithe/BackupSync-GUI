using System;
using System.IO;
using System.Text.Json;

namespace BackupSyncGui.Services;

internal sealed class AppSettings
{
    public int Version { get; set; } = 1;

    public string? PowerShellFolder { get; set; }
}

/// <summary>
/// Per-user application settings kept beside the configuration registry.
/// </summary>
internal sealed class AppSettingsService
{
    private readonly string _filePath;

    public AppSettings Settings { get; private set; }

    public AppSettingsService()
    {
        Directory.CreateDirectory(ApplicationPaths.DataDirectory);
        _filePath = Path.Combine(ApplicationPaths.DataDirectory, "settings.json");
        Settings = Load();
    }

    public void SetPowerShellFolder(string folder)
    {
        Settings.PowerShellFolder = folder;
        Save();
    }

    private AppSettings Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return new AppSettings();
            }
            string json = File.ReadAllText(_filePath);
            AppSettings? parsed = JsonSerializer.Deserialize<AppSettings>(json);
            return parsed ?? new AppSettings();
        }
        catch (Exception)
        {
            // A corrupt settings file must never block startup; defaults are safe.
            return new AppSettings();
        }
    }

    private void Save()
    {
        JsonSerializerOptions options = new JsonSerializerOptions { WriteIndented = true };
        File.WriteAllText(_filePath, JsonSerializer.Serialize(Settings, options));
    }
}

internal static class ApplicationPaths
{
    public static string DataDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "BackupSyncGui");
}
