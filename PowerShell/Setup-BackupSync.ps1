#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Source,
    [switch]$NoExplorer
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')
function RestoreConsoleFocus {
    try {
        if (-not ('BackupSync.ConsoleFocus' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace BackupSync {
    public static class ConsoleFocus {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool BringWindowToTop(IntPtr window);
    }
}
'@
        }
        $window=[BackupSync.ConsoleFocus]::GetConsoleWindow()
        if ($window -ne [IntPtr]::Zero) {
            [void][BackupSync.ConsoleFocus]::ShowWindowAsync($window,9)
            [void][BackupSync.ConsoleFocus]::BringWindowToTop($window)
            [void][BackupSync.ConsoleFocus]::SetForegroundWindow($window)
        }
    } catch {
        # Focus restoration is best-effort and must never stop setup.
    }
}
function ChooseFolder([string]$Title) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description=$Title
    $dialog.ShowNewFolderButton=$true
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Setup cancelled.' }
        return $dialog.SelectedPath
    } finally {
        $dialog.Dispose()
        RestoreConsoleFocus
    }
}
function ChooseExecutable([string]$InitialDirectory) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=New-Object Windows.Forms.OpenFileDialog
    $dialog.Title='Select the application executable'
    $dialog.Filter='Applications (*.exe)|*.exe'
    $dialog.InitialDirectory=$InitialDirectory
    $dialog.CheckFileExists=$true
    $dialog.CheckPathExists=$true
    $dialog.DereferenceLinks=$true
    $dialog.Multiselect=$false
    $dialog.RestoreDirectory=$true
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
        return $dialog.FileName
    } finally {
        $dialog.Dispose()
        RestoreConsoleFocus
    }
}
try {
    if (-not $Source) { $Source=ChooseFolder 'Select the SOURCE folder to synchronize' }
    $Source=(Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw 'Source must be a folder.' }
    $config=Join-Path $Source 'backup_setup.txt'
    if (Test-Path -LiteralPath $config) {
        if ((Read-Host 'A config already exists. Replace it and its selection rules? Type YES').Trim() -cne 'YES') { exit 0 }
        Copy-Item -LiteralPath $config -Destination ($config+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak') -ErrorAction Stop
    }
    $destination=(ChooseFolder 'Select a dedicated DESTINATION folder (its files will participate in two-way sync)').TrimEnd('\')
    if ($Source -eq $destination -or $Source.StartsWith($destination+'\',[StringComparison]::OrdinalIgnoreCase) -or
        $destination.StartsWith($Source+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source and destination must be separate, non-nested folders.' }
    foreach ($root in @($Source,$destination)) {
        if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { throw 'Choose dedicated folders, not drive/share roots.' }
    }
    InitializeSource $Source $destination
    Write-Host "`nSearching executables in $Source ..."
    # Do not recurse through links or the recovery directory.
    $found=New-Object 'Collections.Generic.List[string]'
    $stack=New-Object 'Collections.Generic.Stack[string]'; $stack.Push($Source)
    while ($stack.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $stack.Pop() -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Name -eq '.backup_sync_recovery') { continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            elseif ($item.Extension -eq '.exe') { $found.Add($item.FullName) }
        }
    }
    $executables=@($found | Sort-Object)
    Write-Host '0. No executable (manual sync)'
    for ($i=0; $i -lt $executables.Count; $i++) { Write-Host ('{0}. {1}' -f ($i+1),$executables[$i].Substring($Source.Length+1)) }
    $browseSelection=$executables.Count+1
    Write-Host ("$browseSelection. Browse for an executable...")
    $exe=$null
    while ($null -eq $exe) {
        $selection=-1
        $valid=[int]::TryParse((Read-Host 'Choose an executable number'),[ref]$selection)
        if (-not $valid -or $selection -lt 0 -or $selection -gt $browseSelection) { continue }
        if ($selection -eq 0) { $exe=''; continue }
        if ($selection -le $executables.Count) {
            $exe=$executables[$selection-1].Substring($Source.Length+1)
            continue
        }
        $picked=ChooseExecutable $Source
        if (-not $picked) { Write-Host 'No executable selected; choose another option.'; continue }
        $picked=(Resolve-Path -LiteralPath $picked).ProviderPath
        if ([IO.Path]::GetExtension($picked) -ine '.exe') { Write-Host 'Choose a file with the .exe extension.'; continue }
        $sourcePrefix=$Source+'\'
        $exe=if ($picked.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) { $picked.Substring($sourcePrefix.Length) } else { $picked }
    }
    $delay=10
    while ($true) {
        $value=Read-Host 'Seconds to wait before sync [10]'
        if ([string]::IsNullOrWhiteSpace($value)) { $delay=10; break }
        if ([int]::TryParse($value,[ref]$delay) -and $delay -ge 0) { break }
    }
    # The script location is a comment, never a positional config field.
    $engine=Join-Path $PSScriptRoot 'BackupSync.ps1'
    $lines=@($destination,$exe,[string]$delay,
        '# Optional rules below: + includes, - excludes; no rules means all files.',
        '# Example: +Saves', '# Example: -**/cache/**', '# Example: -*.zip',
        ('# Script: '+$engine))
    [IO.File]::WriteAllLines($config,[string[]]$lines,(New-Object Text.UTF8Encoding($true)))
    $shell=New-Object -ComObject WScript.Shell
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start=Join-Path $PSScriptRoot 'Start-BackupSync.ps1'
    $exePath=if (-not $exe) { $null } elseif ([IO.Path]::IsPathRooted($exe)) { $exe } else { Join-Path $Source $exe }
    foreach ($mode in @('Launcher','Sync only')) {
        $link=$shell.CreateShortcut((Join-Path $Source ($mode+'.backup-sync.lnk')))
        $link.TargetPath=$powershell
        $link.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$start+'" -Source "'+$Source+'"'
        if ($mode -eq 'Sync only') { $link.Arguments+=' -SyncOnly' }
        $link.WorkingDirectory=$Source
        $link.Description=if ($mode -eq 'Launcher') { 'Launch configured application, wait, then synchronize' } else { 'Synchronize now without launching the application' }
        if ($exePath) { $link.IconLocation=$exePath+',0' }
        $link.Save()
    }
    $destinationLink=$shell.CreateShortcut((Join-Path $Source 'Backup folder.backup-sync.lnk'))
    $destinationLink.TargetPath=$destination
    $destinationLink.WorkingDirectory=$destination
    $destinationLink.Description='Open the backup destination folder'
    $destinationLink.Save()
    Write-Host "`nSetup complete: $config`nCreated Launcher.backup-sync.lnk, Sync only.backup-sync.lnk, and Backup folder.backup-sync.lnk in the source."
    Write-Host 'Edit the config to add inclusion/exclusion rules. You may copy either shortcut anywhere.'
    Write-Host 'Use -Preview for a read-only review before the first sync.'
    if (-not $NoExplorer) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('/select,"{0}"' -f $config)
    }
} catch { Write-Host "Setup stopped: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
