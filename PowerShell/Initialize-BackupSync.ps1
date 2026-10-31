#requires -Version 5.1
<#
.SYNOPSIS
    Runs the destination-to-source initialization step without console prompts.

.DESCRIPTION
    Setup-BackupSync.ps1 asks its questions with Read-Host. The desktop front-end
    collects the same answers in dialogs, so this helper scripts them: it
    dot-sources the shared library and replaces Ask() before calling
    InitializeSource(), leaving the real filtering, locking, hashing, recovery
    and copy logic untouched.

    InitializeSource() itself performs every safety check (missing
    backup_version.txt, missing backup_init.txt, reparse points, changed files
    during review) and returns silently when initialization is not applicable.

.PARAMETER ConflictPolicy
    What to do when a matching file has different content:
    Destination copies the destination version over the source one (a recovery
    copy is kept), Source keeps the existing source file, Abort cancels without
    touching any user file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [ValidateSet('Destination', 'Source', 'Abort')][string]$ConflictPolicy = 'Abort'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')

# Every interactive question answered from the parameters above.
function Ask([string]$Message, [string[]]$Choices) {
    if ($Choices -contains 'Y') {
        Write-Host "Answering Y: $Message"
        return 'Y'
    }
    if ($Choices -contains 'D') {
        $answer = switch ($ConflictPolicy) { 'Destination' { 'D' } 'Source' { 'S' } default { 'A' } }
        Write-Host "Answering ${answer}: $Message"
        return $answer
    }
    throw "Unexpected interactive prompt in non-interactive initialization: $Message"
}

try {
    $resolvedSource = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
    $resolvedDestination = (Resolve-Path -LiteralPath $Destination).ProviderPath.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) { throw 'Source must be a folder.' }
    if (-not (Test-Path -LiteralPath $resolvedDestination -PathType Container)) { throw 'Destination must be a folder.' }
    InitializeSource $resolvedSource $resolvedDestination
    exit 0
} catch {
    Write-Host "Initialization stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
