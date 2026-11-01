#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true,Position=0)][string]$Source,
    [switch]$SyncOnly,[switch]$Preview,[switch]$RebuildBaseline,[switch]$Rehash)
$engine=Join-Path $PSScriptRoot 'BackupSync.ps1'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:EngineExitCode=0
function InvokeEngine([string[]]$ExtraArguments=@()) {
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Source',$Source)+$ExtraArguments
    & $powershell @arguments
    $script:EngineExitCode=$LASTEXITCODE
}
if ($SyncOnly -or $Preview -or $RebuildBaseline -or $Rehash) {
    $arguments=New-Object 'Collections.Generic.List[string]'
    foreach ($name in @('SyncOnly','Preview','RebuildBaseline','Rehash')) { if ((Get-Variable -Name $name -ValueOnly)) { $arguments.Add('-' + $name) } }
    InvokeEngine $arguments.ToArray()
    $result=$script:EngineExitCode
    if ($result -ne 0) { $null=Read-Host 'Sync failed. Press Enter to close' }
    exit $result
}

Write-Host 'Checking for updates before launch...'
InvokeEngine @('-SyncOnly','-SkipDelay')
$preLaunchResult=$script:EngineExitCode
if ($preLaunchResult -eq 2) {
    Write-Host 'Backup destination is unavailable. Launching the application without a pre-launch sync.' -ForegroundColor Yellow
} elseif ($preLaunchResult -ne 0) {
    $null=Read-Host 'Pre-launch sync failed. Press Enter to close without launching the application'
    exit $preLaunchResult
}

InvokeEngine @('-LaunchOnly')
$launchResult=$script:EngineExitCode
if ($launchResult -eq 3) { exit 0 }
if ($launchResult -ne 0) {
    $null=Read-Host 'Application launch failed. Press Enter to close'
    exit $launchResult
}

while ($true) {
    Write-Host 'Application closed. Synchronizing changes...'
    InvokeEngine @('-SyncOnly')
    $postLaunchResult=$script:EngineExitCode
    if ($postLaunchResult -eq 0) { exit 0 }
    if ($postLaunchResult -ne 2) {
        $null=Read-Host 'Post-launch sync failed. Press Enter to close'
        exit $postLaunchResult
    }
    $choice=(Read-Host 'Backup destination is still unavailable. Press Enter to close, or R to retry sync').Trim()
    if ($choice -ine 'R') { exit 2 }
}

