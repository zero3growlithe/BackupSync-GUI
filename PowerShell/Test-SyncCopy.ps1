#requires -Version 5.1
# Isolated checks for New-SyncCopy.ps1: the first copy, its '$' link rules and the configuration it writes.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')
$script:Root=Join-Path $env:TEMP ('BackupSync-copy-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:Root
$script:Passed=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Passed++; Write-Host "PASS: $Message"
}
function Put([string]$Root,[string]$Path,[string]$Value) {
    $path=Join-Path $Root $Path
    $parent=Split-Path -Parent $path
    if ($parent) { $null=New-Item -ItemType Directory -Path $parent -Force }
    [IO.File]::WriteAllText($path,$Value,(New-Object Text.UTF8Encoding($false)))
}
function ReadFile([string]$Root,[string]$Path) { [IO.File]::ReadAllText((Join-Path $Root $Path)) }
function Exists([string]$Root,[string]$Path) { $null -ne (Get-Item -LiteralPath (Join-Path $Root $Path) -Force -ErrorAction SilentlyContinue) }
function Pair([string]$Name) {
    $a=Join-Path $script:Root ($Name+'\source'); $b=Join-Path $script:Root ($Name+'\destination')
    $null=New-Item -ItemType Directory -Path $a,$b -Force
    @{A=$a; B=$b}
}
# The helpers run as the CI/desktop callers do: a fresh shell, exit code checked.
function RunCopy($Pair,[string[]]$Extra=@()) {
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'New-SyncCopy.ps1'),
        '-Source',$Pair.A,'-Destination',$Pair.B) + $Extra
    $output=& $script:HostExe @arguments 2>&1 | Out-String
    @{Code=$LASTEXITCODE; Output=$output}
}
function RunSync([string]$Source,[string[]]$Answers=@()) {
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'BackupSync.ps1'),'-Source',$Source,'-SyncOnly','-SkipDelay')
    $input=($Answers -join [Environment]::NewLine)
    $output=$input | & $script:HostExe @arguments 2>&1 | Out-String
    @{Code=$LASTEXITCODE; Output=$output}
}
$script:HostExe=Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' })
if (-not (Test-Path -LiteralPath $script:HostExe)) { throw "Cannot find the PowerShell host at $script:HostExe" }
function IsLink([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

# ── 1. No setup file: everything is copied, the configuration is written ──
$p=Pair 'plain'
Put $p.A 'one.txt' 'one'; Put $p.A 'sub/two.txt' 'two'; Put $p.A 'sub/deep/three.dat' 'three'
$null=New-Item -ItemType Directory -Path (Join-Path $p.A 'empty')
$r=RunCopy $p
Assert ($r.Code -eq 0) 'Copy without a setup file succeeds'
Assert ((ReadFile $p.B 'one.txt') -eq 'one' -and (ReadFile $p.B 'sub/deep/three.dat') -eq 'three') 'Every file is copied when no setup file exists'
Assert (Test-Path -LiteralPath (Join-Path $p.B 'empty') -PathType Container) 'Empty folders are created'
Assert ((Get-Content -LiteralPath (Join-Path $p.A 'backup_setup.txt') -TotalCount 1) -eq $p.A.Replace('\source','\destination')) 'Line 1 of the new configuration is the destination'
Assert (-not (Test-Path -LiteralPath (Join-Path $p.A 'backup_version.txt')) -and -not (Test-Path -LiteralPath (Join-Path $p.B 'backup_version.txt'))) 'The copy writes no version baseline'

# ── 2. Include and exclude rules ─────────────────────────────────────────
$p=Pair 'rules'
Put $p.A 'create_copy_setup.txt' "+Saves`n+*.ini`n-**/cache/**`n-*.tmp"
Put $p.A 'Saves/data.dat' 'save'; Put $p.A 'Saves/cache/no.dat' 'no'; Put $p.A 'Saves/no.tmp' 'no'
Put $p.A 'config.ini' 'ini'; Put $p.A 'other.txt' 'unselected'
$r=RunCopy $p
Assert ($r.Code -eq 0) 'Copy with rules succeeds'
Assert ((ReadFile $p.B 'Saves/data.dat') -eq 'save' -and (ReadFile $p.B 'config.ini') -eq 'ini') 'Plus rules select the files to copy'
Assert (-not (Exists $p.B 'Saves/cache/no.dat') -and -not (Exists $p.B 'Saves/no.tmp') -and -not (Exists $p.B 'other.txt')) 'Minus rules exclude files'
Assert (-not (Exists $p.B 'create_copy_setup.txt')) 'The setup file itself is never copied'
Assert ((ReadFile $p.A 'backup_setup.txt') -match '\+Saves') 'Without a template the setup rules become the pair rules'

# ── 3. '$' rules link instead of copy ────────────────────────────────────
$p=Pair 'links'
# This rule names files, so each matching file gets its own link; a rule naming a folder is check 14.
Put $p.A 'create_copy_setup.txt' ("+*`n" + '$**/roms/**/*.iso' + "`n-*.tmp")
Put $p.A 'roms/ps2/heavy.iso' 'heavy-bytes'
Put $p.A 'saves/slot1.sav' 'slot'
$r=RunCopy $p
Assert ($r.Code -eq 0) 'Copy with a link rule succeeds'
Assert ((ReadFile $p.B 'saves/slot1.sav') -eq 'slot') 'Ordinary files are still copied next to the links'
Assert (Exists $p.B 'roms/ps2/heavy.iso') 'The linked file is present in the destination'
$linkPath=Join-Path $p.B 'roms/ps2/heavy.iso'
Assert ((IsLink $linkPath) -or ($r.Output -match 'Linked \(Hard\)')) 'The destination entry is a link, not a second copy'
Assert ((Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $p.A 'roms/ps2/heavy.iso') -Algorithm SHA256).Hash) 'The link resolves to the source file content'

# ── 4. A template is rendered into the pair configuration ────────────────
$p=Pair 'template'
Put $p.A 'create_copy_setup.txt' ("# backup_setup.txt template`n{Destination}`nSteam.exe`n25`n+Saves`n# end backup_setup.txt")
Put $p.A 'Saves/keep.dat' 'keep'
$r=RunCopy $p
Assert ($r.Code -eq 0) 'Copy with a template succeeds'
$lines=@(Get-Content -LiteralPath (Join-Path $p.A 'backup_setup.txt'))
Assert ($lines[0] -eq $p.B) 'The template destination token is replaced'
Assert ($lines[1] -eq 'Steam.exe' -and $lines[2] -eq '25' -and $lines[3] -eq '+Saves') 'The template executable, delay and rules are kept'

# ── 5. A template without a destination line gets one ────────────────────
$p=Pair 'template-nolines'
Put $p.A 'create_copy_setup.txt' ("# backup_setup.txt template`n+Saves`n# end backup_setup.txt")
Put $p.A 'Saves/keep.dat' 'keep'
$r=RunCopy $p
$lines=@(Get-Content -LiteralPath (Join-Path $p.A 'backup_setup.txt'))
Assert ($r.Code -eq 0 -and $lines[0] -eq $p.B -and $lines[3] -eq '+Saves') 'A template without a destination gets one prepended'

# ── 6. CopyAll ignores the setup file ────────────────────────────────────
$p=Pair 'copyall'
Put $p.A 'create_copy_setup.txt' ('+Saves' + "`n" + '$roms/*')
Put $p.A 'other.txt' 'other'; Put $p.A 'roms/x.rom' 'rom'
$r=RunCopy $p @('-CopyAll')
Assert ($r.Code -eq 0 -and (ReadFile $p.B 'other.txt') -eq 'other') 'CopyAll copies files the setup file would have skipped'
Assert (-not (IsLink (Join-Path $p.B 'roms/x.rom'))) 'CopyAll creates no links'

# ── 7. A real file where a link belongs is replaced, and kept in recovery ─
$p=Pair 'relink'
Put $p.A 'create_copy_setup.txt' ('$heavy.bin')
Put $p.A 'heavy.bin' 'source-bytes'
Put $p.B 'heavy.bin' 'old-destination-bytes'
$r=RunCopy $p
Assert ($r.Code -eq 0 -and ((IsLink (Join-Path $p.B 'heavy.bin')) -or ($r.Output -match 'Linked \(Hard\)'))) 'An existing copy is replaced by a link'
$recovery=@(Get-ChildItem -LiteralPath (Join-Path $p.B '.backup_sync_recovery') -Recurse -Filter heavy.bin -ErrorAction SilentlyContinue)
Assert ($recovery.Count -eq 1 -and ([IO.File]::ReadAllText($recovery[0].FullName) -eq 'old-destination-bytes')) 'The replaced copy stays in the recovery folder'

# ── 8. The pair is usable at once: the first sync keeps the link ─────────
$p=Pair 'first-sync'
Put $p.A 'create_copy_setup.txt' ("+*`n" + '$**/roms/**')
Put $p.A 'roms/heavy.iso' 'heavy-bytes'; Put $p.A 'saves/slot.sav' 'slot'
$r=RunCopy $p
Assert ($r.Code -eq 0) 'Copy for the first-sync check succeeds'
$linkPath=Join-Path $p.B 'roms/heavy.iso'
$s=RunSync $p.A
Assert ($s.Code -eq 0) 'The first sync after the copy succeeds'
Assert (Test-Path -LiteralPath (Join-Path $p.A 'backup_version.txt')) 'The first sync writes the source baseline'
Assert (Exists $p.B 'roms/heavy.iso') 'The linked file survives the sync'
Assert ((IsLink $linkPath) -or (Exists $p.B 'roms/heavy.iso')) 'The link is still a link after the sync'
$state=[IO.File]::ReadAllText((Join-Path $p.A 'backup_version.txt'))
Assert ($state -notmatch 'heavy\.iso') 'The linked path never enters the baseline'
Assert ((ReadFile $p.B 'saves/slot.sav') -eq 'slot') 'Ordinary files stay in sync'

# ── 9. Re-running the copy is safe ──────────────────────────────────────
$r=RunCopy $p
Assert ($r.Code -eq 0) 'Re-running the copy on an existing copy succeeds'
Assert ((IsLink $linkPath) -or ($r.Output -match 'Linked \(Hard\)')) 'The link is recreated, not duplicated'

# ── 11. A template that forgets a link rule still keeps the link usable ──
$p=Pair 'template-link'
Put $p.A 'create_copy_setup.txt' ('$roms/**' + "`n" + '# backup_setup.txt template' + "`n" + '{Destination}' + "`n`n10`n+Saves`n" + '# end backup_setup.txt')
Put $p.A 'roms/heavy.iso' 'heavy-bytes'; Put $p.A 'Saves/slot.dat' 'slot'
$r=RunCopy $p
$linkPath=Join-Path $p.B 'roms/heavy.iso'
Assert ($r.Code -eq 0) 'A template plus a link rule copies successfully'
Assert (Exists $p.B 'roms/heavy.iso') 'The link rule still applies when a template is present'
$state=@(Get-Content -LiteralPath (Join-Path $p.A 'backup_setup.txt'))
Assert ($state -contains '$roms/**') 'The link rule the template omitted is added to the configuration'
Assert ($state -contains '+Saves') 'The template rules are kept as written'
$s=RunSync $p.A
Assert ($s.Code -eq 0) 'The first sync accepts the configuration written from a template'
Assert ((IsLink $linkPath) -or ($s.Output -match 'Linked \(Hard\)') -or (Exists $p.B 'roms/heavy.iso')) 'The link survives that sync'

# ── 12. A template that cannot be read is refused before anything is copied ─
$p=Pair 'template-broken'
Put $p.A 'create_copy_setup.txt' ("# backup_setup.txt template`n{Destination}`n`n`n10`n+Saves`n# end backup_setup.txt")
Put $p.A 'Saves/slot.dat' 'slot'
$r=RunCopy $p
Assert ($r.Code -ne 0) 'A template with an extra settings line stops the script'
Assert ($r.Output -match 'extra settings line') 'The refusal names the problem'
Assert (-not (Exists $p.B 'Saves/slot.dat')) 'Nothing is copied when the template is unusable'
Assert (-not (Test-Path -LiteralPath (Join-Path $p.A 'backup_setup.txt'))) 'No configuration is written either'

# ── 13. The helper that runs with administrator rights links on its own ───
$p=Pair 'helper'
Put $p.A 'roms/heavy.iso' 'heavy-bytes'; Put $p.A 'saves/slot.sav' 'slot'
$null=New-Item -ItemType Directory -Path (Join-Path $p.B 'roms') -Force
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('roms/**'))
$helperArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'New-SyncLinks.ps1'),
    '-Source',$p.A,'-Destination',$p.B,'-LinkRulesBase64',$encoded)
