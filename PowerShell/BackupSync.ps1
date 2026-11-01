#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true,Position=0)][string]$Source,
    [switch]$SyncOnly,[switch]$Preview,[switch]$RebuildBaseline,
    [switch]$LaunchOnly,[switch]$SkipDelay,[switch]$Rehash)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')
$locks=New-Object 'Collections.Generic.List[IDisposable]'
$script:RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$script:DestinationUnavailable=$false
$Destination=$null
function LaunchConfiguredApplication([string]$Executable) {
    $running=@(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $Executable } catch { $false } })
    if ($running.Count -gt 0) { Write-Host 'Application already running; waiting for it to close.'; $running | Wait-Process -ErrorAction SilentlyContinue }
    else { $null=Start-Process -FilePath $Executable -WorkingDirectory (Split-Path -Parent $Executable) -PassThru -Wait }
    do {
        $running=@(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $Executable } catch { $false } })
        if ($running.Count -gt 0) { $running | Wait-Process -ErrorAction SilentlyContinue }
    } while ($running.Count -gt 0)
}
try {
    $Source=FullPath (Resolve-Path -LiteralPath $Source).ProviderPath
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw 'Source must be a folder.' }
    $lines=@(Get-Content -LiteralPath (Join-Path $Source 'backup_setup.txt') -Encoding UTF8)
    if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) { throw 'First config line must be the destination folder.' }
    $dest=[Environment]::ExpandEnvironmentVariables($lines[0].Trim().Trim('"'))
    if (-not [IO.Path]::IsPathRooted($dest)) { $dest=Join-Path $Source $dest }
    $Destination=FullPath $dest
    if ($Source -eq $Destination -or $Source.StartsWith($Destination+'\',[StringComparison]::OrdinalIgnoreCase) -or
        $Destination.StartsWith($Source+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source and destination must be separate, non-nested folders.' }
    $exe=''; $delay=10; $index=1
    if ($index -lt $lines.Count -and $lines[$index] -notmatch '^\s*[+-]') { $exe=$lines[$index].Trim().Trim('"'); $index++ }
    if ($index -lt $lines.Count -and $lines[$index] -notmatch '^\s*[+-]') {
        if (-not [string]::IsNullOrWhiteSpace($lines[$index])) {
            if (-not [int]::TryParse($lines[$index].Trim(),[ref]$delay) -or $delay -lt 0) { throw 'Delay must be a nonnegative integer.' }
        }
        $index++
    }
    SetSelectionRules $lines $index
    if ($LaunchOnly) {
        if (-not $exe) { Write-Host 'No executable configured; nothing to launch.'; exit 3 }
        $exe=[Environment]::ExpandEnvironmentVariables($exe)
        if (-not [IO.Path]::IsPathRooted($exe)) { $exe=Join-Path $Source $exe }
        $exe=FullPath $exe
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or [IO.Path]::GetExtension($exe) -ne '.exe') { throw "Executable not found: $exe" }
        LaunchConfiguredApplication $exe
        exit 0
    }
    foreach ($root in @($Source,$Destination)) {
        if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { throw 'Use dedicated folders, not drive/share roots.' }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            if ($root -eq $Destination) { $script:DestinationUnavailable=$true }
            throw "Folder unavailable: $root. Reconnect the drive or create it with setup."
        }
        if (((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Sync roots cannot be links/junctions.' }
    }
    if (-not $Preview) {
        foreach ($root in @($Source,$Destination) | Sort-Object) {
            $locks.Add([IO.File]::Open((Join-Path $root '.backup_sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))
        }
    }
    if ($exe -and -not $SyncOnly -and -not $Preview) {
        $exe=[Environment]::ExpandEnvironmentVariables($exe)
        if (-not [IO.Path]::IsPathRooted($exe)) { $exe=Join-Path $Source $exe }
        $exe=FullPath $exe
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or [IO.Path]::GetExtension($exe) -ne '.exe') { throw "Executable not found: $exe" }
        LaunchConfiguredApplication $exe
    }
    if (-not $Preview -and -not $SkipDelay -and $delay -gt 0) { Write-Host "Waiting $delay seconds for background writes..."; Start-Sleep -Seconds $delay }
    Write-Host "Source: $Source`nDestination: $Destination"
    $a=$null; $b=$null
    if (-not $RebuildBaseline) { $a=ReadState $Source; $b=ReadState $Destination }
    $base=@{}; $computers=@{}; $pairId=[guid]::NewGuid().ToString(); $generation=0
    if (-not $RebuildBaseline) {
        if ($null -ne $a -and $null -eq $b) { throw 'Destination version file is missing. Reconnect the correct backup or use -RebuildBaseline for a merge with no inferred deletions.' }
        if ($null -ne $a) {
            if ($a.PairId -ne $b.PairId) { throw 'Different sync pairs. Review files and use -RebuildBaseline for a conservative merge with no inferred deletions.' }
            # This source's snapshot is its last agreed state, even if another PC synced to the destination since then.
            $base=$a.Files; $computers=$a.Computers; $pairId=$a.PairId
            $generation=[Math]::Max($a.Generation,$b.Generation)
            foreach ($name in $b.Computers.Keys) {
                if (-not $computers.ContainsKey($name) -or $computers[$name] -lt $b.Computers[$name]) { $computers[$name]=$b.Computers[$name] }
            }
        } elseif ($null -ne $b) {
            Write-Host 'New source: conservatively merge with the existing destination; no inferred deletions.'
            $pairId=$b.PairId; $computers=$b.Computers; $generation=$b.Generation
        }
    } elseif (-not $Preview -and (Ask 'Rebuild baseline? Current files will be merged without inferring deletions' @('Y','N')) -eq 'N') { exit 0 }
    # Files whose size and write time still match the previous state keep their recorded hash, so this
    # snapshot reads the directory tree instead of every byte. -Rehash forces a full read of both sides.
    $sourceCache=if ($Rehash -or $null -eq $a) { $null } else { $a.Cache }
    $destinationCache=if ($Rehash -or $null -eq $b) { $null } else { $b.Cache }
    $left=Snapshot $Source $sourceCache; $right=Snapshot $Destination $destinationCache
    $keys=@(UnionKeys @($left.Files,$right.Files,$base))
    $operations=New-Object 'Collections.Generic.List[object]'
    foreach ($key in $keys) {
        if (-not (Selected $key)) { continue }
        $lh=Hash $left.Files $key; $rh=Hash $right.Files $key; $bh=Hash $base $key
        if ($lh -eq $rh) { continue }
        $action=''; $reason=''
        if ($null -eq $bh) {
            if ($null -eq $lh) { $action='ToSource' } elseif ($null -eq $rh) { $action='ToDestination' }
            else { $reason='Different contents without a common baseline.' }
        } elseif ($lh -eq $bh) {
            if ($null -eq $rh) { $action='DeleteSource' } else { $action='ToSource' }
        } elseif ($rh -eq $bh) {
            if ($null -eq $lh) { $action='DeleteDestination' } else { $action='ToDestination' }
        } else { $reason='Both sides changed since the last agreed version (possibly edit versus deletion).' }
        if ($reason) {
            Write-Host "`nCONFLICT: $key`n$reason" -ForegroundColor Yellow
            $ld=if ($null -eq $lh) { 'MISSING' } else { "$($left.Files[$key].Modified), $($left.Files[$key].Length) bytes" }
            $rd=if ($null -eq $rh) { 'MISSING' } else { "$($right.Files[$key].Modified), $($right.Files[$key].Length) bytes" }
            Write-Host "Source: $ld`nDestination: $rd"
            if ($Preview) { Write-Host 'Would ask: source / destination / skip / abort'; continue }
            $choice=Ask 'Use (S)ource, (D)estination, s(K)ip, or (A)bort' @('S','D','K','A')
            if ($choice -eq 'A') { exit 0 }; if ($choice -eq 'K') { continue }
            if ($choice -eq 'S') { if ($null -eq $lh) { $action='DeleteDestination' } else { $action='ToDestination' } }
            else { if ($null -eq $rh) { $action='DeleteSource' } else { $action='ToSource' } }
        }
        $operations.Add(@{Path=$key; Action=$action; LeftHash=$lh; RightHash=$rh})
    }
    foreach ($op in $operations) { Write-Host ('{0,-18} {1}' -f $op.Action,$op.Path) }
    if ($Preview) { Write-Host 'Preview only: no application launch, delay, locks, copies, deletions or metadata writes.'; exit 0 }
    $approved=New-Object 'Collections.Generic.List[object]'
    foreach ($op in $operations) {
        if ($op.Action.StartsWith('Delete')) {
            $side=if ($op.Action -eq 'DeleteSource') { $Source } else { $Destination }
            $choice=Ask "Delete '$($op.Path)' from '$side'? (Y) delete with recovery, (R) restore missing file, (N) skip, (A) abort" @('Y','R','N','A')
            if ($choice -eq 'Y') { $approved.Add($op) }
            elseif ($choice -eq 'R') {
                $op.Action=if ($op.Action -eq 'DeleteSource') { 'ToDestination' } else { 'ToSource' }
                $approved.Add($op)
            } elseif ($choice -eq 'A') { exit 0 }
        } else { $approved.Add($op) }
    }
    $checkSourceCache=$null; $checkDestinationCache=$null
    if (-not $Rehash) { $checkSourceCache=$left.Files; $checkDestinationCache=$right.Files }
    $checkLeft=Snapshot $Source $checkSourceCache; $checkRight=Snapshot $Destination $checkDestinationCache
    foreach ($side in @(@{Old=$left.Files; New=$checkLeft.Files},@{Old=$right.Files; New=$checkRight.Files})) {
        if ($side.Old.Count -ne $side.New.Count) { throw 'Files changed during review. Retry sync.' }
        foreach ($key in $side.Old.Keys) { if ((Hash $side.Old $key) -ne (Hash $side.New $key)) { throw "File changed during review: $key" } }
    }
    foreach ($op in $approved) {
        switch ($op.Action) {
            'ToSource' { CopyChecked $Destination $Source $op.Path $op.RightHash $op.LeftHash }
            'ToDestination' { CopyChecked $Source $Destination $op.Path $op.LeftHash $op.RightHash }
            default {
                $root=if ($op.Action -eq 'DeleteSource') { $Source } else { $Destination }
                $other=if ($op.Action -eq 'DeleteSource') { $Destination } else { $Source }
                $expected=if ($op.Action -eq 'DeleteSource') { $op.LeftHash } else { $op.RightHash }
                $path=LocalPath $root $op.Path
                AssertCurrent (LocalPath $other $op.Path) $null; AssertCurrent $path $expected
                Recover $root $op.Path $expected
                AssertCurrent (LocalPath $other $op.Path) $null; AssertCurrent $path $expected
                Remove-Item -LiteralPath $path -Force
                Write-Host "Deleted (recovery saved): $path"
            }
        }
    }
    foreach ($key in @(@($left.Dirs.Keys)+@($right.Dirs.Keys) | Sort-Object -Unique)) {
        foreach ($root in @($Source,$Destination)) { $null=New-Item -ItemType Directory -Path (LocalPath $root $key) -Force }
    }
    # Every path this run touched is rehashed for the new baseline: a copy keeps the source's size and
    # write time, so a cached hash for that path could otherwise still describe the file it replaced.
    foreach ($op in $approved) { $null=$checkLeft.Files.Remove($op.Path); $null=$checkRight.Files.Remove($op.Path) }
    $finalSourceCache=$null; $finalDestinationCache=$null
    if (-not $Rehash) { $finalSourceCache=$checkLeft.Files; $finalDestinationCache=$checkRight.Files }
    $finalLeft=Snapshot $Source $finalSourceCache; $finalRight=Snapshot $Destination $finalDestinationCache
    $newBase=@{}; $pending=0
    foreach ($key in @(UnionKeys @($keys,$finalLeft.Files,$finalRight.Files))) {
        if (-not (Selected $key)) { continue }
        $lh=Hash $finalLeft.Files $key; $rh=Hash $finalRight.Files $key
        if ($lh -eq $rh) {
            if ($null -ne $lh) {
                $agreed=$finalLeft.Files[$key]
                $newBase[$key]=@{Hash=$lh; Length=$agreed.Length; Modified=$agreed.Modified}
            }
        }
        else { $pending++; if ($base.ContainsKey($key)) { $newBase[$key]=$base[$key] } }
    }
    $computer=[Environment]::MachineName
    if (-not $computers.ContainsKey($computer)) { $computers[$computer]=0 }
    $computers[$computer]++
    $json=@{Schema=2; PairId=$pairId; Generation=($generation+1); Computers=$computers; Files=$newBase;
        LastSyncUtc=[DateTime]::UtcNow.ToString('o'); LastSource=$Source; LastDestination=$Destination} | ConvertTo-Json -Depth 8
    WriteState $Source $json; WriteState $Destination $json
    Write-Host "Sync complete. $($approved.Count) file operations; $pending unresolved file(s)."
    if ($pending -gt 0) { Write-Host 'Unresolved differences will be reviewed on the next run.' }
} catch {
    $failure=$_.Exception
    if (-not $script:DestinationUnavailable -and $null -ne $Destination) {
        try { $script:DestinationUnavailable=-not (Test-Path -LiteralPath $Destination -PathType Container) } catch { $script:DestinationUnavailable=$true }
    }
    Write-Host "Backup sync stopped: $($failure.Message)" -ForegroundColor Red
    if ($script:DestinationUnavailable) { exit 2 }
    exit 1
} finally { foreach ($handle in $locks) { $handle.Dispose() } }





