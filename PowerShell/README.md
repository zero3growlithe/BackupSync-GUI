# BackupSync for Windows

A single shared PowerShell utility, with per-folder settings and movable Windows shortcuts.
Requires Windows PowerShell 5.1 (included with Windows) and writable filesystem folders.
No Python, extra modules, scheduler, or administrator rights are required.

## Quick start

1. Keep this entire utility folder in one stable location. A UNC network path works, provided that share is available when you launch it.
2. Double-click `Setup-BackupSync.cmd`. Alternatively pass a source folder:
   `Setup-BackupSync.cmd "D:\Games\Example"`
3. Browse for the source and a dedicated destination folder, choose an executable from the numbered list or its **Browse** option (0 for none), and choose a delay (default 10 seconds).
4. Edit `backup_setup.txt` in the source to add selection rules, if needed.
5. Setup opens the source folder with `backup_setup.txt` selected. Double-click `Launcher.backup-sync.lnk` to sync, launch the app, and sync again after it closes. `Sync only.backup-sync.lnk` syncs without launching, and `Backup folder.backup-sync.lnk` opens the selected destination. Copy any shortcut to your desktop or anywhere else.

The action shortcuts point to the one central script and pass the source as an explicit argument. When an executable is selected, both action shortcuts use its icon. Their location and your current working directory do not determine what gets synced. Moving the central utility folder requires recreating the shortcuts.

For a read-only first review, run in PowerShell:

```powershell
& '\\server\share\BackupSync\Start-BackupSync.ps1' -Source 'D:\Games\Example' -Preview
```

For manual sync:

```powershell
& '\\server\share\BackupSync\Start-BackupSync.ps1' -Source 'D:\Games\Example' -SyncOnly
```

Use your actual central script path in these commands. `Start-BackupSync.ps1` keeps the window open on errors and closes automatically on success. `BackupSync.ps1` is the engine for terminal use and automation; it returns exit code 1 on failure. Declining, skipping or intentionally aborting a review returns 0. There is no completion pause.

## Initialize a new source from the destination

Put `backup_init.txt` in the destination folder. It contains only selection rules, for example:

```text
+bin
+Saves
+*.ini
-**/cache/**
-*.tmp
```

When you run `Setup-BackupSync.cmd` and select that destination, setup offers to initialize the source if the source has no `backup_version.txt`. Accepting copies matching files and selected empty folders **from destination to source**, before the executable selection list is built. Newly copied executables can therefore be selected as launchers. Declining continues ordinary setup. If either condition is absent, no initialization prompt appears.

The `+`, `-`, `*`, `?`, and `**` semantics are the same as normal sync. Blank lines and `#` comments are supported, with no destination, executable or delay lines. No `+` rules means include everything except exclusions; an empty file selects all ordinary files.

Initialization never deletes source-only files. If a matching existing source file has different content, choose destination, keep source, or abort setup. Destination replacements keep a recovery copy of the previous source file. Conflict choices are collected before copies begin, so aborting review leaves user files untouched. Both roots are locked during initialization and copy hashes are checked, just as in normal sync.

The destination's `backup_version.txt`, `backup_setup.txt`, and `backup_init.txt` are not copied. Initialization does not create a version baseline: the first normal sync establishes it using `backup_setup.txt`. Initialization rules and normal sync rules are independent; edit the new `backup_setup.txt` if you also want to restrict future syncs. `backup_init.txt` remains at the destination and is always excluded from normal sync. The prompt belongs to the setup wizard, not the regular launcher. If setup is repeated before the first normal sync, the missing source version file can trigger the offer again.

Keep `BackupSync.Common.ps1` alongside the setup and sync scripts; they share the filtering and verified-copy functions in that file.

## backup_setup.txt

Example:

```text
E:\Backups\Example
Example.exe
10
+Saves
+Profiles
+*.zip
-Saves/cache
-**/temp/**
-*.log
# Script: \\server\share\BackupSync\BackupSync.ps1
```

- Line 1: destination folder. An absolute path or UNC path is recommended; relative paths resolve from the source. Environment variables such as `%USERPROFILE%` expand.
- Line 2: optional executable path, relative to the source or absolute. Leave blank for manual sync. Do not put arguments or an entire command here.
- Line 3: optional nonnegative delay in seconds. Blank or omitted means 10. Applies before scanning even in manual mode. Preview skips it.
- Remaining lines: `+` includes and `-` excludes. Blank lines and `#` comments are accepted after the positional settings.

When omitting the executable but supplying a delay, keep an empty second line. Rules may start immediately after the destination or executable if later settings are omitted. To omit both optional settings, rules can begin on line 2. The wizard always writes both slots, avoiding ambiguity. A script path belongs in a `# Script:` comment, not a positional line. Only an actual shortcut or command launches the script; the text file is configuration.

Selection rules apply identically in both directions:

