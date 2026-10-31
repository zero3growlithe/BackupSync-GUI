using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using BackupSyncGui.Models;
using BackupSyncGui.Services;

namespace BackupSyncGui.Views;

public sealed class ExecutableOption
{
    public string Display { get; init; } = string.Empty;

    public string FullPath { get; init; } = string.Empty;

    public ImageSource? Icon { get; init; }
}

/// <summary>
/// The configuration wizard. It asks the same questions as Setup-BackupSync.ps1
/// and produces the same backup_setup.txt and three shortcuts, but collects the
/// selection rules in an editor before anything is written.
/// </summary>
public partial class SetupWizardWindow : Window
{
    private const int StepCount = 5;

    private const string InitializationFileName = "backup_init.txt";

    private const string VersionFileName = "backup_version.txt";

    private static readonly string[] StepTitles =
    {
        "Source folder",
        "Destination folder",
        "Application to launch",
        "Delay before synchronizing",
        "Selection rules",
    };

    private static readonly string[] StepSubtitles =
    {
        "Pick the folder whose files you want to keep in sync across computers.",
        "Pick the folder that receives the copy. One destination serves one logical set of files.",
        "The launcher starts this application between the two sync passes. Manual sync skips launching.",
        "How long to wait after the application closes before the second sync starts.",
        "Optionally restrict which files take part in the sync.",
    };

    private readonly ObservableCollection<ExecutableOption> _executableOptions = new ObservableCollection<ExecutableOption>();

    private int _step;

    private string _sourcePath = string.Empty;

    private string _destinationPath = string.Empty;

    private string _executableLine = string.Empty;

    private string _executableFullPath = string.Empty;

    private int _delaySeconds = 10;

    private bool _reconfigureExisting;

    public SetupWizardWindow()
    {
        InitializeComponent();
        ExecutableListBox.ItemsSource = _executableOptions;
        ConflictPolicyListBox.SelectedIndex = 0;
        RulesEditorControl.SaveRequested += RulesEditorControl_SaveRequested;
        GoToStep(0);
    }

    /// <summary>True when the wizard wrote or registered a configuration.</summary>
    public bool ConfigurationSaved { get; private set; }

    public string SavedSourcePath => _sourcePath;

    // ── Navigation ────────────────────────────────────────────────────────

    private void GoToStep(int step)
    {
        _step = step;
        SourceStepPanel.Visibility = step == 0 ? Visibility.Visible : Visibility.Collapsed;
        DestinationStepPanel.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        ExecutableStepPanel.Visibility = step == 2 ? Visibility.Visible : Visibility.Collapsed;
        DelayStepPanel.Visibility = step == 3 ? Visibility.Visible : Visibility.Collapsed;
        FiltersStepPanel.Visibility = step == 4 ? Visibility.Visible : Visibility.Collapsed;

        StepTitleTextBlock.Text = StepTitles[step];
        StepSubtitleTextBlock.Text = StepSubtitles[step];
        StepCounterTextBlock.Text = "Step " + (step + 1) + " of " + StepCount;
        BackButton.IsEnabled = step > 0;
        NextButton.Content = step == StepCount - 1 ? "Save configuration" : "Next";
        ClearMessage();

        if (step == 0)
        {
            SourcePathTextBox.Focus();
            SourcePathTextBox.CaretIndex = SourcePathTextBox.Text.Length;
        }
        else if (step == 2)
        {
            LoadExecutablesAsync();
        }
        else if (step == 3)
        {
            if (string.IsNullOrWhiteSpace(DelayTextBox.Text))
            {
                DelayTextBox.Text = "10";
            }
            DelayTextBox.Focus();
            DelayTextBox.SelectAll();
        }
        else if (step == 4)
        {
            if (string.IsNullOrWhiteSpace(RulesEditorControl.RulesText))
            {
                RulesEditorControl.RulesText = ConfigurationFileService.DefaultRulesText;
            }
            RulesEditorControl.FocusEditor();
        }
    }

