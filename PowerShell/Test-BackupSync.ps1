#requires -Version 5.1
# Integration tests use isolated folders under TEMP. No user files are touched.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:Engine=Join-Path $PSScriptRoot 'BackupSync.ps1'
$script:TestRoot=Join-Path $env:TEMP ('BackupSync-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:TestRoot
$script:Passed=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Passed++; Write-Host "PASS: $Message"
}
function Put([string]$Root,[string]$Path,[string]$Value) {
    $p=Join-Path $Root $Path
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force
    [IO.File]::WriteAllText($p,$Value)
}
function Content([string]$Root,[string]$Path) { [IO.File]::ReadAllText((Join-Path $Root $Path)) }
function Pair([string]$Name,[string[]]$Rules=@()) {
    $a=Join-Path $script:TestRoot ($Name+'\source [test]'); $b=Join-Path $script:TestRoot ($Name+'\destination')
    $null=New-Item -ItemType Directory -Path $a,$b -Force
    [IO.File]::WriteAllLines((Join-Path $a 'backup_setup.txt'),[string[]](@($b,'','0')+$Rules))
    @{A=$a; B=$b}
}
function Run($Pair,[string[]]$Answers=@(),[string[]]$Options=@()) {
    $inputText=($Answers -join "`n")+"`n"
    $result=$inputText | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Engine -Source $Pair.A -SyncOnly @Options 2>&1
    @{Code=$LASTEXITCODE; Text=($result -join "`n")}
}
function Good($Result) { if ($Result.Code -ne 0) { throw $Result.Text } }
$p=Pair 'basic'
Put $p.A 'save.txt' 'first'; Put $p.B 'remote.txt' 'remote'
$r=Run $p; Good $r
Assert ((Content $p.B 'save.txt') -eq 'first' -and (Content $p.A 'remote.txt') -eq 'remote') 'First sync merges additions both ways'
Assert ((Content $p.A 'backup_version.txt') -eq (Content $p.B 'backup_version.txt')) 'Both version files are identical'
$r=Run $p; Good $r
Assert ($r.Text.Contains('0 file operations')) 'Unchanged files cause no copies'
Put $p.B 'save.txt' 'remote change'
# Deliberately older timestamp: hashes, not wall-clock time, decide direction.
(Get-Item -LiteralPath (Join-Path $p.B 'save.txt')).LastWriteTimeUtc=[datetime]'2001-01-01'
$r=Run $p; Good $r
Assert ((Content $p.A 'save.txt') -eq 'remote change') 'Destination edit returns to source regardless of timestamp'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $p.A '.backup_sync_recovery') -Recurse -Filter save.txt).Count -gt 0) 'Overwrites retain a recovery copy'
Put $p.A 'save.txt' 'source conflict'; Put $p.B 'save.txt' 'destination conflict'
$r=Run $p @('K'); Good $r
Assert ((Content $p.A 'save.txt') -eq 'source conflict' -and (Content $p.B 'save.txt') -eq 'destination conflict') 'Skipping a conflict preserves both files'
$r=Run $p @('D'); Good $r
Assert ($r.Text.Contains('CONFLICT: save.txt') -and (Content $p.A 'save.txt') -eq 'destination conflict') 'Skipped conflicts prompt again; destination choice works'
Remove-Item -LiteralPath (Join-Path $p.A 'save.txt')
$r=Run $p @('N'); Good $r
Assert (Test-Path -LiteralPath (Join-Path $p.B 'save.txt')) 'Declining a deletion preserves the remaining file'
$r=Run $p @('Y'); Good $r
Assert (-not (Test-Path -LiteralPath (Join-Path $p.B 'save.txt'))) 'Deletion prompts again and propagates only after approval'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $p.B '.backup_sync_recovery') -Recurse -Filter save.txt).Count -gt 0) 'Deleted files have recovery copies'
Put $p.A 'remote.txt' 'edited while remote deleted'; Remove-Item -LiteralPath (Join-Path $p.B 'remote.txt')
$r=Run $p @('S'); Good $r
Assert ($r.Text.Contains('CONFLICT: remote.txt') -and (Content $p.B 'remote.txt') -eq 'edited while remote deleted') 'Edit versus deletion is a conflict and can restore the file'
Put $p.A 'remote.txt' 'left'; Put $p.B 'remote.txt' 'right'
$r=Run $p @('A'); Good $r
Assert ((Content $p.A 'remote.txt') -eq 'left' -and (Content $p.B 'remote.txt') -eq 'right') 'Aborting conflict review performs no file operations'
$r=Run $p @() @('-Preview'); Good $r
Assert ($r.Text.Contains('CONFLICT: remote.txt') -and (Content $p.A 'remote.txt') -eq 'left') 'Preview reports conflicts without prompting or writing'
$q=Pair 'rules' @('+Saves','+*.zip','-Saves/cache','-**/secret?.zip')
Put $q.A 'Saves/good.dat' 'yes'; Put $q.A 'Saves/cache/no.dat' 'no'
Put $q.A 'nested/archive.zip' 'zip'; Put $q.A 'secret1.zip' 'no'; Put $q.A 'other.dat' 'no'
$null=New-Item -ItemType Directory -Path (Join-Path $q.A 'Saves/empty')
$r=Run $q; Good $r
Assert ((Test-Path -LiteralPath (Join-Path $q.B 'Saves/good.dat')) -and (Test-Path -LiteralPath (Join-Path $q.B 'nested/archive.zip'))) 'Includes support directories and basename wildcards at any depth'
Assert (-not (Test-Path -LiteralPath (Join-Path $q.B 'Saves/cache/no.dat')) -and -not (Test-Path -LiteralPath (Join-Path $q.B 'secret1.zip')) -and -not (Test-Path -LiteralPath (Join-Path $q.B 'other.dat'))) 'Exclusions filter includes; double-star and question-mark work'
Assert (Test-Path -LiteralPath (Join-Path $q.B 'Saves/empty') -PathType Container) 'Selected empty folders are created'
$q=Pair 'exclude-only' @('-*.zip')
Put $q.A 'nested/a.zip' 'no'; Put $q.A 'nested/a.txt' 'yes'
$r=Run $q; Good $r
Assert ((Test-Path -LiteralPath (Join-Path $q.B 'nested/a.txt')) -and -not (Test-Path -LiteralPath (Join-Path $q.B 'nested/a.zip'))) 'Exclusion-only config includes all other files'
$q=Pair 'first-conflict'
Put $q.A 'same.txt' 'a'; Put $q.B 'same.txt' 'b'
$r=Run $q @('S'); Good $r
Assert ((Content $q.B 'same.txt') -eq 'a') 'First-run differing files require a source/destination decision'
Remove-Item -LiteralPath (Join-Path $q.B 'backup_version.txt')
$r=Run $q
Assert ($r.Code -ne 0 -and $r.Text.Contains('version file is missing')) 'Missing destination metadata stops safely'
$r=Run $q @('Y') @('-RebuildBaseline'); Good $r
Assert ((Content $q.A 'backup_version.txt') -eq (Content $q.B 'backup_version.txt')) 'Explicit baseline rebuild repairs missing metadata'
# Simulate a second machine with its own last agreed source snapshot and the shared destination.
$q=Pair 'multi-pc'
Put $q.A 'shared.txt' 'initial'; $r=Run $q; Good $r
$c=Join-Path $script:TestRoot 'multi-pc\other-source'; $null=New-Item -ItemType Directory -Path $c
Copy-Item -LiteralPath (Join-Path $q.A 'shared.txt'),(Join-Path $q.A 'backup_version.txt') -Destination $c
[IO.File]::WriteAllLines((Join-Path $c 'backup_setup.txt'),[string[]]@($q.B,'','0'))
Put $q.A 'shared.txt' 'PC A update'; $r=Run $q; Good $r
$r=Run @{A=$c; B=$q.B}; Good $r
Assert ((Content $c 'shared.txt') -eq 'PC A update') 'An older PC snapshot correctly receives changes from another PC'
Put $q.A 'shared.txt' 'A edit'; Put $c 'shared.txt' 'B edit'
$r=Run @{A=$c; B=$q.B}; Good $r
$r=Run $q @('K'); Good $r
Assert ($r.Text.Contains('CONFLICT: shared.txt')) 'Independent edits on two PCs produce a conflict'
$q=Pair 'restore-choice'
Put $q.A 'restore.txt' 'keep me'; $r=Run $q; Good $r
Remove-Item -LiteralPath (Join-Path $q.A 'restore.txt')
$r=Run $q @('R'); Good $r
Assert ((Content $q.A 'restore.txt') -eq 'keep me') 'Deletion review can restore a missing source file'
Remove-Item -LiteralPath (Join-Path $q.B 'restore.txt')
$r=Run $q @('R'); Good $r
Assert ((Content $q.B 'restore.txt') -eq 'keep me') 'Deletion review can restore a missing destination file'
$previewPair=Pair 'preview-readonly'
Put $previewPair.A 'new.txt' 'preview'
$r=Run $previewPair @() @('-Preview'); Good $r
Assert (-not (Test-Path -LiteralPath (Join-Path $previewPair.B 'new.txt')) -and -not (Test-Path -LiteralPath (Join-Path $previewPair.A 'backup_version.txt')) -and -not (Test-Path -LiteralPath (Join-Path $previewPair.A '.backup_sync.lock'))) 'Preview creates no files or locks'
Put $q.A 'backup_version.txt' 'invalid JSON'
$r=Run $q
Assert ($r.Code -ne 0) 'Malformed metadata stops normal sync'
$r=Run $q @('Y') @('-RebuildBaseline'); Good $r
Assert ((Content $q.A 'backup_version.txt') -eq (Content $q.B 'backup_version.txt')) 'Rebuild repairs malformed metadata'
$missing=Join-Path $script:TestRoot 'offline-source'; $null=New-Item -ItemType Directory -Path $missing
$notThere=Join-Path $script:TestRoot 'offline-destination'
[IO.File]::WriteAllLines((Join-Path $missing 'backup_setup.txt'),[string[]]@($notThere,'','0'))
$r=Run @{A=$missing; B=$notThere}
Assert ($r.Code -ne 0 -and -not (Test-Path -LiteralPath $notThere)) 'Unavailable destination stops without creating a false backup'
$lock=[IO.File]::Open((Join-Path $q.A '.backup_sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { $r=Run $q; Assert ($r.Code -ne 0) 'Concurrent runs are blocked by the source lock' } finally { $lock.Dispose() }
# Run setup with deterministic answers, replacing only the folder picker and Read-Host.
$setupPair=Pair 'setup'
Remove-Item -LiteralPath (Join-Path $setupPair.A 'backup_setup.txt')
$setupCode=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Setup-BackupSync.ps1') -Raw
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($setupCode,[ref]$tokens,[ref]$parseErrors)
$picker=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ChooseFolder'},$true)
$setupCode=$setupCode.Replace($picker.Extent.Text,'function ChooseFolder([string]$Title) { return $script:FixtureDestination }')
$fakeSetup=Join-Path $PSScriptRoot '.Test-SetupFixture.ps1'
$prefix='$script:FixtureDestination='''+$setupPair.B.Replace("'","''")+''''+"`r`n"+
    'function Read-Host { param([string]$Prompt) if ($Prompt -like ''Choose an executable*'') { return ''0'' } else { return '''' } }'+"`r`n"
$setupCode=$setupCode.Replace('Set-StrictMode -Version Latest',$prefix+'Set-StrictMode -Version Latest')
try {
    [IO.File]::WriteAllText($fakeSetup,$setupCode,(New-Object Text.UTF8Encoding($true)))
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fakeSetup -Source $setupPair.A -NoExplorer 2>&1
    Assert ($LASTEXITCODE -eq 0) ('Setup wizard core creates config and shortcuts: '+($output -join ' '))
    $cfg=@(Get-Content -LiteralPath (Join-Path $setupPair.A 'backup_setup.txt'))
    Assert ($cfg[0] -eq $setupPair.B -and $cfg[1] -eq '' -and $cfg[2] -eq '10') 'Setup writes manual mode and the default delay in correct slots'
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut((Join-Path $setupPair.A 'Sync only.backup-sync.lnk'))
    Assert ($shortcut.Arguments.Contains('-Source "'+$setupPair.A+'"') -and $shortcut.Arguments.EndsWith('-SyncOnly')) 'Generated shortcut passes the quoted source and manual mode'
    $destinationShortcut=$shell.CreateShortcut((Join-Path $setupPair.A 'Backup folder.backup-sync.lnk'))
    Assert ($destinationShortcut.TargetPath -eq $setupPair.B) 'Generated backup-folder shortcut targets the selected destination'
} finally { if (Test-Path -LiteralPath $fakeSetup) { Remove-Item -LiteralPath $fakeSetup -Force } }
$browsePair=Pair 'setup-browse'
Remove-Item -LiteralPath (Join-Path $browsePair.A 'backup_setup.txt')
$pickedExe=Join-Path $script:TestRoot 'manually-picked.exe'
[IO.File]::WriteAllText($pickedExe,'fixture only')
$setupCode=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Setup-BackupSync.ps1') -Raw
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($setupCode,[ref]$tokens,[ref]$parseErrors)
$folderPicker=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ChooseFolder'},$true)
$exePicker=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ChooseExecutable'},$true)
$setupCode=$setupCode.Replace($folderPicker.Extent.Text,'function ChooseFolder([string]$Title) { return $script:FixtureDestination }')
$setupCode=$setupCode.Replace($exePicker.Extent.Text,'function ChooseExecutable([string]$InitialDirectory) { return $script:FixtureExecutable }')
$fakeSetup=Join-Path $PSScriptRoot '.Test-SetupBrowseFixture.ps1'
$prefix='$script:FixtureDestination='''+$browsePair.B.Replace("'","''")+''''+"`r`n"+
    '$script:FixtureExecutable='''+$pickedExe.Replace("'","''")+''''+"`r`n"+
    'function Read-Host { param([string]$Prompt) if ($Prompt -like ''Choose an executable*'') { return ''1'' } else { return '''' } }'+"`r`n"
$setupCode=$setupCode.Replace('Set-StrictMode -Version Latest',$prefix+'Set-StrictMode -Version Latest')
try {
    [IO.File]::WriteAllText($fakeSetup,$setupCode,(New-Object Text.UTF8Encoding($true)))
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fakeSetup -Source $browsePair.A -NoExplorer 2>&1
    Assert ($LASTEXITCODE -eq 0) ('Setup accepts a manually browsed executable: '+($output -join ' '))
    $cfg=@(Get-Content -LiteralPath (Join-Path $browsePair.A 'backup_setup.txt'))
    $shell=New-Object -ComObject WScript.Shell
    $launcher=$shell.CreateShortcut((Join-Path $browsePair.A 'Launcher.backup-sync.lnk'))
    $syncOnly=$shell.CreateShortcut((Join-Path $browsePair.A 'Sync only.backup-sync.lnk'))
    Assert ($cfg[1] -eq $pickedExe -and $launcher.IconLocation.StartsWith($pickedExe) -and $syncOnly.IconLocation.StartsWith($pickedExe)) 'Manual picker stores an external EXE and applies its icon to both action shortcuts'
} finally { if (Test-Path -LiteralPath $fakeSetup) { Remove-Item -LiteralPath $fakeSetup -Force } }
$unicodeName=([string][char]0x017C)+([string][char]0x4E2D)+'.txt'
$unicodePair=Pair ('unicode-'+[char]0x0141)
Put $unicodePair.A $unicodeName 'unicode first'; $r=Run $unicodePair; Good $r
Put $unicodePair.B $unicodeName 'unicode update'; $r=Run $unicodePair; Good $r
Assert ((Content $unicodePair.A $unicodeName) -eq 'unicode update') 'UTF-8 config and metadata preserve non-ASCII folder and file names'
# Wrapper must preserve switch arguments through Windows PowerShell 5.1.
$out=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Start-BackupSync.ps1') -Source $q.A -Preview 2>&1
Assert ($LASTEXITCODE -eq 0 -and ($out -join "`n").Contains('Preview only')) 'Launcher wrapper forwards switches correctly'
$launcherPair=Pair 'launcher-pre-post'
$quickExe=Join-Path $env:SystemRoot 'System32\where.exe'
[IO.File]::WriteAllLines((Join-Path $launcherPair.A 'backup_setup.txt'),[string[]]@($launcherPair.B,$quickExe,'0'))
Put $launcherPair.B 'remote-before-launch.txt' 'download first'
$out=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Start-BackupSync.ps1') -Source $launcherPair.A 2>&1
Assert ($LASTEXITCODE -eq 0 -and (Content $launcherPair.A 'remote-before-launch.txt') -eq 'download first' -and (@($out | Select-String 'Sync complete').Count -eq 2)) 'Launcher synchronizes before and after the configured executable'
$offlineLauncher=Join-Path $script:TestRoot 'launcher-offline\source'; $null=New-Item -ItemType Directory -Path $offlineLauncher -Force
$offlineDestination=Join-Path $script:TestRoot 'launcher-offline\missing-destination'
[IO.File]::WriteAllLines((Join-Path $offlineLauncher 'backup_setup.txt'),[string[]]@($offlineDestination,$quickExe,'0'))
$out="`n" | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Start-BackupSync.ps1') -Source $offlineLauncher 2>&1
Assert ($LASTEXITCODE -eq 2 -and ($out -join "`n").Contains('Launching the application without a pre-launch sync') -and ($out -join "`n").Contains('Application closed. Synchronizing changes')) 'Launcher continues while offline and waits after closing for retry or Enter'
Write-Host "`n$script:Passed checks passed. Fixtures retained at $script:TestRoot"


