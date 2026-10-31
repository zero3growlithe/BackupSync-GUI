# BackupSync GUI

A small WPF desktop front-end for the [BackupSync](PowerShell/README.md) PowerShell utility.
It shows every configured backup pair, launches or syncs them, and creates new
configurations with the same questions the original setup script asks — plus an
editor for the selection rules.

The PowerShell engine is bundled unchanged inside [PowerShell](PowerShell). All file
copying, hashing, locking, conflict handling and recovery is still done by those scripts;
the GUI only configures, monitors and starts them.

## What it does

* **List of configured backups** — one row per source folder, with the icon of the
  configured application (or of the launcher shortcut), the destination folder, the
  delay and the number of selection rules.
* **Double-click a row** to run the generated `Launcher.backup-sync.lnk`. If the source
  folder has no launcher shortcut, the sync runs on its own instead.
* **Sync now** runs a sync pass for the selected pair, **Sync all** walks the whole list
  one configuration at a time.
* **F5 refreshes the list** — every source, destination and configuration file is re-checked,
  so a drive that was connected or disconnected while the window stayed open is reflected
  immediately.
* **Open source folder** / **Open destination folder** open the pair's folders in Explorer.
* **Add configuration** asks the same questions as `Setup-BackupSync.ps1`: source folder,
  destination folder, application to launch, delay before the second sync and the
  selection rules. It writes the same `backup_setup.txt` (UTF-8 with BOM, CRLF) and creates
  the same three shortcuts, so the result is interchangeable with the script.
* **Existing configuration detected** — when the chosen source folder already contains
  `backup_setup.txt`, the wizard offers to either add that configuration to the list
  without touching it, or to configure it again and overwrite it (the old file is kept as
  `backup_setup.txt.<timestamp>.bak`, exactly like the script does).
* **Selection rule editor** — a plain text editor with Undo/Redo buttons and
  `Ctrl+Z`, `Ctrl+Y`, `Ctrl+S`. Rules are validated with the same rules the engine uses
  before anything is written.
* **Destination initialization** — when the destination carries `backup_init.txt` and the
  source has no `backup_version.txt`, the wizard offers the script's opt-in initialization
  and asks what to do about differing files (use destination / keep source / abort).
* **Remove from list** — optionally deletes the files this tool leaves in the source folder
  (the three `*.backup-sync.lnk` shortcuts) and optionally the `backup_setup.txt` itself;
  both choices are explicit checkboxes.

## Requirements

* Windows 10 or 11, x64.
* Windows PowerShell 5.1 (part of Windows). No extra modules, no administrator rights.
* The .NET 8 desktop runtime if you use the framework-dependent build, or nothing at all
  for the self-contained one.

## Running

Unpack the artifact anywhere and start `BackupSyncGui.exe`. The `PowerShell` folder with
the scripts must sit beside the executable — the release zip already has that layout.
If it is missing, the app asks for the script folder once and remembers it
(`%LOCALAPPDATA%\BackupSyncGui\settings.json`).

The list itself lives in `%LOCALAPPDATA%\BackupSyncGui\configurations.json`; the per-folder
state that matters (`backup_setup.txt`, `backup_version.txt`, shortcuts) stays where it
always was, inside the source and destination folders.

Unhandled errors are appended to `%LOCALAPPDATA%\BackupSyncGui\crash.log` together with the
build SHA shown in the window title, so a report can be matched to a CI artifact.

## Building

The repository builds with the .NET 8 SDK for Windows:

```powershell
dotnet build src\BackupSyncGui\BackupSyncGui.csproj -c Release
dotnet publish src\BackupSyncGui\BackupSyncGui.csproj -c Release -r win-x64 --self-contained false -o publish
```

`dotnet publish` copies the `PowerShell` folder next to the executable. CI runs the same
commands on `windows-latest` and uploads `BackupSyncGui-win-x64.zip` as an artifact named
`BackupSyncGui-win-x64`.

## Notes and limitations

* A sync run opens its own console window on purpose: the engine asks questions when it
  finds conflicting files, and those prompts need a real console.
* The GUI is a thin layer. It does not re-implement any sync logic, so behaviour, safety
  checks and recovery semantics are exactly those documented in
  [the PowerShell README](PowerShell/README.md).
* The list only contains folders you added through this app or through the wizard; it is
  not a filesystem scan for `backup_setup.txt`. Point **Add configuration** at an existing
  source folder and choose *add it to the list* to bring an older configuration in.
