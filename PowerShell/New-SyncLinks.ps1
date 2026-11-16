#requires -Version 5.1
<#
.SYNOPSIS
    Creates the links a synced copy needs, with the rights the caller lacks.

.DESCRIPTION
    New-SyncCopy.ps1 creates links itself first. When Windows refuses a file symbolic link to a
    non-administrator (no Developer Mode, or the two roots live on different volumes, where a hard
    link is impossible), it starts this script elevated once for all remaining paths. The rules
    travel as base64 so no quoting can break them, and nothing else about the copy is repeated here.

    Run it by hand to repair links after moving folders, without repeating the copy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$LinkRulesBase64
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')

try {
    $Source = FullPath (Resolve-Path -LiteralPath $Source).ProviderPath
    $Destination = FullPath (Resolve-Path -LiteralPath $Destination).ProviderPath
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw 'The destination folder does not exist.' }

    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LinkRulesBase64))
    $rules = New-Object 'Collections.Generic.List[string]'
    foreach ($line in ($decoded -split "`n")) {
        $pattern = $line.Trim().TrimStart('$').Trim()
        if ($pattern.Length -gt 0) { $rules.Add('$' + $pattern) }
    }
    if ($rules.Count -eq 0) { throw 'No link rules were supplied.' }
    SetSelectionRules $rules.ToArray()

    # Informational only: the Windows identity APIs exist on Windows alone, and this helper still has to
    # run where the tests run.
    $elevated = $false
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $elevated = $false }
    Write-Host ("Elevated: {0} | link rules: {1}" -f $elevated, $script:LinkRules.Count)

    $created = 0
    $skipped = 0
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($Source)
    while ($stack.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop)) {
            $relative = $item.FullName.Substring($Source.Length + 1).Replace('\', '/')
            if (Reserved $relative) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and -not (IsLinked $relative)) {
                throw "Link/junction encountered: $($item.FullName). Move it outside this folder."
            }
            if ($item.PSIsContainer) {
                # A rule that names the folder itself gets one link for the whole tree, exactly like the copy.
                if (-not (IsLinked $relative)) { $stack.Push($item.FullName); continue }
                $folderPath=LocalPath $Destination $relative
                $folderItem=Get-Item -LiteralPath $folderPath -Force -ErrorAction SilentlyContinue
                if ($null -ne $folderItem -and ($folderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skipped++
                    continue
                }
                ClearForLink $Source $Destination $relative
                $kind=NewLink (LocalPath $Source $relative) $folderPath -Container
                $entries=@(Get-ChildItem -LiteralPath $folderPath -Force -ErrorAction Stop).Count
                if ($entries -ne @(Get-ChildItem -LiteralPath (LocalPath $Source $relative) -Force -ErrorAction Stop).Count) {
                    throw "Folder link verification failed: $relative"
                }
                $created++
                Write-Host "Linked folder ($kind) $relative"
                continue
            }
            if (-not (IsLinked $relative)) { continue }

            $target = LocalPath $Source $relative
            $linkPath = LocalPath $Destination $relative
            $existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                if ($null -ne (LinkTargetOf $linkPath)) {
                    # Already a link: leave it, the caller verifies the content afterwards.
                    $skipped++
                    continue
                }
                Recover $Destination $relative (Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash
                Remove-Item -LiteralPath $linkPath -Force
            }
            $kind = NewLink $target $linkPath
            if ((Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
                throw "Link verification failed: $relative"
            }
            $created++
            Write-Host "Linked ($kind) $relative"
        }
    }
    Write-Host ("Links created: {0}; already present: {1}." -f $created, $skipped)
    exit 0
} catch {
    Write-Host "Link creation stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
