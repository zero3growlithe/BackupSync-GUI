#requires -Version 5.1
# Isolated initialization checks; the Windows folder picker is substituted in the setup integration check.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')
$script:Root=Join-Path $env:TEMP ('BackupSync-init-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:Root
$script:Passed=0
$script:Answers=New-Object 'Collections.Generic.Queue[string]'
function Read-Host([string]$Prompt) {
    if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    $script:Answers.Dequeue()
}
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Passed++; Write-Host "PASS: $Message"
}
function Put([string]$Root,[string]$Path,[string]$Value) {
    $path=Join-Path $Root $Path
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
    [IO.File]::WriteAllText($path,$Value,(New-Object Text.UTF8Encoding($false)))
}
function ReadFile([string]$Root,[string]$Path) { [IO.File]::ReadAllText((Join-Path $Root $Path)) }
function Pair([string]$Name,[string]$Rules='+*') {
    $a=Join-Path $script:Root ($Name+'\source [test]'); $b=Join-Path $script:Root ($Name+'\destination')
    $null=New-Item -ItemType Directory -Path $a,$b -Force
    Put $b 'backup_init.txt' $Rules
    @{A=$a; B=$b}
}
function RunInit($Pair,[string[]]$Answers=@()) {
    $script:Answers.Clear()
    foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
    InitializeSource $Pair.A $Pair.B
    if ($script:Answers.Count -gt 0) { throw 'Not all expected prompts occurred' }
}
$p=Pair 'filters' "+Saves`n+*.exe`n-Saves/cache`n-*.tmp"
Put $p.B 'Saves/data.dat' 'save'; Put $p.B 'Saves/cache/no.dat' 'no'; Put $p.B 'Saves/no.tmp' 'no'
Put $p.B 'bin/app.exe' 'app'; Put $p.B 'other.txt' 'unselected'; Put $p.A 'Saves/local.dat' 'keep'
$null=New-Item -ItemType Directory -Path (Join-Path $p.B 'Saves/empty')
RunInit $p @('Y')
Assert ((ReadFile $p.A 'Saves/data.dat') -eq 'save' -and (ReadFile $p.A 'bin/app.exe') -eq 'app') 'Initialization includes files and folders using plus rules'
Assert (-not (Test-Path -LiteralPath (Join-Path $p.A 'Saves/cache/no.dat')) -and -not (Test-Path -LiteralPath (Join-Path $p.A 'Saves/no.tmp')) -and -not (Test-Path -LiteralPath (Join-Path $p.A 'other.txt'))) 'Minus rules filter includes'
Assert ((ReadFile $p.A 'Saves/local.dat') -eq 'keep') 'Source-only files are never deleted'
Assert (Test-Path -LiteralPath (Join-Path $p.A 'Saves/empty') -PathType Container) 'Selected empty destination directories are initialized'
Assert (-not (Test-Path -LiteralPath (Join-Path $p.A 'backup_version.txt')) -and -not (Test-Path -LiteralPath (Join-Path $p.A 'backup_init.txt'))) 'Initialization creates no baseline and does not copy its filter file'
$p=Pair 'decline'; Put $p.B 'file.txt' 'remote'
RunInit $p @('N')
Assert (-not (Test-Path -LiteralPath (Join-Path $p.A 'file.txt')) -and -not (Test-Path -LiteralPath (Join-Path $p.A '.backup_sync.lock'))) 'Declining initialization does not copy or create locks'
Put $p.A 'backup_version.txt' 'existing metadata'
RunInit $p
Assert (-not (Test-Path -LiteralPath (Join-Path $p.A 'file.txt'))) 'Source version file suppresses the initialization prompt'
$p=Pair 'no-init'; Remove-Item -LiteralPath (Join-Path $p.B 'backup_init.txt')
RunInit $p
Assert (-not (Test-Path -LiteralPath (Join-Path $p.A '.backup_sync.lock'))) 'Missing destination init file leaves setup unchanged'
$p=Pair 'conflict'; Put $p.B 'same.txt' 'destination'; Put $p.A 'same.txt' 'source'
RunInit $p @('Y','S')
Assert ((ReadFile $p.A 'same.txt') -eq 'source' -and (ReadFile $p.B 'same.txt') -eq 'destination') 'Choosing source preserves a conflicting local file'
RunInit $p @('Y','D')
Assert ((ReadFile $p.A 'same.txt') -eq 'destination' -and (ReadFile $p.B 'same.txt') -eq 'destination') 'Choosing destination copies only to source'
$copies=@(Get-ChildItem -LiteralPath (Join-Path $p.A '.backup_sync_recovery') -Recurse -Filter same.txt)
Assert ($copies.Count -eq 1 -and [IO.File]::ReadAllText($copies[0].FullName) -eq 'source') 'Initialization overwrites retain a verified recovery copy'
RunInit $p @('Y')
Assert ((ReadFile $p.A 'same.txt') -eq 'destination') 'Identical files need no conflict prompt'
$p=Pair 'abort'; Put $p.B 'aaa.txt' 'addition'; Put $p.B 'zzz.txt' 'remote'; Put $p.A 'zzz.txt' 'local'
$failed=$false
try { RunInit $p @('Y','A') } catch { $failed=$_.Exception.Message.Contains('cancelled before any files') }
Assert ($failed -and -not (Test-Path -LiteralPath (Join-Path $p.A 'aaa.txt')) -and (ReadFile $p.A 'zzz.txt') -eq 'local') 'Aborting conflict review prevents all planned copies'
$p=Pair 'invalid-rule' '+../outside'; Put $p.B 'file.txt' 'no'
$failed=$false
try { RunInit $p @('Y') } catch { $failed=$_.Exception.Message.Contains('relative paths') }
Assert ($failed -and -not (Test-Path -LiteralPath (Join-Path $p.A 'file.txt'))) 'Unsafe initialization rules fail before copies'
$p=Pair 'exclude-only' '-*.zip'; Put $p.B 'nested/no.zip' 'no'; Put $p.B 'nested/yes.txt' 'yes'
RunInit $p @('Y')
Assert ((Test-Path -LiteralPath (Join-Path $p.A 'nested/yes.txt')) -and -not (Test-Path -LiteralPath (Join-Path $p.A 'nested/no.zip'))) 'Exclusion-only initialization includes other files at all depths'
$p=Pair 'empty-rules' ''; Put $p.B 'file.txt' 'yes'; Put $p.B 'backup_version.txt' 'destination state'; Put $p.B 'backup_setup.txt' 'destination config'
RunInit $p @('Y')
Assert ((ReadFile $p.A 'file.txt') -eq 'yes' -and -not (Test-Path -LiteralPath (Join-Path $p.A 'backup_setup.txt')) -and -not (Test-Path -LiteralPath (Join-Path $p.A 'backup_version.txt'))) 'Empty rules include ordinary files but preserve control metadata'
Assert ((ReadFile $p.B 'backup_version.txt') -eq 'destination state' -and (ReadFile $p.B 'backup_setup.txt') -eq 'destination config') 'Initialization preserves destination metadata'
$p=Pair 'wildcards' "+**/slot?.dat`n-**/cache/**"
Put $p.B 'slot1.dat' 'root'; Put $p.B 'nested/slot2.dat' 'nested'; Put $p.B 'cache/slot3.dat' 'no'; Put $p.B 'slot10.dat' 'no'
RunInit $p @('Y')
Assert ((ReadFile $p.A 'slot1.dat') -eq 'root' -and (ReadFile $p.A 'nested/slot2.dat') -eq 'nested' -and -not (Test-Path -LiteralPath (Join-Path $p.A 'cache/slot3.dat')) -and -not (Test-Path -LiteralPath (Join-Path $p.A 'slot10.dat'))) 'Double-star and question-mark initialization globs match normal sync rules'
# Integration: initialize first, then offer the copied EXE in the setup list.
$p=Pair 'setup-integration' '+bin'
Put $p.B 'bin/game.exe' 'fixture only; never executed'
$code=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Setup-BackupSync.ps1') -Raw -Encoding UTF8
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
$picker=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ChooseFolder'},$true)
$code=$code.Replace($picker.Extent.Text,'function ChooseFolder([string]$Title) { return $script:FixtureDestination }')
$prefix='$script:FixtureDestination='''+$p.B.Replace("'","''")+''''+"`r`n"+
    'function Read-Host { param([string]$Prompt) if ($Prompt -like ''Initialize source*'') { return ''Y'' }; if ($Prompt -like ''Choose an executable*'') { return ''1'' }; if ($Prompt -like ''Seconds to wait*'') { return ''0'' }; throw "Unexpected prompt: $Prompt" }'+"`r`n"
$code=$code.Replace('Set-StrictMode -Version Latest',$prefix+'Set-StrictMode -Version Latest')
$fixture=Join-Path $PSScriptRoot ('.Test-InitSetup-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    [IO.File]::WriteAllText($fixture,$code,(New-Object Text.UTF8Encoding($true)))
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixture -Source $p.A -NoExplorer 2>&1
    Assert ($LASTEXITCODE -eq 0) ('Setup initializes before executable selection: '+($output -join ' '))
    $lines=@(Get-Content -LiteralPath (Join-Path $p.A 'backup_setup.txt') -Encoding UTF8)
    $shell=New-Object -ComObject WScript.Shell
    $launcher=$shell.CreateShortcut((Join-Path $p.A 'Launcher.backup-sync.lnk'))
    $syncOnly=$shell.CreateShortcut((Join-Path $p.A 'Sync only.backup-sync.lnk'))
    Assert ($lines[1] -eq 'bin\game.exe' -and $launcher.IconLocation.StartsWith((Join-Path $p.A 'bin\game.exe')) -and $syncOnly.IconLocation.StartsWith((Join-Path $p.A 'bin\game.exe'))) 'Copied executable is selectable and supplies both action-shortcut icons'
    # Normal sync must also exclude backup_init.txt, regardless of its own different selection rules.
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'BackupSync.ps1') -Source $p.A -SyncOnly 2>&1
    Assert ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $p.A 'backup_init.txt')) -and (Test-Path -LiteralPath (Join-Path $p.A 'backup_version.txt'))) 'First normal sync establishes its baseline and excludes backup_init.txt'
} finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force } }
Write-Host "`n$script:Passed initialization checks passed. Fixtures retained at $script:Root"