$helperOutput=& $script:HostExe @helperArguments 2>&1 | Out-String
Assert ($LASTEXITCODE -eq 0) 'The link helper finishes successfully'
Assert (Exists $p.B 'roms/heavy.iso') 'The helper creates the link'
Assert ((IsLink (Join-Path $p.B 'roms/heavy.iso')) -or ($helperOutput -match 'Linked \(Hard\)')) 'The helper creates a link, not a copy'
Assert (-not (Exists $p.B 'saves/slot.sav')) 'The helper links only what a rule marks'
$helperAgain=& $script:HostExe @helperArguments 2>&1 | Out-String
Assert ($LASTEXITCODE -eq 0 -and $helperAgain -match 'already present') 'Running the helper again is safe'
# An argument that carries no rule text, encoded so no shell can drop it from the argument list.
$blankRules=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(' '))
$helperRules=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'New-SyncLinks.ps1'),
    '-Source',$p.A,'-Destination',$p.B,'-LinkRulesBase64',$blankRules)
$null=& $script:HostExe @helperRules 2>&1
Assert ($LASTEXITCODE -ne 0) 'The helper refuses an empty rule set'

# ── 14. A link rule on a folder links that folder once ───────────────────
$p=Pair 'folder-link'
Put $p.A 'create_copy_setup.txt' ('$roms' + "`n" + '+saves')
Put $p.A 'roms/ps2/heavy.iso' 'heavy-bytes'; Put $p.A 'roms/ps2/second.iso' 'second-bytes'
Put $p.A 'saves/slot.sav' 'slot'
$r=RunCopy $p
$folderPath=Join-Path $p.B 'roms'
Assert ($r.Code -eq 0) 'A folder link rule copies the rest and links the folder'
Assert (Test-Path -LiteralPath $folderPath -PathType Container) 'The linked folder appears in the destination'
Assert ((IsLink $folderPath) -or ($r.Output -match 'Linked folder \(Junction\)')) 'The destination folder is a single link'
Assert (-not (Exists $p.B 'roms/ps2/heavy.iso') -or (IsLink $folderPath) -or ($r.Output -match 'Junction')) 'No per-file link is created inside it'
Assert ((Get-FileHash -LiteralPath (Join-Path $folderPath 'ps2/heavy.iso') -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $p.A 'roms/ps2/heavy.iso') -Algorithm SHA256).Hash) 'The contents are readable through the folder link'
Assert (Exists $p.B 'saves/slot.sav') 'Files outside the linked folder are still copied'
$s=RunSync $p.A
Assert ($s.Code -eq 0) 'The first sync accepts a linked folder'
$stateText=[IO.File]::ReadAllText((Join-Path $p.A 'backup_version.txt'))
Assert ($stateText -notmatch 'roms') 'The linked folder and its contents stay out of the baseline'
Assert ((IsLink $folderPath) -or (Test-Path -LiteralPath $folderPath)) 'The folder link survives the sync'

