using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace BackupSyncGui.Services;

/// <summary>
/// The parsed contents of create_copy_setup.txt: the rules that decide what the first copy carries,
/// plus the optional block that becomes the pair's backup_setup.txt.
/// </summary>
internal sealed class SyncCopySetup
{
    /// <summary>Every line outside the template block, comments included.</summary>
    public List<string> RuleLines { get; } = new List<string>();

    /// <summary>The template body, without its marker lines.</summary>
    public List<string> TemplateLines { get; } = new List<string>();

    public bool HasTemplate { get; set; }

    /// <summary>Rules starting with '$': the destination gets a link instead of a copy.</summary>
    public int LinkRuleCount
    {
        get
        {
            int count = 0;
            foreach (string line in RuleLines)
            {
                string trimmed = line.Trim();
                if (trimmed.StartsWith("$", StringComparison.Ordinal) && trimmed.Length > 1)
                {
                    count++;
                }
            }
            return count;
        }
    }

    public int SelectionRuleCount
    {
        get
        {
            int count = 0;
            foreach (string line in RuleLines)
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
    }
}

/// <summary>
/// Reads and writes create_copy_setup.txt. The syntax is the one New-SyncCopy.ps1 understands:
/// the same +/- rules as backup_setup.txt, '$' rules that link instead of copy, and a template
/// block between "# backup_setup.txt template" and "# end backup_setup.txt".
/// </summary>
internal static class SyncCopySetupFile
{
    public const string FileName = "create_copy_setup.txt";

    public const string TemplateStartMarker = "# backup_setup.txt template";

    public const string TemplateEndMarker = "# end backup_setup.txt";

    private static readonly Regex TemplateStartRegex = new Regex(
        "^\\s*#\\s*-*\\s*(backup_setup|backup_sync)(\\.txt)?\\s*(template)?\\s*-*\\s*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex TemplateEndRegex = new Regex(
        "^\\s*#\\s*-*\\s*end\\s+(backup_setup|backup_sync)(\\.txt)?\\s*-*\\s*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string GetPath(string sourceFolder)
    {
        return Path.Combine(sourceFolder, FileName);
    }

    public static bool Exists(string sourceFolder)
    {
        return File.Exists(GetPath(sourceFolder));
    }

    public static string ReadText(string sourceFolder)
    {
        string path = GetPath(sourceFolder);
        if (!File.Exists(path))
        {
            return string.Empty;
        }
        return File.ReadAllText(path).Replace("\r\n", "\n").Replace('\r', '\n');
    }

    /// <summary>Written back exactly as edited, so the script reads the text the user approved.</summary>
    public static void WriteText(string sourceFolder, string text)
    {
        string normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        string[] lines = normalized.Split('\n');
        string output = string.Join("\r\n", lines);
        File.WriteAllText(GetPath(sourceFolder), output, new UTF8Encoding(false));
    }

    /// <summary>
    /// Validates the text the way New-SyncCopy.ps1 splits it, so problems surface in the editor and
    /// not halfway through a copy.
    /// </summary>
    public static bool TryParse(string? text, out SyncCopySetup setup, out string error)
    {
        setup = new SyncCopySetup();
        error = string.Empty;

        string normalized = (text ?? string.Empty).Replace("\r\n", "\n").Replace('\r', '\n');
        string[] lines = normalized.Split('\n');
        bool inTemplate = false;
        int templateStartLine = 0;

        for (int index = 0; index < lines.Length; index++)
        {
            string line = lines[index];
            int lineNumber = index + 1;

            if (inTemplate)
            {
                if (TemplateEndRegex.IsMatch(line))
                {
                    inTemplate = false;
                    continue;
                }
                if (TemplateStartRegex.IsMatch(line))
                {
                    error = "Line " + lineNumber + ": the template block that starts on line " + templateStartLine +
                            " was never closed with \"" + TemplateEndMarker + "\".";
                    return false;
                }
                setup.TemplateLines.Add(line.TrimEnd());
                continue;
            }

            if (TemplateEndRegex.IsMatch(line))
            {
                error = "Line " + lineNumber + ": \"" + TemplateEndMarker + "\" appears without a template block above it.";
                return false;
            }
            if (TemplateStartRegex.IsMatch(line))
            {
                inTemplate = true;
                setup.HasTemplate = true;
                templateStartLine = lineNumber;
                continue;
            }

            string trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith("#", StringComparison.Ordinal))
            {
                setup.RuleLines.Add(line.TrimEnd());
                continue;
            }
            if (!Regex.IsMatch(trimmed, "^[+\\-$].+"))
            {
                error = "Line " + lineNumber + ": a rule must start with +, - or $ (for a link), or be a # comment: " + trimmed;
                return false;
            }

            string pattern = trimmed.Substring(1).Trim().Replace('\\', '/').TrimEnd('/');
            if (string.IsNullOrWhiteSpace(pattern))
            {
                error = "Line " + lineNumber + ": the rule has no pattern after the sign.";
                return false;
            }
            if (pattern.StartsWith("/", StringComparison.Ordinal))
            {
                error = "Line " + lineNumber + ": rules must be relative paths, not absolute.";
                return false;
            }
            if (pattern.Length >= 2 && char.IsLetter(pattern[0]) && pattern[1] == ':')
            {
                error = "Line " + lineNumber + ": rules cannot start with a drive letter.";
                return false;
            }
            foreach (string segment in pattern.Split('/'))
            {
                if (segment == "..")
                {
                    error = "Line " + lineNumber + ": rules cannot contain '..'.";
                    return false;
                }
            }
            setup.RuleLines.Add(line.TrimEnd());
        }

        if (inTemplate)
        {
            error = "The template block that starts on line " + templateStartLine + " was never closed with \"" +
                    TemplateEndMarker + "\".";
            return false;
        }

        while (setup.RuleLines.Count > 0 && string.IsNullOrWhiteSpace(setup.RuleLines[setup.RuleLines.Count - 1]))
        {
            setup.RuleLines.RemoveAt(setup.RuleLines.Count - 1);
        }
        while (setup.TemplateLines.Count > 0 && string.IsNullOrWhiteSpace(setup.TemplateLines[setup.TemplateLines.Count - 1]))
        {
            setup.TemplateLines.RemoveAt(setup.TemplateLines.Count - 1);
        }
        return true;
    }
}
