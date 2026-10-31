using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using BackupSyncGui.Models;

namespace BackupSyncGui.Services;

/// <summary>
/// Reads and writes backup_setup.txt. The byte layout matches Setup-BackupSync.ps1:
/// UTF-8 with BOM, CRLF line endings, destination / executable / delay then rules.
/// </summary>
internal static class ConfigurationFileService
{
    public const string FileName = "backup_setup.txt";

    private const string DefaultRuleComment =
        "# Optional rules below: + includes, - excludes; no rules means all files.\r\n" +
        "# Example: +Saves\r\n" +
        "# Example: -**/cache/**\r\n" +
        "# Example: -*.zip";

    public static string DefaultRulesText => DefaultRuleComment.Replace("\r\n", "\n");

    public static string GetPath(string sourceFolder)
    {
        return Path.Combine(sourceFolder, FileName);
    }

    public static bool Exists(string sourceFolder)
    {
        return File.Exists(GetPath(sourceFolder));
    }

    public static string NormalizePath(string path)
    {
        return Path.GetFullPath(path).TrimEnd('\\', '/');
    }

    public static BackupConfiguration Read(string sourceFolder)
    {
        string[] lines = File.ReadAllLines(GetPath(sourceFolder));
        if (lines.Length == 0 || string.IsNullOrWhiteSpace(lines[0]))
        {
            throw new InvalidDataException("The first configuration line must be the destination folder.");
        }

        string rawDestination = lines[0].Trim().Trim('"');
        string expandedDestination = Environment.ExpandEnvironmentVariables(rawDestination);
        string absoluteDestination = Path.IsPathRooted(expandedDestination)
            ? expandedDestination
            : Path.Combine(sourceFolder, expandedDestination);

        BackupConfiguration configuration = new BackupConfiguration
        {
            SourcePath = sourceFolder,
            RawDestinationLine = rawDestination,
            DestinationPath = NormalizePath(absoluteDestination),
        };

        int index = 1;
        if (index < lines.Length && !IsPositionalBoundary(lines[index]))
        {
            configuration.ExecutableLine = lines[index].Trim().Trim('"');
            index++;
        }
        if (index < lines.Length && !IsPositionalBoundary(lines[index]))
        {
            string candidate = lines[index].Trim();
            if (!string.IsNullOrWhiteSpace(candidate))
            {
                if (!int.TryParse(candidate, NumberStyles.Integer, CultureInfo.InvariantCulture, out int delay) || delay < 0)
                {
                    throw new InvalidDataException("Delay must be a nonnegative integer.");
                }
                configuration.DelaySeconds = delay;
            }
            index++;
        }

        for (int i = index; i < lines.Length; i++)
        {
            string line = lines[i];
            if (line.TrimStart().StartsWith("# Script:", StringComparison.OrdinalIgnoreCase))
            {
                configuration.ScriptComment = line.Trim();
                continue;
            }
            configuration.RuleLines.Add(line);
        }
        while (configuration.RuleLines.Count > 0 &&
               string.IsNullOrWhiteSpace(configuration.RuleLines[configuration.RuleLines.Count - 1]))
        {
            configuration.RuleLines.RemoveAt(configuration.RuleLines.Count - 1);
        }

        if (configuration.HasExecutable)
        {
            string expandedExecutable = Environment.ExpandEnvironmentVariables(configuration.ExecutableLine);
            string absoluteExecutable = Path.IsPathRooted(expandedExecutable)
                ? expandedExecutable
                : Path.Combine(sourceFolder, expandedExecutable);
            configuration.ResolvedExecutablePath = NormalizePath(absoluteExecutable);
        }

        return configuration;
    }

    public static void Write(string sourceFolder, BackupConfiguration configuration, string engineScriptPath)
    {
        List<string> lines = new List<string>
        {
            configuration.RawDestinationLine,
            configuration.ExecutableLine,
            configuration.DelaySeconds.ToString(CultureInfo.InvariantCulture),
        };
        lines.AddRange(configuration.RuleLines);
        lines.Add("# Script: " + engineScriptPath);

        string text = string.Join("\r\n", lines) + "\r\n";
        File.WriteAllText(GetPath(sourceFolder), text, new UTF8Encoding(true));
    }

    /// <summary>Mirrors the wizard: keep a timestamped copy before overwriting.</summary>
    public static string? BackupExisting(string sourceFolder)
    {
        string path = GetPath(sourceFolder);
        if (!File.Exists(path))
        {
            return null;
        }
        string backupPath = path + "." + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + ".bak";
        File.Copy(path, backupPath, false);
        return backupPath;
    }

    public static int CountSelectionRules(IEnumerable<string> ruleLines)
    {
        int count = 0;
        foreach (string line in ruleLines)
        {
            string trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith("#", StringComparison.Ordinal))
            {
                continue;
            }
            count++;
        }
        return count;
    }

    /// <summary>
    /// Validates rule text exactly like SetSelectionRules in BackupSync.Common.ps1.
    /// </summary>
    public static bool TryParseRules(string text, out List<string> ruleLines, out string error)
    {
        ruleLines = new List<string>();
        error = string.Empty;

        string[] lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (int index = 0; index < lines.Length; index++)
        {
            string line = lines[index];
            string trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith("#", StringComparison.Ordinal))
            {
                ruleLines.Add(line.TrimEnd());
                continue;
            }
            if (!Regex.IsMatch(trimmed, "^[+-].+"))
            {
                error = "Line " + (index + 1) + ": a selection rule must start with + or -, or be a # comment: " + trimmed;
                return false;
            }
            string pattern = trimmed.Substring(1).Trim().Replace('\\', '/').TrimEnd('/');
            if (string.IsNullOrWhiteSpace(pattern))
            {
                error = "Line " + (index + 1) + ": the rule has no pattern after the sign.";
                return false;
            }
            if (pattern.StartsWith("/", StringComparison.Ordinal))
            {
                error = "Line " + (index + 1) + ": rules must be relative paths, not absolute.";
                return false;
            }
            if (pattern.Contains(':'))
            {
                error = "Line " + (index + 1) + ": rules cannot contain a drive or stream separator.";
                return false;
            }
            string[] segments = pattern.Split('/');
            foreach (string segment in segments)
            {
                if (segment == "..")
                {
                    error = "Line " + (index + 1) + ": rules cannot contain '..'.";
                    return false;
                }
            }
            ruleLines.Add(line.TrimEnd());
        }

        while (ruleLines.Count > 0 && string.IsNullOrWhiteSpace(ruleLines[ruleLines.Count - 1]))
        {
            ruleLines.RemoveAt(ruleLines.Count - 1);
        }
        return true;
    }

    private static bool IsPositionalBoundary(string line)
    {
        return Regex.IsMatch(line, "^\\s*[+-]");
    }
}
