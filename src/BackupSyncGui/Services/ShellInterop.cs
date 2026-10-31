using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace BackupSyncGui.Services;

/// <summary>
/// Thin Windows shell helpers: folder/file pickers, Explorer activation and
/// shell icon extraction.
/// </summary>
internal static class ShellInterop
{
    private const uint ShgfiIcon = 0x00000100;

    private const uint ShgfiLargeIcon = 0x00000000;

    public static string? BrowseForFolder(string title, string? initialFolder)
    {
        OpenFolderDialog dialog = new OpenFolderDialog
        {
            Title = title,
            Multiselect = false,
        };
        if (!string.IsNullOrWhiteSpace(initialFolder) && Directory.Exists(initialFolder))
        {
            dialog.InitialDirectory = initialFolder;
        }
        bool? result = dialog.ShowDialog();
        if (result != true || string.IsNullOrWhiteSpace(dialog.FolderName))
        {
            return null;
        }
        return ConfigurationFileService.NormalizePath(dialog.FolderName);
    }

    public static string? BrowseForExecutable(string title, string? initialFolder)
    {
        OpenFileDialog dialog = new OpenFileDialog
        {
            Title = title,
            Filter = "Applications (*.exe)|*.exe",
            CheckFileExists = true,
            CheckPathExists = true,
            Multiselect = false,
        };
        if (!string.IsNullOrWhiteSpace(initialFolder) && Directory.Exists(initialFolder))
        {
            dialog.InitialDirectory = initialFolder;
        }
        bool? result = dialog.ShowDialog();
        if (result != true)
        {
            return null;
        }
        return dialog.FileName;
    }

    public static void OpenFolder(string folder)
    {
        if (string.IsNullOrWhiteSpace(folder))
        {
            return;
        }
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = "\"" + folder + "\"",
            UseShellExecute = true,
        });
    }

    public static void SelectFileInExplorer(string filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath))
        {
            return;
        }
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = "/select,\"" + filePath + "\"",
            UseShellExecute = true,
        });
    }

    /// <summary>Shell icon (32x32) for a file, folder, shortcut or executable.</summary>
    public static ImageSource? LoadShellIcon(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }
        ShellFileInfo info = new ShellFileInfo();
        IntPtr result = SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf<ShellFileInfo>(), ShgfiIcon | ShgfiLargeIcon);
        if (result == IntPtr.Zero || info.IconHandle == IntPtr.Zero)
        {
            return null;
        }
        try
        {
            BitmapSource source = Imaging.CreateBitmapSourceFromHIcon(
                info.IconHandle,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            DestroyIcon(info.IconHandle);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(
        string path,
        uint fileAttributes,
        ref ShellFileInfo fileInfo,
        uint fileInfoSize,
        uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShellFileInfo
    {
        public IntPtr IconHandle;
        public int IconIndex;
        public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string TypeName;
    }
}