- No `+` lines: include all files, then remove exclusions.
- With `+` lines: include only those matches, then remove exclusions within them.
- `Saves` selects any directory/file named Saves and its descendants, anywhere in the tree.
- `Saves/*.dat` matches DAT files directly inside root Saves (and descendants of a matching directory).
- `*.zip` matches ZIP files at every depth; `?` matches one character.
- `**` spans directories. `**/cache/**` matches cache contents at any depth, including root cache.
- Rules containing `/` are anchored at the source/destination root. Use `/` or `\` as separators. Matching is case insensitive. These are glob rules, not regular expressions; character classes such as `[ab]` are not supported.

The setup, initialization and version files at each root, recovery directories, lock files, temporary sync files and generated `*.backup-sync.lnk` shortcuts are always excluded. Other files, including executables, are synced unless excluded by your rules.

## How changes and conflicts are detected

`backup_version.txt` is JSON despite its .txt extension. It stores SHA-256 hashes of the last agreed files, a sync ID, generation, UTC audit time, and a map of computer names to sync counters. Do not edit it manually. Hash snapshots determine changes; computer counters alone cannot distinguish editing from deletion, and timestamps can be misleading across computers.

| Source versus baseline | Destination versus baseline | Result |
| --- | --- | --- |
| Same | Same | No file operation |
| Changed | Same | Copy source to destination |
| Same | Changed | Copy destination to source |
| Changed identically | Changed identically | Accept identical content |
| Changed differently | Changed differently | Ask source / destination / skip / abort |
| Missing | Unchanged | Ask delete destination / restore source / skip / abort |
| Unchanged | Missing | Ask delete source / restore destination / skip / abort |
| Edited | Missing (or vice versa) | Conflict; ask which side to use |

The first sync has no baseline: files on only one side are added to the other, with no inferred deletions; different contents at the same path prompt. Choosing a missing side in a conflict still requires separate deletion approval. All choices are collected before changing user files. Abort during review leaves user files untouched. A skipped conflict or declined deletion retains its previous baseline and is reconsidered next time.

For multiple PCs, each source retains its last agreed snapshot. It can detect edits that another computer has uploaded to the shared destination since its own last sync. A new source without metadata conservatively merges with the existing destination, without inferring deletions. Use the same destination for one logical set of files. Each source folder belongs to one sync set.

If destination metadata disappears or pair IDs disagree, the script stops. Check that the intended drive/share is connected. To intentionally merge current contents again without inferring deletions:

```powershell
& '\\server\share\BackupSync\Start-BackupSync.ps1' -Source 'D:\Games\Example' -SyncOnly -RebuildBaseline
```

Rebuild asks for confirmation, treats unmatched files as additions and prompts on differing contents. It also recovers from malformed metadata. It does not select an authoritative side or silently delete unmatched files. Rebuilding creates a new sync ID; other PCs from the previous sync set must also rebuild conservatively before joining it again.

## Recovery and operational details

Before an overwrite or approved deletion, the previous file is copied to `.backup_sync_recovery\<timestamp-id>\<original-relative-path>` on that same side. Copy hashes are verified. Old version files are retained there too. To restore, copy a recovery file to its original location and run sync, reviewing any conflict. Recovery copies are never automatically deleted; clean up old recovery folders manually when you no longer need them. Keep additional offline backups for disk loss.

Copies are staged in the target directory and replaced using Windows file replacement. If the filesystem/share does not support replacement, sync stops with the original target preserved. A full sync is not a transaction: failure can leave already completed file operations in place. Re-running reconciles remaining differences; inspect both sides after an interrupted metadata update and rebuild if needed.

Both roots are locked against concurrent runs of this utility during each sync phase. Ordinary apps do not honor these locks. The script rechecks file hashes after review and before replacements, but cannot provide a filesystem snapshot or eliminate every race with a live writer. Close other writers and avoid simultaneous edits during sync. The destination must already exist; the wizard's folder picker can create a dedicated folder. An offline destination stops a Sync-only run, but the launcher logs the problem and still opens the application.

The launcher first synchronizes pending changes so updates from another computer are available before the application starts. It then waits for the newly launched application, or existing processes with the exact configured executable path, and performs another sync after the configured delay. Launchers that delegate work to unrelated services or detached processes may need the actual application EXE selected instead. If the destination is unavailable before launch, the application still opens; after it closes, the launcher tries again and waits for Enter to close or `R` to retry while the destination remains unavailable.

Selected empty directories are created on both sides. Empty directories are never deleted automatically. File renames are handled as an addition plus a separately approved deletion. File-versus-directory collisions stop safely for manual review. Links, junctions and other reparse points anywhere under the scanned roots stop sync; do not use this utility on trees containing those (including cloud placeholder files). It synchronizes ordinary file contents, not NTFS permissions, alternate data streams or filesystem snapshots. SHA-256 scanning reads all selected file contents each run.

Preview is read-only and does not acquire locks, launch the application, sleep, create directories, or update metadata. It can be run while another operation is active, but its results are only a view of what was readable during the scan.

## Verification

`Test-BackupSync.ps1` runs integration checks in newly created TEMP folders under Windows PowerShell 5.1. It covers two-way copying, clock differences, recovery, repeat conflicts, deletion approval, edit/delete conflicts, wildcard rules, empty folders, metadata recovery, multiple-PC histories, and wrapper argument forwarding. Test fixtures remain in TEMP for inspection.


`Test-Initialization.ps1` adds initialization checks for filtering, opt-in, existing versions, conflicts, recovery, aborting, metadata exclusion, executable discovery after copying, and the first normal sync. Its setup integration check substitutes the interactive folder picker and answers while exercising actual config/shortcut creation.
