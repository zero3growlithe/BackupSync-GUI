using System;
using System.Collections.Generic;
using System.Windows;
using BackupSyncGui.Services;

namespace BackupSyncGui.Views;

/// <summary>
/// Stand-alone selection rule editor used from the main window.
/// </summary>
public partial class FilterEditorWindow : Window
{
    public FilterEditorWindow()
    {
        InitializeComponent();
        EditorControl.SaveRequested += EditorControl_SaveRequested;
        Loaded += FilterEditorWindow_Loaded;
    }

    public List<string> RuleLines { get; private set; } = new List<string>();

    public void Initialize(string displayName, string rulesText)
    {
        TitleTextBlock.Text = "Selection rules for " + displayName;
        EditorControl.RulesText = rulesText;
    }

    private void FilterEditorWindow_Loaded(object sender, RoutedEventArgs e)
    {
        EditorControl.FocusEditor();
    }

    private void EditorControl_SaveRequested(object? sender, EventArgs e)
    {
        AttemptSave();
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        AttemptSave();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void AttemptSave()
    {
        if (!EditorControl.TryGetRules(out List<string> rules, out string error))
        {
            ValidationTextBlock.Text = error;
            return;
        }
        ValidationTextBlock.Text = string.Empty;
        RuleLines = rules;
        DialogResult = true;
    }
}
