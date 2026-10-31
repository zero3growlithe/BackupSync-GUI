using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using BackupSyncGui.Services;

namespace BackupSyncGui.Views;

/// <summary>
/// Asks what should happen to the files BackupSync left inside the source folder.
/// </summary>
public partial class RemoveConfigurationWindow : Window
{
    public RemoveConfigurationWindow()
    {
        InitializeComponent();
    }

    public bool DeleteShortcutFiles { get; private set; }

    public bool DeleteConfigurationFile { get; private set; }

    public void Initialize(string displayName, string sourcePath)
    {
        TitleTextBlock.Text = "Remove " + displayName + " from the list?";
        SourcePathTextBlock.Text = sourcePath;

        IReadOnlyList<string> applicationFiles = ShortcutService.GetApplicationFiles(sourcePath);
        if (applicationFiles.Count == 0)
        {
            ShortcutFilesCheckBox.IsEnabled = false;
            ShortcutFilesCheckBox.IsChecked = false;
            ShortcutFilesTextBlock.Text = "No files with \"backup-sync\" in their name were found in the source folder.";
        }
        else
        {
            ShortcutFilesCheckBox.IsChecked = true;
            List<string> names = new List<string>();
            foreach (string file in applicationFiles)
            {
                names.Add(Path.GetFileName(file));
            }
            ShortcutFilesTextBlock.Text = names.Count + " file(s): " + string.Join(", ", names);
        }

        bool configurationExists = ConfigurationFileService.Exists(sourcePath);
        ConfigurationFileCheckBox.IsEnabled = configurationExists;
        ConfigurationFileCheckBox.IsChecked = false;
        if (!configurationExists)
        {
            ConfigurationFileCheckBox.Content = "Also delete the configuration file (not present)";
        }
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        DeleteShortcutFiles = ShortcutFilesCheckBox.IsChecked == true;
        DeleteConfigurationFile = ConfigurationFileCheckBox.IsChecked == true;
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
