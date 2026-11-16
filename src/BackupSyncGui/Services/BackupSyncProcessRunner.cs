using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace BackupSyncGui.Services;

internal enum InitializationConflictPolicy
{
    Destination,
    Source,
    Abort,
}

internal sealed class InitializationResult
{
    public int ExitCode { get; init; }

    public string Output { get; init; } = string.Empty;

    public bool Succeeded => ExitCode == 0;
}

/// <summary>
/// Starts the PowerShell utility. Sync runs are deliberately not redirected:
/// the engine asks questions on conflict, so it needs a real console window.
/// </summary>
internal static class BackupSyncProcessRunner
{
    public static string PowerShellExecutablePath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.System),
        "WindowsPowerShell",
        "v1.0",
        "powershell.exe");

    public static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    public static Process StartPowerShellScript(string scriptPath, string extraArguments)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("The PowerShell script was not found: " + scriptPath, scriptPath);
        }
        StringBuilder arguments = new StringBuilder();
        arguments.Append("-NoProfile -ExecutionPolicy Bypass -File ");
        arguments.Append(Quote(scriptPath));
        if (!string.IsNullOrWhiteSpace(extraArguments))
        {
            arguments.Append(' ');
            arguments.Append(extraArguments);
        }
        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = PowerShellExecutablePath,
            Arguments = arguments.ToString(),
            UseShellExecute = true,
            WorkingDirectory = Path.GetDirectoryName(scriptPath) ?? string.Empty,
        };
        return Process.Start(startInfo)
               ?? throw new InvalidOperationException("Windows PowerShell could not be started.");
    }

    /// <summary>Mirrors the "Sync only" shortcut: sync without launching the application.</summary>
    public static Process RunSyncOnly(string powerShellFolder, string sourceFolder)
    {
        string startScript = ScriptLocator.GetScriptPath(powerShellFolder, ScriptLocator.StartScriptFileName);
        return StartPowerShellScript(startScript, "-Source " + Quote(sourceFolder) + " -SyncOnly");
    }

    /// <summary>Mirrors the "Launcher" shortcut: pre-sync, launch, wait, post-sync.</summary>
    public static Process RunLauncher(string powerShellFolder, string sourceFolder)
    {
        string startScript = ScriptLocator.GetScriptPath(powerShellFolder, ScriptLocator.StartScriptFileName);
        return StartPowerShellScript(startScript, "-Source " + Quote(sourceFolder));
    }

    public static Process? StartShortcut(string shortcutPath)
    {
        if (!File.Exists(shortcutPath))
        {
            return null;
        }
        return Process.Start(new ProcessStartInfo
        {
            FileName = shortcutPath,
            UseShellExecute = true,
            WorkingDirectory = Path.GetDirectoryName(shortcutPath) ?? string.Empty,
        });
    }

    /// <summary>
    /// Runs New-SyncCopy.ps1. Unlike a sync, the copy answers no questions, so its output is
    /// streamed into the window instead of a console.
    /// </summary>
    public static async Task<InitializationResult> RunSyncCopyAsync(
        string powerShellFolder,
        string sourceFolder,
        string destinationFolder,
        bool copyEverything,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        string scriptPath = ScriptLocator.GetScriptPath(powerShellFolder, ScriptLocator.CopyScriptFileName);
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptPath) +
                           " -Source " + Quote(sourceFolder) +
                           " -Destination " + Quote(destinationFolder);
        if (copyEverything)
        {
            arguments += " -CopyAll";
        }

        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = PowerShellExecutablePath,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = powerShellFolder,
        };

        StringBuilder output = new StringBuilder();
        using Process process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        bool wasCancelled = false;

        void Collect(object sender, DataReceivedEventArgs args)
        {
            if (args.Data is null)
            {
                return;
            }
            lock (output)
            {
                output.AppendLine(args.Data);
            }
            progress?.Report(args.Data);
        }

        process.OutputDataReceived += Collect;
        process.ErrorDataReceived += Collect;

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            process.WaitForExit();
        }
        catch (OperationCanceledException)
        {
            wasCancelled = true;
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(10000);
                }
            }
            catch (Exception)
            {
                // The process may have exited on its own between the check and the kill.
            }
        }

        string text;
        lock (output)
        {
            text = output.ToString();
        }
        if (wasCancelled)
        {
            text += Environment.NewLine + "The copy was stopped.";
            return new InitializationResult { ExitCode = -1, Output = text };
        }
        return new InitializationResult { ExitCode = process.ExitCode, Output = text };
    }

    public static async Task<InitializationResult> RunInitializationAsync(
        string powerShellFolder,
        string sourceFolder,
        string destinationFolder,
        InitializationConflictPolicy conflictPolicy,
        CancellationToken cancellationToken)
    {
        string scriptPath = ScriptLocator.GetScriptPath(powerShellFolder, ScriptLocator.InitializationScriptFileName);
        string policy = conflictPolicy switch
        {
            InitializationConflictPolicy.Destination => "Destination",
            InitializationConflictPolicy.Source => "Source",
            _ => "Abort",
        };
        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = PowerShellExecutablePath,
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptPath) +
                        " -Source " + Quote(sourceFolder) +
                        " -Destination " + Quote(destinationFolder) +
                        " -ConflictPolicy " + policy,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = powerShellFolder,
        };

        StringBuilder output = new StringBuilder();
        using Process process = new Process { StartInfo = startInfo };
        process.OutputDataReceived += (sender, args) =>
        {
            if (args.Data is not null)
            {
                lock (output)
                {
                    output.AppendLine(args.Data);
                }
            }
        };
        process.ErrorDataReceived += (sender, args) =>
        {
            if (args.Data is not null)
            {
                lock (output)
                {
                    output.AppendLine(args.Data);
                }
            }
        };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        process.WaitForExit();

        string text;
        lock (output)
        {
            text = output.ToString();
        }
        return new InitializationResult { ExitCode = process.ExitCode, Output = text };
    }
}
