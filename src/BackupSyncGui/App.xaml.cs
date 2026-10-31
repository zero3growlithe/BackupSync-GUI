using System;
using System.Windows;
using System.Windows.Threading;
using BackupSyncGui.Services;

namespace BackupSyncGui;

public partial class App : Application
{
    internal AppSettingsService SettingsService { get; private set; } = null!;

    internal ConfigurationRegistry Registry { get; private set; } = null!;

    public string PowerShellFolder { get; private set; } = string.Empty;

    public static App Instance => (App)Current;

    public void UpdatePowerShellFolder(string folder)
    {
        PowerShellFolder = folder;
        SettingsService.SetPowerShellFolder(folder);
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        ShutdownMode = ShutdownMode.OnMainWindowClose;

        try
        {
            SettingsService = new AppSettingsService();
            Registry = new ConfigurationRegistry();

            string? folder = ScriptLocator.ResolveFolder(SettingsService.Settings.PowerShellFolder);
            if (folder is null)
            {
                folder = PromptForPowerShellFolder();
                if (folder is null)
                {
                    Shutdown();
                    return;
                }
            }
            UpdatePowerShellFolder(folder);

            MainWindow window = new MainWindow();
            MainWindow = window;
            window.Show();
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "BackupSync could not start.\n\n" + exception.Message,
                "BackupSync",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown();
        }
    }

    private string? PromptForPowerShellFolder()
    {
        while (true)
        {
            MessageBoxResult answer = MessageBox.Show(
                "The BackupSync PowerShell scripts were not found next to this application.\n\n" +
                "Locate the folder that contains BackupSync.ps1, BackupSync.Common.ps1 and Start-BackupSync.ps1.",
                "BackupSync",
                MessageBoxButton.OKCancel,
                MessageBoxImage.Information);
            if (answer != MessageBoxResult.OK)
            {
                return null;
            }

            string? selected = ShellInterop.BrowseForFolder(
                "Select the folder that contains the BackupSync PowerShell scripts",
                ScriptLocator.FindDefaultCandidate());
            if (selected is null)
            {
                return null;
            }
            if (ScriptLocator.IsValidFolder(selected))
            {
                return selected;
            }
            MessageBox.Show(
                "That folder does not contain BackupSync.ps1, BackupSync.Common.ps1 and Start-BackupSync.ps1.",
                "BackupSync",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        CrashLog.Write(e.Exception);
        MessageBox.Show(
            "An unexpected error occurred.\n\n" + e.Exception.Message +
            "\n\nDetails were written to:\n" + CrashLog.FilePath,
            "BackupSync",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
    }
}