    private async void Next_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            switch (_step)
            {
                case 0:
                    if (!AdvanceFromSource())
                    {
                        return;
                    }
                    GoToStep(1);
                    return;

                case 1:
                    if (!AdvanceFromDestination())
                    {
                        return;
                    }
                    if (InitializeCheckBox.Visibility == Visibility.Visible && InitializeCheckBox.IsChecked == true)
                    {
                        if (!await RunInitializationAsync().ConfigureAwait(true))
                        {
                            return;
                        }
                    }
                    GoToStep(2);
                    return;

                case 2:
                    AdvanceFromExecutable();
                    GoToStep(3);
                    return;

                case 3:
                    if (!AdvanceFromDelay())
                    {
                        return;
                    }
                    GoToStep(4);
                    return;

                default:
                    AttemptFinish();
                    return;
            }
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            ShowMessage(exception.Message);
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (_step > 0)
        {
            GoToStep(_step - 1);
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void RulesEditorControl_SaveRequested(object? sender, EventArgs e)
    {
        if (_step == StepCount - 1)
        {
            AttemptFinish();
        }
    }

    // ── Step 1: source ─────────────────────────────────────────────────────

    private void BrowseSource_Click(object sender, RoutedEventArgs e)
    {
        string? selected = ShellInterop.BrowseForFolder(
            "Select the SOURCE folder to synchronize",
            SourcePathTextBox.Text);
        if (selected is not null)
        {
            SourcePathTextBox.Text = selected;
            SourceInfoTextBlock.Text = string.Empty;
        }
    }

    private bool AdvanceFromSource()
    {
        string candidate = (SourcePathTextBox.Text ?? string.Empty).Trim().Trim('"');
        if (candidate.Length == 0)
        {
            ShowMessage("Choose the source folder first.");
            return false;
        }
        if (!Directory.Exists(candidate))
        {
            ShowMessage("That folder does not exist: " + candidate);
            return false;
        }
        string source = ConfigurationFileService.NormalizePath(candidate);
        if (IsDriveRoot(source))
        {
            ShowMessage("Choose a dedicated folder, not a drive or share root.");
            return false;
        }
        _sourcePath = source;
        SourcePathTextBox.Text = source;

        if (!ConfigurationFileService.Exists(source))
        {
            SourceInfoTextBlock.Text = "A new configuration will be created in " + source + ".";
            return true;
        }

        MessageBoxResult answer = MessageBox.Show(
            this,
            "A BackupSync configuration already exists in this folder:\n\n" + ConfigurationFileService.GetPath(source) +
            "\n\nYes — add the existing configuration to the list and change nothing.\n" +
            "No — configure it again and overwrite the existing configuration file.\n" +
            "Cancel — leave everything as it is.",
            "Configuration already exists",
            MessageBoxButton.YesNoCancel,
            MessageBoxImage.Question,
            MessageBoxResult.Cancel);

        if (answer == MessageBoxResult.Cancel)
        {
            return false;
        }
        if (answer == MessageBoxResult.Yes)
        {
            App.Instance.Registry.Add(source);
            ConfigurationSaved = true;
            DialogResult = true;
            return false;
        }

        _reconfigureExisting = true;
        SourceInfoTextBlock.Text =
            "The existing configuration will be backed up as\n" +
            ConfigurationFileService.GetPath(source) + ".<timestamp>.bak\nand then overwritten.";
        return true;
    }

    // ── Step 2: destination ────────────────────────────────────────────────

    private void BrowseDestination_Click(object sender, RoutedEventArgs e)
    {
        string? selected = ShellInterop.BrowseForFolder(
            "Select a dedicated DESTINATION folder (its files take part in two-way sync)",
            DestinationPathTextBox.Text);
        if (selected is null)
        {
            return;
        }
        DestinationPathTextBox.Text = selected;
        UpdateInitializationAvailability();
    }

    private void DestinationPathTextBox_LostFocus(object sender, RoutedEventArgs e)
    {
        UpdateInitializationAvailability();
    }

    private void InitializeCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (ConflictPolicyPanel is null || InitializeCheckBox is null)
        {
            return;
        }
        ConflictPolicyPanel.Visibility = InitializeCheckBox.IsChecked == true
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    /// <summary>
    /// Mirrors the wizard's opt-in initialization prompt: it only applies when the
    /// destination carries backup_init.txt and the source has no version baseline.
    /// </summary>
    private void UpdateInitializationAvailability()
    {
        bool available = false;
        string candidate = (DestinationPathTextBox.Text ?? string.Empty).Trim().Trim('"');
        if (candidate.Length > 0 && _sourcePath.Length > 0 && Directory.Exists(candidate))
        {
            try
            {
                string destination = ConfigurationFileService.NormalizePath(candidate);
                available = File.Exists(Path.Combine(destination, InitializationFileName)) &&
                            !File.Exists(Path.Combine(_sourcePath, VersionFileName));
            }
            catch (Exception)
            {
                available = false;
            }
        }

        InitializeCheckBox.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
        if (!available)
        {
            InitializeCheckBox.IsChecked = false;
            ConflictPolicyPanel.Visibility = Visibility.Collapsed;
        }
        DestinationInfoTextBlock.Text = available
            ? "The destination contains " + InitializationFileName + " and the source has no " + VersionFileName +
              " yet, so the source can be filled with matching files from the destination before the first sync. " +
              "Nothing is deleted; differing files are decided by the policy below."
            : string.Empty;
    }

    private bool AdvanceFromDestination()
    {
        string candidate = (DestinationPathTextBox.Text ?? string.Empty).Trim().Trim('"');
        if (candidate.Length == 0)
        {
            ShowMessage("Choose the destination folder first.");
            return false;
        }
        if (!Directory.Exists(candidate))
        {
            ShowMessage("That folder does not exist. Create it first, then choose it:\n" + candidate);
            return false;
        }
        string destination = ConfigurationFileService.NormalizePath(candidate);
        if (IsDriveRoot(destination))
        {
            ShowMessage("Choose a dedicated folder, not a drive or share root.");
            return false;
        }
        if (string.Equals(_sourcePath, destination, StringComparison.OrdinalIgnoreCase) ||
            _sourcePath.StartsWith(destination + "\\", StringComparison.OrdinalIgnoreCase) ||
            destination.StartsWith(_sourcePath + "\\", StringComparison.OrdinalIgnoreCase))
        {
            ShowMessage("Source and destination must be separate, non-nested folders.");
            return false;
        }
        _destinationPath = destination;
        DestinationPathTextBox.Text = destination;
        UpdateInitializationAvailability();
        return true;
    }

    private async Task<bool> RunInitializationAsync()
    {
        InitializationConflictPolicy policy = ConflictPolicyListBox.SelectedIndex switch
        {
            1 => InitializationConflictPolicy.Source,
            2 => InitializationConflictPolicy.Abort,
            _ => InitializationConflictPolicy.Destination,
        };

        NextButton.IsEnabled = false;
        BackButton.IsEnabled = false;
        ShowMessage("Initializing the source from the destination. This reads every selected file, so it can take a while…", isError: false);
        try
        {
            InitializationResult result = await BackupSyncProcessRunner.RunInitializationAsync(
                App.Instance.PowerShellFolder,
                _sourcePath,
                _destinationPath,
                policy,
                CancellationToken.None).ConfigureAwait(true);

            if (!result.Succeeded)
            {
                ShowMessage("Initialization failed.");
                MessageBox.Show(
                    this,
                    "The initialization step stopped. No files were deleted.\n\n" + TrimOutput(result.Output),
                    "Initialization failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return false;
            }

            ClearMessage();
            MessageBox.Show(
                this,
                "Initialization finished.\n\n" + TrimOutput(result.Output),
                "Initialization finished",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return true;
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            ShowMessage("Initialization failed: " + exception.Message);
            return false;
        }
        finally
        {
            NextButton.IsEnabled = true;
            BackButton.IsEnabled = _step > 0;
        }
    }

    // ── Step 3: application ────────────────────────────────────────────────

    private async void LoadExecutablesAsync()
    {
        try
        {
            ExecutableStatusTextBlock.Text = "Searching for executables in the source folder…";
            _executableOptions.Clear();
            ExecutableOption manual = new ExecutableOption { Display = "No application (manual sync only)" };
            _executableOptions.Add(manual);
            ExecutableListBox.SelectedIndex = 0;

            string source = _sourcePath;
            IReadOnlyList<string> found = await Task.Run(() => ExecutableDiscovery.Find(source)).ConfigureAwait(true);

            foreach (string path in found)
            {
                _executableOptions.Add(new ExecutableOption
                {
                    Display = ExecutableDiscovery.ToConfigurationValue(source, path),
                    FullPath = path,
                    Icon = ShellInterop.LoadShellIcon(path),
                });
            }

            ExecutableListBox.SelectedIndex = 0;
            ExecutableStatusTextBlock.Text = found.Count == 0
                ? "No .exe files were found in the source folder. Keep manual sync, or browse for an executable outside it."
                : found.Count + " executable(s) found. Choose the one the launcher should start.";
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            ExecutableStatusTextBlock.Text = "The executable search failed: " + exception.Message;
        }
    }

    private void BrowseExecutable_Click(object sender, RoutedEventArgs e)
    {
        string? selected = ShellInterop.BrowseForExecutable(
            "Select the application executable",
            string.IsNullOrWhiteSpace(_sourcePath) ? null : _sourcePath);
        if (selected is null)
        {
            return;
        }
        if (!string.Equals(Path.GetExtension(selected), ".exe", StringComparison.OrdinalIgnoreCase))
        {
            MessageBox.Show(this, "Choose a file with the .exe extension.", "BackupSync", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        ExecutableOption option = new ExecutableOption
        {
            Display = ExecutableDiscovery.ToConfigurationValue(_sourcePath, selected),
            FullPath = selected,
            Icon = ShellInterop.LoadShellIcon(selected),
        };
        _executableOptions.Add(option);
        ExecutableListBox.SelectedItem = option;
    }

    private void AdvanceFromExecutable()
    {
        ExecutableOption? selected = ExecutableListBox.SelectedItem as ExecutableOption;
        if (selected is null && _executableOptions.Count > 0)
        {
            selected = _executableOptions[0];
            ExecutableListBox.SelectedIndex = 0;
        }
        _executableFullPath = selected?.FullPath ?? string.Empty;
        _executableLine = string.IsNullOrWhiteSpace(_executableFullPath)
            ? string.Empty
            : ExecutableDiscovery.ToConfigurationValue(_sourcePath, _executableFullPath);
    }

    // ── Step 4: delay ──────────────────────────────────────────────────────

    private bool AdvanceFromDelay()
    {
        string text = (DelayTextBox.Text ?? string.Empty).Trim();
        if (text.Length == 0)
        {
            _delaySeconds = 10;
            DelayTextBox.Text = "10";
            return true;
        }
        if (!int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out int delay) || delay < 0)
        {
            ShowMessage("The delay must be a nonnegative whole number of seconds.");
            return false;
        }
        _delaySeconds = delay;
        return true;
    }

    // ── Step 5: write everything ────────────────────────────────────────────

    private void AttemptFinish()
    {
        if (!RulesEditorControl.TryGetRules(out List<string> rules, out string error))
        {
            ShowMessage(error);
            return;
        }

        try
        {
            if (_reconfigureExisting)
            {
                ConfigurationFileService.BackupExisting(_sourcePath);
            }

            BackupConfiguration configuration = new BackupConfiguration
            {
                SourcePath = _sourcePath,
                RawDestinationLine = _destinationPath,
                DestinationPath = _destinationPath,
                ExecutableLine = _executableLine,
                ResolvedExecutablePath = _executableFullPath,
                DelaySeconds = _delaySeconds,
                RuleLines = rules,
            };

            string engineScript = ScriptLocator.GetScriptPath(App.Instance.PowerShellFolder, ScriptLocator.EngineFileName);
            ConfigurationFileService.Write(_sourcePath, configuration, engineScript);
            ShortcutService.CreateShortcuts(_sourcePath, _destinationPath, _executableFullPath, App.Instance.PowerShellFolder);
            App.Instance.Registry.Add(_sourcePath);

            ConfigurationSaved = true;
            if (OpenFolderCheckBox.IsChecked == true)
            {
                ShellInterop.SelectFileInExplorer(ConfigurationFileService.GetPath(_sourcePath));
            }
            DialogResult = true;
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            ShowMessage("The configuration could not be saved: " + exception.Message);
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private static bool IsDriveRoot(string path)
    {
        string root = Path.GetPathRoot(path) ?? string.Empty;
        return string.Equals(root.TrimEnd('\\', '/'), path.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
    }

    private static string TrimOutput(string output)
    {
        if (string.IsNullOrWhiteSpace(output))
        {
            return "The step produced no output.";
        }
        string trimmed = output.Trim();
        if (trimmed.Length <= 1500)
        {
            return trimmed;
        }
        return "…" + trimmed.Substring(trimmed.Length - 1500);
    }

    private void ShowMessage(string message, bool isError = true)
    {
        MessageTextBlock.Text = message;
        MessageTextBlock.Foreground = isError
            ? (Brush)FindResource("DangerBrush")
            : (Brush)FindResource("TextMutedBrush");
    }

    private void ClearMessage()
    {
        MessageTextBlock.Text = string.Empty;
    }
}
