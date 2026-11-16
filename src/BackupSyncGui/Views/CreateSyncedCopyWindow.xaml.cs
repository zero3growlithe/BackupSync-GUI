using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using BackupSyncGui.Models;
using BackupSyncGui.Services;

namespace BackupSyncGui.Views;

/// <summary>
/// The "Create synced copy" flow: pick a source folder, pick a destination, review the optional
/// create_copy_setup.txt, then let New-SyncCopy.ps1 fill the destination once. When that succeeds the
/// pair's backup_setup.txt already exists, so all that is left is registering it and adding shortcuts.
/// </summary>
public partial class CreateSyncedCopyWindow : Window
{
    private const int StepCount = 4;

    private const string VersionFileName = "backup_version.txt";

    private static readonly string[] StepTitles =
    {
        "Source folder",
        "Destination folder",
        "Setup file for the first copy",
        "Application and delay",
    };

    private static readonly string[] StepSubtitles =
    {
        "Pick the folder you want to copy. Its files stay the reference side of the pair.",
        "Pick the folder that should receive the copy. One destination serves one logical set of files.",
        "create_copy_setup.txt decides what the first copy carries and how the pair is configured afterwards.",
        "Choose what the launcher starts in the copied folder, and how long it waits before syncing again.",
    };

    private string _sourcePath = string.Empty;

    private string _destinationPath = string.Empty;

    private readonly ObservableCollection<ExecutableOption> _executableOptions = new ObservableCollection<ExecutableOption>();

    private bool _setupFileExists;

    private bool _copyCompleted;

    private bool _destinationOpened;

    private bool _running;

    private bool _finished;

    private CancellationTokenSource? _cancellation;

    private int _step;

    public CreateSyncedCopyWindow()
    {
        InitializeComponent();
        ExecutableListBox.ItemsSource = _executableOptions;
        GoToStep(0);
    }

    /// <summary>True when the copy ran and the pair was registered.</summary>
    public bool ConfigurationCreated { get; private set; }

    public string CreatedSourcePath => _sourcePath;

    public string CreatedDestinationPath => _destinationPath;

    // ── Navigation ────────────────────────────────────────────────────────

    private void GoToStep(int step)
    {
        _step = step;
        SourceStepPanel.Visibility = step == 0 ? Visibility.Visible : Visibility.Collapsed;
        DestinationStepPanel.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        SetupStepPanel.Visibility = step == 2 ? Visibility.Visible : Visibility.Collapsed;
        ApplicationStepPanel.Visibility = step == 3 ? Visibility.Visible : Visibility.Collapsed;

        StepTitleTextBlock.Text = StepTitles[step];
        StepSubtitleTextBlock.Text = StepSubtitles[step];
        StepCounterTextBlock.Text = "Step " + (step + 1) + " of " + StepCount;
        BackButton.IsEnabled = step > 0 && !_copyCompleted;
        if (step == StepCount - 1)
        {
            NextButton.Content = "Finish";
        }
        else if (step == StepCount - 2)
        {
            NextButton.Content = "Create synced copy";
        }
        else
        {
            NextButton.Content = "Next";
        }
        ClearMessage();

        if (step == 0)
        {
            SourcePathTextBox.Focus();
            SourcePathTextBox.CaretIndex = SourcePathTextBox.Text.Length;
        }
        if (step == 2)
        {
            SetupEditorTextBox.Focus();
        }
        if (step == StepCount - 1)
        {
            PrepareApplicationStep();
        }
    }

    /// <summary>Step 4 keeps whatever the copy already wrote, and offers the executables it brought along.</summary>
    private void PrepareApplicationStep()
    {
        _copyCompleted = true;
        try
        {
            BackupConfiguration configuration = ConfigurationFileService.Read(_sourcePath);
            DelayTextBox.Text = configuration.DelaySeconds.ToString(CultureInfo.InvariantCulture);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            if (string.IsNullOrWhiteSpace(DelayTextBox.Text))
            {
                DelayTextBox.Text = "10";
            }
        }
        if (_executableOptions.Count == 0)
        {
            LoadExecutablesAsync();
        }
        OpenDestinationCheckBox.IsChecked = true;
    }

