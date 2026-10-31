using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace BackupSyncGui.Services;

internal sealed class RegistryDocument
{
    public int Version { get; set; } = 1;

    public List<string> Sources { get; set; } = new List<string>();
}

/// <summary>
/// The list of configured backup pairs. BackupSync itself keeps its state inside
/// each source folder, so this registry only remembers which folders to show.
/// </summary>
internal sealed class ConfigurationRegistry
{
    private readonly string _filePath;

    private readonly List<string> _sourcePaths = new List<string>();

    public ConfigurationRegistry()
    {
        Directory.CreateDirectory(ApplicationPaths.DataDirectory);
        _filePath = Path.Combine(ApplicationPaths.DataDirectory, "configurations.json");
        Load();
    }

    public IReadOnlyList<string> SourcePaths => _sourcePaths;

    public bool Contains(string sourcePath)
    {
        string normalized = ConfigurationFileService.NormalizePath(sourcePath);
        return IndexOf(normalized) >= 0;
    }

    public bool Add(string sourcePath)
    {
        string normalized = ConfigurationFileService.NormalizePath(sourcePath);
        if (IndexOf(normalized) >= 0)
        {
            return false;
        }
        _sourcePaths.Add(normalized);
        Save();
        return true;
    }

    public bool Remove(string sourcePath)
    {
        string normalized = ConfigurationFileService.NormalizePath(sourcePath);
        int index = IndexOf(normalized);
        if (index < 0)
        {
            return false;
        }
        _sourcePaths.RemoveAt(index);
        Save();
        return true;
    }

    private int IndexOf(string normalizedPath)
    {
        for (int index = 0; index < _sourcePaths.Count; index++)
        {
            if (string.Equals(_sourcePaths[index], normalizedPath, StringComparison.OrdinalIgnoreCase))
            {
                return index;
            }
        }
        return -1;
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return;
            }
            RegistryDocument? document = JsonSerializer.Deserialize<RegistryDocument>(File.ReadAllText(_filePath));
            if (document?.Sources is null)
            {
                return;
            }
            foreach (string source in document.Sources)
            {
                if (!string.IsNullOrWhiteSpace(source) && IndexOf(source) < 0)
                {
                    _sourcePaths.Add(source);
                }
            }
        }
        catch (Exception)
        {
            // A damaged registry starts empty rather than blocking startup.
        }
    }

    private void Save()
    {
        RegistryDocument document = new RegistryDocument();
        document.Sources.AddRange(_sourcePaths);
        JsonSerializerOptions options = new JsonSerializerOptions { WriteIndented = true };
        File.WriteAllText(_filePath, JsonSerializer.Serialize(document, options));
    }
}