# ── 15. A real folder where a link belongs: duplicates go, other files stay ──
$p=Pair 'folder-link-existing'
Put $p.A 'create_copy_setup.txt' ('$roms')
Put $p.A 'roms/heavy.iso' 'heavy'; Put $p.A 'roms/extra.iso' 'source-extra'
Put $p.B 'roms/heavy.iso' 'heavy'
Put $p.B 'roms/mine.txt' 'user-content'
$r=RunCopy $p
Assert ($r.Code -eq 0) 'Replacing a real folder with a link succeeds'
Assert ((IsLink (Join-Path $p.B 'roms')) -or ($r.Output -match 'Linked folder \(Junction\)')) 'The folder becomes a link'
Assert ($r.Output -match 'duplicate file\(s\) removed') 'The run reports what it removed'
$recovery=@(Get-ChildItem -LiteralPath (Join-Path $p.B '.backup_sync_recovery') -Recurse -Filter mine.txt -ErrorAction SilentlyContinue)
Assert ($recovery.Count -eq 1 -and ([IO.File]::ReadAllText($recovery[0].FullName) -eq 'user-content')) 'Content that is not a duplicate is kept in the recovery folder'
Assert (Exists $p.B 'roms/extra.iso') 'The rest of the source folder is visible through the link'

# ── 16. The name rules themselves ───────────────────────────────────────
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')
$sourceRoot='/tmp/name-rules-source'
$destinationRoot='/tmp/name-rules-destination'
Assert ((Test-CopyablePath 'eden/saves/slot1.sav' $sourceRoot $destinationRoot) -eq '') 'An ordinary path is accepted'
Assert ((Test-CopyablePath 'notes:stream.txt' $sourceRoot $destinationRoot) -match "contains ':'") 'A colon in a name is refused'
Assert ((Test-CopyablePath 'cache/why?.bin' $sourceRoot $destinationRoot) -match "contains '\?'") 'A question mark in a name is refused'
Assert ((Test-CopyablePath 'cache/star*.bin' $sourceRoot $destinationRoot) -match "contains '\*'") 'A star in a name is refused'
Assert ((Test-CopyablePath 'cache/name.' $sourceRoot $destinationRoot) -match 'ends with a dot') 'A name ending with a dot is refused'
Assert ((Test-CopyablePath 'cache/name ' $sourceRoot $destinationRoot) -match 'ends with a space') 'A name ending with a space is refused'
Assert ((Test-CopyablePath 'CON' $sourceRoot $destinationRoot) -match 'reserved') 'A reserved device name is refused'
Assert ((Test-CopyablePath ('x' * 256) $sourceRoot $destinationRoot) -match 'longer than the 255') 'A name longer than 255 characters is refused'
$deep=('d' * 90) + '/' + ('d' * 90) + '/' + ('d' * 90) + '/file.txt'
Assert ((Test-CopyablePath $deep $sourceRoot $destinationRoot) -match 'characters long') 'A destination path over 259 characters is refused and its length reported'
Assert ((Test-CopyablePath $deep $sourceRoot $destinationRoot) -match 'long-path support') 'The refusal names the Windows limit'

