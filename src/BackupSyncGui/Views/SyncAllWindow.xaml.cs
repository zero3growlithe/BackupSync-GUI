using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Windows;
using BackupSyncGui.Models;
using BackupSyncGui.Services;

namespace BackupSyncGui.Views;

/// <summary>
/// Runs one sync pass for every configuration, one at a time, and reports the result.
/// </summary>
public partial class SyncAllWindow : Window
{
    private readonly List<ConfigurationListItem> _items;

    private bool _stopRequested;

    public SyncAllWindow(IReadOnlyList<ConfigurationListItem> items)
    {
        InitializeComponent();
        _items = new List<ConfigurationListItem>(items);
        Loaded += SyncAllWindow_Loaded;
    }

    public int CompletedCount { get; private set; }

    public int FailedCount { get; private set; }

    public int SkippedCount { get; private set; }

    private async void SyncAllWindow_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            string powerShellFolder = App.Instance.PowerShellFolder;
            for (int index = 0; index < _items.Count; index++)
            {
                ConfigurationListItem item = _items[index];

                if (_stopRequested)
                {
                    SkippedCount += _items.Count - index;
                    AddResult("Stopped by request; " + (_items.Count - index) + " configuration(s) not synced.");
                    break;
                }
                if (!item.CanSync)
                {
                    SkippedCount++;
                    AddResult("Skipped " + item.DisplayName + " — " + (item.ErrorMessage ?? "not configured."));
                    continue;
                }

                ProgressTextBlock.Text = "Syncing " + (index + 1) + " of " + _items.Count + ": " + item.DisplayName;
                AddResult("→ " + item.DisplayName + "  (" + item.DestinationPath + ")");
                try
                {
                    using Process? process = BackupSyncProcessRunner.RunSyncOnly(powerShellFolder, item.SourcePath);
                    if (process is null)
                    {
                        FailedCount++;
                        AddResult("   could not start Windows PowerShell");
                        continue;
                    }
                    await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(true);
                    if (process.ExitCode == 0)
                    {
                        CompletedCount++;
                        AddResult("   finished");
                    }
                    else
                    {
                        FailedCount++;
                        AddResult("   failed with exit code " + process.ExitCode);
                    }
                }
                catch (Exception exception)
                {
                    CrashLog.Write(exception);
                    FailedCount++;
                    AddResult("   failed: " + exception.Message);
                }
            }

            ProgressTextBlock.Text = "Done: " + CompletedCount + " synced, " + FailedCount + " failed, " + SkippedCount + " skipped.";
            StopButton.IsEnabled = false;
            CloseButton.IsEnabled = true;
            CloseButton.Focus();
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            ProgressTextBlock.Text = "The batch stopped: " + exception.Message;
            StopButton.IsEnabled = false;
            CloseButton.IsEnabled = true;
        }
    }

    private void Stop_Click(object sender, RoutedEventArgs e)
    {
        _stopRequested = true;
        StopButton.IsEnabled = false;
        ProgressTextBlock.Text = "Stopping after the current configuration…";
    }

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void AddResult(string message)
    {
        ResultsListBox.Items.Add(message);
        if (ResultsListBox.Items.Count > 0)
        {
            ResultsListBox.ScrollIntoView(ResultsListBox.Items[ResultsListBox.Items.Count - 1]);
        }
    }
}