    private async void Next_Click(object sender, RoutedEventArgs e)
    {
        if (_finished)
        {
            DialogResult = true;
            return;
        }

        try
        {
            switch (_step)
            {
                case 0:
                    if (AdvanceFromSource())
                    {
                        GoToStep(1);
                    }
                    return;

                case 1:
                    if (AdvanceFromDestination())
                    {
                        GoToStep(2);
                    }
                    return;

                case 2:
                    await AttemptCreateAsync().ConfigureAwait(true);
                    return;

                default:
                    FinishApplication();
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
        if (_running || _copyCompleted || _step == 0)
        {
            return;
        }
        GoToStep(_step - 1);
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (_running)
        {
            _cancellation?.Cancel();
            ShowMessage("Stopping the copy. Files already copied stay in place.", isError: false);
            return;
        }
        DialogResult = false;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        _cancellation?.Cancel();
        // The copy already wrote the configuration: keep the pair rather than leaving it half registered.
        if (_copyCompleted && !ConfigurationCreated)
        {
            try
            {
                CompleteRegistration(ConfigurationFileService.Read(_sourcePath), openDestination: false);
            }
            catch (Exception exception)
            {
                CrashLog.Write(exception);
            }
        }
        base.OnClosing(e);
    }

    // ── Step 1: source ─────────────────────────────────────────────────────

    private void BrowseSource_Click(object sender, RoutedEventArgs e)
    {
        string? selected = ShellInterop.BrowseForFolder(
            "Select the folder to create a synced copy of",
            SourcePathTextBox.Text);
        if (selected is null)
        {
            return;
        }
        SourcePathTextBox.Text = selected;
        SourceInfoTextBlock.Text = string.Empty;
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

        bool hasConfiguration = ConfigurationFileService.Exists(source);
        bool alreadySynced = File.Exists(Path.Combine(source, VersionFileName));
        if (hasConfiguration || alreadySynced)
        {
            MessageBoxResult answer = MessageBox.Show(
                this,
                "This folder already carries BackupSync state:\n\n" +
                (hasConfiguration ? ConfigurationFileService.GetPath(source) + "\n" : string.Empty) +
                (alreadySynced ? Path.Combine(source, VersionFileName) + "\n" : string.Empty) +
                "\nYes — keep copying; the configuration is backed up first and then overwritten.\n" +
                "No — choose a different source folder.",
                "Configuration already exists",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question,
                MessageBoxResult.No);
            if (answer != MessageBoxResult.Yes)
            {
                return false;
            }
        }

        _sourcePath = source;
        SourcePathTextBox.Text = source;
        LoadSetupFile();

        if (_setupFileExists)
        {
            SyncCopySetupFile.TryParse(SetupEditorTextBox.Text, out SyncCopySetup parsed, out _);
            SourceInfoTextBlock.Text =
                "Found " + SyncCopySetupFile.GetPath(source) + " — " +
                parsed.SelectionRuleCount + " selection rule(s), " + parsed.LinkRuleCount + " link rule(s)" +
                (parsed.HasTemplate ? ", plus a template for backup_setup.txt." : ".");
        }
        else
        {
            SourceInfoTextBlock.Text =
                "No " + SyncCopySetupFile.FileName + " in this folder, so every file is copied and the rules " +
                "written to the pair come from the selection rules step. You can still write a setup file on the next step.";
        }
        return true;
    }

    /// <summary>Loads create_copy_setup.txt, or prepares an empty editor when there is none yet.</summary>
    private void LoadSetupFile()
    {
        _setupFileExists = SyncCopySetupFile.Exists(_sourcePath);
        SetupEditorTextBox.Text = _setupFileExists ? SyncCopySetupFile.ReadText(_sourcePath) : string.Empty;
        if (!_setupFileExists)
        {
            SetupEditorTextBox.Text = BuildStarterText();
        }

        ApplySetupCheckBox.IsChecked = _setupFileExists;
        ApplySetupCheckBox.IsEnabled = true;
        ApplySetupCheckBox.Content = _setupFileExists
            ? "Apply this setup file to the first copy"
            : "Apply the setup text to the first copy";
        StarterFileButton.Visibility = _setupFileExists ? Visibility.Collapsed : Visibility.Visible;
        SetupInfoTextBlock.Text = _setupFileExists
            ? "The source folder carries " + SyncCopySetupFile.GetPath(_sourcePath) +
              ". Review it below: the text you leave here is written to that file before the copy starts, so the " +
              "copy obeys exactly what you approve."
            : "The source folder has no " + SyncCopySetupFile.FileName +
              ". Leave the box unchecked to copy every file, or edit the starter text below and keep the box " +
              "checked — it is then saved as " + SyncCopySetupFile.GetPath(_sourcePath) + " and used for the copy.";
        UpdateSetupEditorState();
    }

    private void StarterFile_Click(object sender, RoutedEventArgs e)
    {
        SetupEditorTextBox.Text = BuildStarterText();
        ApplySetupCheckBox.IsChecked = true;
        SetupEditorTextBox.IsEnabled = true;
        SetupEditorTextBox.Focus();
        ShowMessage("A starter file was placed in the editor. Review it, then continue.", isError: false);
    }

    private void ApplySetup_Changed(object sender, RoutedEventArgs e)
    {
        if (SetupEditorTextBox is null)
        {
            return;
        }
        UpdateSetupEditorState();
    }

    private void UpdateSetupEditorState()
    {
        bool apply = ApplySetupCheckBox.IsChecked == true;
        SetupEditorTextBox.IsEnabled = apply && !_running;
        StarterFileButton.IsEnabled = !_running;
        if (SetupEditorTextBox.IsEnabled && !_setupFileExists && string.IsNullOrWhiteSpace(SetupEditorTextBox.Text))
        {
            SetupEditorTextBox.Text = BuildStarterText();
        }
    }

    // ── Step 2: destination ────────────────────────────────────────────────

    private void BrowseDestination_Click(object sender, RoutedEventArgs e)
    {
        string? selected = ShellInterop.BrowseForFolder(
            "Select the folder that should receive the copy",
            DestinationPathTextBox.Text);
        if (selected is null)
        {
            return;
        }
        DestinationPathTextBox.Text = selected;
        DestinationInfoTextBlock.Text = string.Empty;
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
            MessageBoxResult create = MessageBox.Show(
                this,
                "That folder does not exist yet:\n\n" + candidate + "\n\nCreate it now?",
                "Create destination folder",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question,
                MessageBoxResult.Yes);
            if (create != MessageBoxResult.Yes)
            {
                return false;
            }
            try
            {
                Directory.CreateDirectory(candidate);
            }
            catch (Exception exception)
            {
                CrashLog.Write(exception);
                ShowMessage("The folder could not be created: " + exception.Message);
                return false;
            }
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
        DestinationInfoTextBlock.Text = "The copy is written to " + destination +
                                        ". Files that are already there are replaced, and the replaced versions are kept in " +
                                        Path.Combine(destination, ".backup_sync_recovery") + ".";
        return true;
    }

    // ── Step 3: run the copy ───────────────────────────────────────────────

    private async Task AttemptCreateAsync()
    {
        if (_running)
        {
            return;
        }

        bool applySetup = ApplySetupCheckBox.IsChecked == true;
        string setupText = SetupEditorTextBox.Text ?? string.Empty;
        bool copyEverything = !applySetup;

        SyncCopySetup plan = new SyncCopySetup();
        if (!copyEverything)
        {
            if (!SyncCopySetupFile.TryParse(setupText, out SyncCopySetup parsed, out string error))
            {
                ShowMessage(error);
                return;
            }
            plan = parsed;
        }

        MessageBoxResult answer = MessageBox.Show(
            this,
            "Create the copy now?\n\nFrom: " + _sourcePath + "\nTo: " + _destinationPath + "\n\n" + DescribePlan(copyEverything, plan),
            "Create synced copy",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Question,
            MessageBoxResult.OK);
        if (answer != MessageBoxResult.OK)
        {
            return;
        }

        await RunCopyAsync(copyEverything, setupText).ConfigureAwait(true);
    }

    private async Task RunCopyAsync(bool copyEverything, string setupText)
    {
        _running = true;
        _cancellation = new CancellationTokenSource();
        SetBusyState(true);
        CopyLogTextBox.Text = string.Empty;
        CopyLogTextBox.Visibility = Visibility.Visible;
        CopyLogLabelTextBlock.Visibility = Visibility.Visible;
        ShowMessage("Copying. Large folders take a while; the progress below is live.", isError: false);

        try
        {
            if (!copyEverything && !string.Equals(Normalize(setupText), Normalize(SyncCopySetupFile.ReadText(_sourcePath)), StringComparison.Ordinal))
            {
                SyncCopySetupFile.WriteText(_sourcePath, setupText);
                AppendLog("Saved the edited setup file to " + SyncCopySetupFile.GetPath(_sourcePath));
            }
            if (ConfigurationFileService.Exists(_sourcePath))
            {
                string? backupPath = ConfigurationFileService.BackupExisting(_sourcePath);
                if (backupPath is not null)
                {
                    AppendLog("Kept the previous configuration as " + backupPath);
                }
            }

            IProgress<string> progress = new Progress<string>(AppendLog);
            InitializationResult result = await BackupSyncProcessRunner.RunSyncCopyAsync(
                App.Instance.PowerShellFolder,
                _sourcePath,
                _destinationPath,
                copyEverything,
                progress,
                _cancellation.Token).ConfigureAwait(true);

            if (!result.Succeeded)
            {
                ShowMessage("The copy did not finish: " + Summarize(result.Output));
                MessageBox.Show(
                    this,
                    "The copy stopped before it finished.\n\n" + TrimOutput(result.Output),
                    "Create synced copy",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                NextButton.Content = "Try again";
                return;
            }

            GoToStep(StepCount - 1);
            OpenDestinationIfWanted();
            ShowMessage("The copy is finished. One more decision: what the launcher should start.", isError: false);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            ShowMessage("The copy failed: " + exception.Message);
        }
        finally
        {
            _running = false;
            SetBusyState(false);
            _cancellation?.Dispose();
            _cancellation = null;
        }
    }

    // ── Step 4: what the launcher starts ───────────────────────────────────

    private void RefreshExecutables_Click(object sender, RoutedEventArgs e)
    {
        _executableOptions.Clear();
        LoadExecutablesAsync();
    }

    private async void LoadExecutablesAsync()
    {
        try
        {
            ExecutableStatusTextBlock.Text = "Looking for executables in the copied folder…";
            _executableOptions.Clear();
            ExecutableOption manual = new ExecutableOption { Display = "No application (manual sync only)" };
            _executableOptions.Add(manual);
            ExecutableListBox.SelectedIndex = 0;

            string source = _sourcePath;
            string destination = _destinationPath;
            IReadOnlyList<string> inDestination = await Task.Run(() => ExecutableDiscovery.Find(destination)).ConfigureAwait(true);
            IReadOnlyList<string> inSource = await Task.Run(() => ExecutableDiscovery.Find(source)).ConfigureAwait(true);

            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int added = 0;
            foreach (string path in inDestination)
            {
                if (!seen.Add(ConfigurationFileService.NormalizePath(path)))
                {
                    continue;
                }
                _executableOptions.Add(new ExecutableOption
                {
                    Display = ExecutableDiscovery.ToConfigurationValue(source, path),
                    FullPath = path,
                    Icon = ShellInterop.LoadShellIcon(path),
                });
                added++;
            }
            foreach (string path in inSource)
            {
                if (!seen.Add(ConfigurationFileService.NormalizePath(path)))
                {
                    continue;
                }
                _executableOptions.Add(new ExecutableOption
                {
                    Display = ExecutableDiscovery.ToConfigurationValue(source, path),
                    FullPath = path,
                    Icon = ShellInterop.LoadShellIcon(path),
                });
                added++;
            }

            ExecutableListBox.SelectedIndex = 0;
            ExecutableStatusTextBlock.Text = added == 0
                ? "No .exe files were found in the copy. Keep manual sync, or browse for an executable yourself."
                : added + " executable(s) found in the copy. Choose the one the launcher should start, or keep manual sync.";
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
            string.IsNullOrWhiteSpace(_destinationPath) ? null : _destinationPath);
        if (selected is null)
        {
            return;
        }
        if (!string.Equals(Path.GetExtension(selected), ".exe", StringComparison.OrdinalIgnoreCase))
        {
            ShowMessage("Choose a file with the .exe extension.");
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
        ClearMessage();
    }

    /// <summary>Writes the executable and delay into the pair's configuration, then finishes the flow.</summary>
    private void FinishApplication()
    {
        if (_running)
        {
            return;
        }

        ExecutableOption? selected = ExecutableListBox.SelectedItem as ExecutableOption;
        if (selected is null && _executableOptions.Count > 0)
        {
            selected = _executableOptions[0];
            ExecutableListBox.SelectedIndex = 0;
        }
        string executablePath = selected?.FullPath ?? string.Empty;
        string executableLine = string.IsNullOrWhiteSpace(executablePath)
            ? string.Empty
            : ExecutableDiscovery.ToConfigurationValue(_sourcePath, executablePath);

        string delayText = (DelayTextBox.Text ?? string.Empty).Trim();
        int delay = 10;
        if (delayText.Length > 0)
        {
            if (!int.TryParse(delayText, NumberStyles.Integer, CultureInfo.InvariantCulture, out delay) || delay < 0)
            {
                ShowMessage("The delay must be a nonnegative whole number of seconds.");
                return;
            }
        }

        try
        {
            BackupConfiguration configuration = ConfigurationFileService.Read(_sourcePath);
            configuration.ExecutableLine = executableLine;
            configuration.ResolvedExecutablePath = string.IsNullOrWhiteSpace(executablePath)
                ? string.Empty
                : ConfigurationFileService.NormalizePath(executablePath);
            configuration.DelaySeconds = delay;

            string engineScript = ScriptLocator.GetScriptPath(App.Instance.PowerShellFolder, ScriptLocator.EngineFileName);
            ConfigurationFileService.Write(_sourcePath, configuration, engineScript);
            CompleteRegistration(configuration, OpenDestinationCheckBox.IsChecked == true);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            ShowMessage("The configuration could not be saved: " + exception.Message);
        }
    }

    /// <summary>Shortcuts, list entry and the final wording. The configuration file is already written.</summary>
    private void CompleteRegistration(BackupConfiguration configuration, bool openDestination)
    {
        try
        {
            ShortcutService.CreateShortcuts(
                _sourcePath,
                configuration.DestinationPath,
                configuration.ResolvedExecutablePath,
                App.Instance.PowerShellFolder);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            AppendLog("Shortcuts could not be created: " + exception.Message);
        }

        App.Instance.Registry.Add(_sourcePath);
        ConfigurationCreated = true;
        _finished = true;

        NextButton.Content = "Close";
        NextButton.IsEnabled = true;
        BackButton.IsEnabled = false;
        CancelButton.Visibility = Visibility.Collapsed;
        StepTitleTextBlock.Text = "Synced copy created";
        StepSubtitleTextBlock.Text = "The destination is populated and the pair is registered.";
        StepCounterTextBlock.Text = "Finished";
        ShowMessage(
            "Done. The pair launches " + configuration.ExecutableDisplayName + " with a " +
            configuration.DelaySeconds + " second delay; “Sync now” in the list keeps it up to date.",
            isError: false);
        AppendLog("Registered the pair in " + ConfigurationFileService.GetPath(_sourcePath));

        if (openDestination)
        {
            OpenDestinationIfWanted();
        }
    }

    /// <summary>Explorer opens in the folder the copy just filled, at most once per run.</summary>
    private void OpenDestinationIfWanted()
    {
        if (_destinationOpened || OpenDestinationCheckBox.IsChecked != true || string.IsNullOrWhiteSpace(_destinationPath))
        {
            return;
        }
        try
        {
            ShellInterop.OpenFolder(_destinationPath);
            _destinationOpened = true;
            AppendLog("Opened " + _destinationPath);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            AppendLog("The destination folder could not be opened: " + exception.Message);
        }
    }

    private void SetBusyState(bool busy)
    {
        NextButton.IsEnabled = !busy;
        BackButton.IsEnabled = !busy && !_finished && !_copyCompleted && _step > 0;
        CancelButton.Content = busy ? "Stop" : "Cancel";
        ApplySetupCheckBox.IsEnabled = !busy;
        UpdateSetupEditorState();
    }

    private void AppendLog(string line)
    {
        if (string.IsNullOrEmpty(line))
        {
            return;
        }
        CopyLogTextBox.AppendText(line + Environment.NewLine);
        CopyLogTextBox.ScrollToEnd();
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private static string BuildStarterText()
    {
        string[] lines =
        {
            "# create_copy_setup.txt — used once, by \"Create synced copy\".",
            "# The copy obeys these rules, then becomes the pair's backup_setup.txt rules.",
            "# +rule includes, -rule excludes. No + rule at all means: copy every file.",
            "# Examples:",
            "#   +Saves",
            "#   +*.ini",
            "#   -**/cache/**",
            "#   -*.tmp",
            "#",
            "# A rule that starts with $ creates a link in the destination instead of a copy.",
            "# Use it for heavy files an emulator can read straight from the copy folder:",
            "#   $**/roms/**",
            "#   $**/*.iso",
            "# Links only work while the source folder is reachable from this computer.",
            "#",
            "# Everything between the two markers below becomes the pair's backup_setup.txt.",
            "# Its layout is: destination, executable (empty for manual sync), delay, then rules.",
            "# {Destination} is replaced with the folder you picked, {Source} with this folder.",
            "#",
            "# backup_setup.txt template",
            "# {Destination}",
            "# ",
            "# 10",
            "# end backup_setup.txt",
        };
        return string.Join(Environment.NewLine, lines);
    }

    private static string DescribePlan(bool copyEverything, SyncCopySetup plan)
    {
        if (copyEverything)
        {
            return "Every file is copied. create_copy_setup.txt is ignored and the selection rules are written " +
                   "straight into the new backup_setup.txt.";
        }

        List<string> parts = new List<string>
        {
            plan.SelectionRuleCount == 0
                ? "No selection rules, so every file is copied."
                : plan.SelectionRuleCount + " selection rule(s).",
        };
        if (plan.LinkRuleCount > 0)
        {
            parts.Add(plan.LinkRuleCount + " link rule(s): those paths are not copied. The destination points at " +
                      "the source file, so it only works while the source folder stays reachable from this computer. " +
                      "Windows asks for administrator rights when the links are created unless Developer Mode is on.");
        }
        parts.Add(plan.HasTemplate
            ? "The template becomes this pair's backup_setup.txt. Link rules it does not repeat are added to it, " +
              "so the links keep working."
            : "Without a template the rules above also become this pair's backup_setup.txt.");
        return string.Join(" ", parts);
    }

    private static string Normalize(string text)
    {
        return (text ?? string.Empty).Replace("\r\n", "\n").Replace('\r', '\n').TrimEnd();
    }

    private static bool IsDriveRoot(string path)
    {
        string root = Path.GetPathRoot(path) ?? string.Empty;
        return string.Equals(root.TrimEnd('\\', '/'), path.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
    }

    private static string Summarize(string output)
    {
        if (string.IsNullOrWhiteSpace(output))
        {
            return "the script produced no output.";
        }
        string[] lines = output.Replace("\r\n", "\n").Split('\n');
        for (int index = lines.Length - 1; index >= 0; index--)
        {
            string line = lines[index].Trim();
            if (line.Length > 0)
            {
                return line;
            }
        }
        return "the script produced no output.";
    }

    private static string TrimOutput(string output)
    {
        if (string.IsNullOrWhiteSpace(output))
        {
            return "The script produced no output.";
        }
        string trimmed = output.Trim();
        if (trimmed.Length <= 2000)
        {
            return trimmed;
        }
        return "…" + trimmed.Substring(trimmed.Length - 2000);
    }

    private void ShowMessage(string message, bool isError = true)
    {
        MessageTextBlock.Text = message;
        MessageTextBlock.Foreground = isError
            ? (System.Windows.Media.Brush)FindResource("DangerBrush")
            : (System.Windows.Media.Brush)FindResource("TextMutedBrush");
    }

    private void ClearMessage()
    {
        MessageTextBlock.Text = string.Empty;
    }
}