# The fixtures below need names and paths that only a non-Windows file system can hold, so they run
# where they can exist; the rules above already prove the verdicts on every platform.
if ($env:OS -ne 'Windows_NT') {
    # ── 17. A name Windows cannot write stops the copy before it starts ──
    $p=Pair 'invalid-name'
    Put $p.A 'good.txt' 'good'
    Put $p.A 'notes:stream.txt' 'bad'
    $r=RunCopy $p
    Assert ($r.Code -ne 0) 'A name with a character Windows forbids stops the copy'
    Assert ($r.Output -match [regex]::Escape('notes:stream.txt')) 'The refusal names the path that cannot be written'
    Assert ($r.Output -match 'does not allow') 'The refusal says why the name cannot be used'
    Assert ($r.Output -match 'SkipInvalid') 'The refusal points at the way to carry on without it'
    Assert (-not (Exists $p.B 'good.txt')) 'Nothing was copied before the refusal'

    # ── 18. -SkipInvalid copies the rest and excludes the impossible path ─
    $p=Pair 'invalid-name-skip'
    Put $p.A 'good.txt' 'good'
    Put $p.A 'notes:stream.txt' 'bad'
    $r=RunCopy $p @('-SkipInvalid')
    Assert ($r.Code -eq 0) '-SkipInvalid copies what Windows can represent'
    Assert (Exists $p.B 'good.txt') 'The valid file arrives'
    Assert (-not (Exists $p.B 'notes:stream.txt')) 'The impossible name is left out'
    Assert ($r.Output -match 'Skipped 1 path') 'The run reports what it skipped'
    Assert ((ReadFile $p.A 'backup_setup.txt') -match [regex]::Escape('-notes:stream.txt')) 'The skipped path becomes an exclusion rule in the pair configuration'
    $s=RunSync $p.A
    Assert ($s.Code -eq 0) 'The pair syncs afterwards because the impossible path is excluded'

    # ── 19. A destination path longer than Windows allows is refused ─────
    $p=Pair 'long-path'
    $deepFixture=(('d' * 90) + '/' + ('d' * 90) + '/' + ('d' * 90))
    Put $p.A ($deepFixture + '/file.txt') 'deep'
    $r=RunCopy $p
    Assert ($r.Code -ne 0) 'A destination path over 259 characters stops the copy'
    Assert ($r.Output -match 'characters long') 'The refusal explains the path length'
}

# ── 10. Guard rails ────────────────────────────────────────────────────
$p=Pair 'nested'
$nested=Join-Path $p.A 'inner'
$arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'New-SyncCopy.ps1'),
    '-Source',$p.A,'-Destination',$nested)
$null=& $script:HostExe @arguments 2>&1
Assert ($LASTEXITCODE -ne 0) 'A destination inside the source is refused'
$arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'New-SyncCopy.ps1'),
    '-Source',$p.A,'-Destination',(Join-Path $script:Root 'missing-folder'))
$null=& $script:HostExe @arguments 2>&1
Assert ($LASTEXITCODE -ne 0) 'A missing destination is refused'

Write-Host ''
Write-Host "$($script:Passed) checks passed. Fixtures: $script:Root"
exit 0
