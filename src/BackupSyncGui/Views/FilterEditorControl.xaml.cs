using System;
using System.Collections.Generic;
using System.Windows.Controls;
using System.Windows.Input;
using BackupSyncGui.Services;

namespace BackupSyncGui.Views;

/// <summary>
/// The selection rule editor: a plain text box with an explicit undo stack,
/// Undo/Redo buttons and Ctrl+Z / Ctrl+Y / Ctrl+S handling.
/// </summary>
public partial class FilterEditorControl : UserControl
{
    public FilterEditorControl()
    {
        InitializeComponent();
    }

    /// <summary>Raised when the user presses Ctrl+S inside the editor.</summary>
    public event EventHandler? SaveRequested;

    public string RulesText
    {
        get => RulesTextBox.Text;
        set
        {
            RulesTextBox.Text = value ?? string.Empty;
            RulesTextBox.CaretIndex = RulesTextBox.Text.Length;
        }
    }

    public void FocusEditor()
    {
        RulesTextBox.Focus();
        RulesTextBox.CaretIndex = RulesTextBox.Text.Length;
    }

    public bool TryGetRules(out List<string> ruleLines, out string error)
    {
        return ConfigurationFileService.TryParseRules(RulesTextBox.Text, out ruleLines, out error);
    }

    private void RulesTextBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        bool controlPressed = (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control;
        if (!controlPressed)
        {
            return;
        }

        // Handled here rather than through InputBindings so exactly one undo or
        // redo step runs even when the TextBox template also reacts to the key.
        if (e.Key == Key.Z)
        {
            e.Handled = true;
            UndoOrRedo(direction: -1);
            return;
        }
        if (e.Key == Key.Y)
        {
            e.Handled = true;
            UndoOrRedo(direction: 1);
            return;
        }
        if (e.Key == Key.S)
        {
            e.Handled = true;
            SaveRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void UndoOrRedo(int direction)
    {
        if (direction < 0)
        {
            if (RulesTextBox.CanUndo)
            {
                RulesTextBox.Undo();
            }
        }
        else
        {
            if (RulesTextBox.CanRedo)
            {
                RulesTextBox.Redo();
            }
        }
        RulesTextBox.Focus();
    }

    private void Undo_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        UndoOrRedo(direction: -1);
    }

    private void Redo_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        UndoOrRedo(direction: 1);
    }
}
