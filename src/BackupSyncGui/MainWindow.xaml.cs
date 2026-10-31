using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using BackupSyncGui.Models;
using BackupSyncGui.Services;
using BackupSyncGui.Views;

namespace BackupSyncGui;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<ConfigurationListItem> _items = new ObservableCollection<ConfigurationListItem>();

    public MainWindow()
    {
        InitializeComponent();
        ConfigurationsListBox.ItemsSource = _items;
        Title = "BackupSync — build " + BuildInfo.ShortSha;
        Loaded += MainWindow_Loaded;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        await RefreshAsync();
    }

    // ── Loading ────────────────────────────────────────────────────────────

    private async Task RefreshAsync()
    {
        string? previousSelection = (ConfigurationsListBox.SelectedItem as ConfigurationListItem)?.SourcePath;
        List<string> sources = new List<string>(App.Instance.Registry.SourcePaths);

        List<ConfigurationListItem> loaded = await Task.Run(() =>
        {
            List<ConfigurationListItem> result = new List<ConfigurationListItem>();
            foreach (string source in sources)
            {
                result.Add(ConfigurationListItem.Load(source));
            }
            result.Sort((left, right) => string.Compare(left.DisplayName, right.DisplayName, StringComparison.OrdinalIgnoreCase));
            return result;
        });

        _items.Clear();
        foreach (ConfigurationListItem item in loaded)
        {
            _items.Add(item);
        }

        EmptyStatePanel.Visibility = _items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        HeaderSummaryTextBlock.Text = DescribeCounts();
        StatusFooterTextBlock.Text = "Scripts: " + App.Instance.PowerShellFolder + "   •   F5 refreshes the list";

        if (previousSelection is not null)
        {
            ConfigurationListItem? match = _items.FirstOrDefault(
                item => string.Equals(item.SourcePath, previousSelection, StringComparison.OrdinalIgnoreCase));
            if (match is not null)
            {
                ConfigurationsListBox.SelectedItem = match;
                UpdateDetails();
                return;
            }
        }

        if (_items.Count > 0 && ConfigurationsListBox.SelectedItem is null)
        {
            ConfigurationsListBox.SelectedIndex = 0;
        }
        UpdateDetails();
    }

    private string DescribeCounts()
    {
        if (_items.Count == 0)
        {
            return "No configurations";
        }
        int unavailable = _items.Count(item => !item.IsValid);
        string text = _items.Count == 1 ? "1 configuration" : _items.Count + " configurations";
        if (unavailable > 0)
        {
            text += "  •  " + unavailable + " needing attention";
        }
        return text;
    }

    private void UpdateDetails()
    {
        ConfigurationListItem? item = ConfigurationsListBox.SelectedItem as ConfigurationListItem;
        bool hasSelection = item is not null;
        DetailsPanel.Visibility = hasSelection ? Visibility.Visible : Visibility.Collapsed;
        DetailsEmptyTextBlock.Visibility = hasSelection ? Visibility.Collapsed : Visibility.Visible;

        if (item is null)
        {
            return;
        }

        DetailIconImage.Source = item.Icon;
        DetailNameTextBlock.Text = item.DisplayName;
        DetailStatusTextBlock.Text = item.StatusText;
        DetailStatusTextBlock.Foreground = item.IsStatusWarning
            ? (Brush)FindResource("DangerBrush")
            : (Brush)FindResource("TextMutedBrush");
        DetailSourceTextBlock.Text = item.SourcePath;
        DetailDestinationTextBlock.Text = string.IsNullOrWhiteSpace(item.DestinationPath) ? "—" : item.DestinationPath;
        DetailApplicationTextBlock.Text = item.ExecutableDisplayName + "  •  " + item.DelaySeconds + " s delay";
        DetailRulesTextBlock.Text = item.SelectionRuleCount == 0
            ? "All files (no selection rules)"
            : item.SelectionRuleCount + " selection rule(s) in " + ConfigurationFileService.FileName;

        DetailConfigurationTextBlock.Text = item.ErrorMessage ?? string.Empty;
        DetailConfigurationTextBlock.Visibility = item.IsValid ? Visibility.Collapsed : Visibility.Visible;

        SyncSelectedButton.IsEnabled = item.CanSync;
        LaunchSelectedButton.IsEnabled = item.CanSync && !string.IsNullOrWhiteSpace(item.ExecutablePath);
        EditFiltersButton.IsEnabled = item.HasConfigurationFile;
        OpenSourceButton.IsEnabled = Directory.Exists(item.SourcePath);
        OpenDestinationButton.IsEnabled = !string.IsNullOrWhiteSpace(item.DestinationPath) && Directory.Exists(item.DestinationPath);
    }

    // ── Selection ──────────────────────────────────────────────────────────

    private void ConfigurationsListBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateDetails();
    }

    private void ConfigurationsListBox_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && FindAncestor<ListBoxItem>(source) is null)
        {
            return;
        }
        ExecuteSelected();
    }

    private void ConfigurationsListBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            ExecuteSelected();
        }
    }

    /// <summary>F5 re-reads the registry and re-checks every folder, so drives that
    /// appeared or disappeared while the window was open are reflected at once.</summary>
    private async void MainWindow_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.F5)
        {
            return;
        }
        e.Handled = true;
        await RefreshAsync();
        StatusFooterTextBlock.Text = "Refreshed. " + DescribeCounts() + "   •   Scripts: " + App.Instance.PowerShellFolder;
    }

    /// <summary>
    /// Double click behaviour: run the generated launcher when it exists,
    /// otherwise just run the sync.
    /// </summary>
    private void ExecuteSelected()
    {
        ConfigurationListItem? item = ConfigurationsListBox.SelectedItem as ConfigurationListItem;
        if (item is null || !item.CanSync)
        {
            return;
        }
        try
        {
            if (item.HasLauncher)
            {
                BackupSyncProcessRunner.StartShortcut(item.LauncherPath);
                StatusFooterTextBlock.Text = "Started the launcher for " + item.DisplayName + ".";
                return;
            }
            BackupSyncProcessRunner.RunSyncOnly(App.Instance.PowerShellFolder, item.SourcePath);
            StatusFooterTextBlock.Text = "Started the sync for " + item.DisplayName + " (no launcher shortcut found).";
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            MessageBox.Show(this, exception.Message, "BackupSync", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    // ── Header actions ─────────────────────────────────────────────────────

    private async void AddConfiguration_Click(object sender, RoutedEventArgs e)
    {
        SetupWizardWindow wizard = new SetupWizardWindow { Owner = this };
        bool? result = wizard.ShowDialog();
        if (result == true && wizard.ConfigurationSaved)
        {
            await RefreshAsync();
            StatusFooterTextBlock.Text = "Configuration saved for " + wizard.SavedSourcePath + ".";
        }
    }

    private async void SyncAll_Click(object sender, RoutedEventArgs e)
    {
        if (_items.Count == 0)
        {
            MessageBox.Show(this, "There are no configurations to sync yet.", "BackupSync", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        SyncAllWindow window = new SyncAllWindow(_items.ToList()) { Owner = this };
        window.ShowDialog();
        await RefreshAsync();
    }

    // ── Details actions ────────────────────────────────────────────────────

    private void SyncSelected_Click(object sender, RoutedEventArgs e)
    {
        ExecuteSelected();
    }

    private void LaunchSelected_Click(object sender, RoutedEventArgs e)
    {
        ConfigurationListItem? item = ConfigurationsListBox.SelectedItem as ConfigurationListItem;
        if (item is null || !item.CanSync)
        {
            return;
        }
        try
        {
            if (item.HasLauncher)
            {
                BackupSyncProcessRunner.StartShortcut(item.LauncherPath);
            }
            else
            {
                BackupSyncProcessRunner.RunLauncher(App.Instance.PowerShellFolder, item.SourcePath);
            }
            StatusFooterTextBlock.Text = "Started the launcher for " + item.DisplayName + ".";
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            MessageBox.Show(this, exception.Message, "BackupSync", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OpenSource_Click(object sender, RoutedEventArgs e)
    {
        ConfigurationListItem? item = ConfigurationsListBox.SelectedItem as ConfigurationListItem;
        if (item is null)
        {
            return;
        }
        ShellInterop.OpenFolder(item.SourcePath);
    }

    private void OpenDestination_Click(object sender, RoutedEventArgs e)
    {
        ConfigurationListItem? item = ConfigurationsListBox.SelectedItem as ConfigurationListItem;
        if (item is null || string.IsNullOrWhiteSpace(item.DestinationPath))
        {
            return;
        }
        ShellInterop.OpenFolder(item.DestinationPath);
    }

    private async void EditFilters_Click(object sender, RoutedEventArgs e)
    {
        ConfigurationListItem? item = ConfigurationsListBox.SelectedItem as ConfigurationListItem;
        if (item is null || !item.HasConfigurationFile)
        {
            return;
        }

        try
        {
            BackupConfiguration configuration = ConfigurationFileService.Read(item.SourcePath);
            string rulesText = configuration.RuleLines.Count == 0
                ? ConfigurationFileService.DefaultRulesText
                : string.Join(Environment.NewLine, configuration.RuleLines);

            FilterEditorWindow window = new FilterEditorWindow { Owner = this };
            window.Initialize(item.DisplayName, rulesText);
            if (window.ShowDialog() != true)
            {
                return;
            }

            configuration.RuleLines = window.RuleLines;
            string engineScript = ScriptLocator.GetScriptPath(App.Instance.PowerShellFolder, ScriptLocator.EngineFileName);
            ConfigurationFileService.Write(item.SourcePath, configuration, engineScript);
            await RefreshAsync();
            StatusFooterTextBlock.Text = "Selection rules saved for " + item.DisplayName + ".";
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            MessageBox.Show(this, exception.Message, "BackupSync", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void RemoveSelected_Click(object sender, RoutedEventArgs e)
    {
        ConfigurationListItem? item = ConfigurationsListBox.SelectedItem as ConfigurationListItem;
        if (item is null)
        {
            return;
        }

        RemoveConfigurationWindow window = new RemoveConfigurationWindow { Owner = this };
        window.Initialize(item.DisplayName, item.SourcePath);
        if (window.ShowDialog() != true)
        {
            return;
        }

        try
        {
            if (window.DeleteShortcutFiles)
            {
                foreach (string file in ShortcutService.GetApplicationFiles(item.SourcePath))
                {
                    try
                    {
                        File.Delete(file);
                    }
                    catch (Exception exception)
                    {
                        CrashLog.Write(exception);
                    }
                }
            }
            if (window.DeleteConfigurationFile)
            {
                string configurationPath = ConfigurationFileService.GetPath(item.SourcePath);
                if (File.Exists(configurationPath))
                {
                    File.Delete(configurationPath);
                }
            }

            App.Instance.Registry.Remove(item.SourcePath);
            await RefreshAsync();
            StatusFooterTextBlock.Text = "Removed " + item.DisplayName + " from the list.";
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            MessageBox.Show(this, exception.Message, "BackupSync", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    // ── Footer ─────────────────────────────────────────────────────────────

    private async void ScriptsFolder_Click(object sender, RoutedEventArgs e)
    {
        string? selected = ShellInterop.BrowseForFolder(
            "Select the folder that contains the BackupSync PowerShell scripts",
            App.Instance.PowerShellFolder);
        if (selected is null)
        {
            return;
        }
        if (!ScriptLocator.IsValidFolder(selected))
        {
            MessageBox.Show(
                this,
                "That folder does not contain " + ScriptLocator.EngineFileName + ", " +
                ScriptLocator.CommonFileName + " and " + ScriptLocator.StartScriptFileName + ".",
                "BackupSync",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }
        App.Instance.UpdatePowerShellFolder(selected);
        await RefreshAsync();
        StatusFooterTextBlock.Text = "Scripts folder set to " + selected + ".";
    }

    // ── Visual tree helper ─────────────────────────────────────────────────

    private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
    {
        while (current is not null)
        {
            if (current is T match)
            {
                return match;
            }
            current = current is Visual || current is System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(current)
                : LogicalTreeHelper.GetParent(current);
        }
        return null;
    }
}
