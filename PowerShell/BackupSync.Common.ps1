#requires -Version 5.1
# Shared filtering, verified copying, recovery and initialization helpers.
function Ask([string]$Message,[string[]]$Choices) {
    while ($true) {
        $reply=(Read-Host "$Message [$($Choices -join '/')]").Trim().ToUpperInvariant()
        if ($Choices -contains $reply) { return $reply }
    }
}
function FullPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\','/') }
function Reserved([string]$Path) {
    $parts=$Path -split '/'
    ($parts[0] -in @('backup_setup.txt','backup_init.txt','backup_version.txt','create_copy_setup.txt','.backup_sync_recovery','.backup_sync.lock') -or
        $parts[-1] -like '*.backup-sync.lnk' -or $parts[-1] -like '.backup-sync-tmp-*')
}
# Rules from SetSelectionRules. '$' rules mark files the destination keeps as a link to the source.
$script:Includes=@(); $script:Excludes=@(); $script:LinkRules=@()
function Glob([string]$Pattern) {
    $regex=''
    for ($i=0; $i -lt $Pattern.Length; $i++) {
        $c=$Pattern[$i]
        if ($c -eq '*') {
            if ($i+1 -lt $Pattern.Length -and $Pattern[$i+1] -eq '*') {
                $i++
                if ($i+1 -lt $Pattern.Length -and $Pattern[$i+1] -eq '/') { $regex+='(?:.*/)?'; $i++ }
                else { $regex+='.*' }
            } else { $regex+='[^/]*' }
        } elseif ($c -eq '?') { $regex+='[^/]' }
        else { $regex += [regex]::Escape([string]$c) }
    }
    $regex
}
function Matches([string]$Path,[string]$Pattern) {
    $prefix=if ($Pattern.Contains('/')) { '^' } else { '(?:^|/)' }
    $Path -match ($prefix+(Glob $Pattern)+'(?:/.*)?$')
}
function IsLinked([string]$Path) {
    foreach ($pattern in $script:LinkRules) { if (Matches $Path $pattern) { return $true } }
    return $false
}
function Selected([string]$Path) {
    if (Reserved $Path) { return $false }
    # A '$' rule means "the destination holds a link to this file", so the file itself never syncs as content.
    if (IsLinked $Path) { return $false }
    $yes=$script:Includes.Count -eq 0
    foreach ($pattern in $script:Includes) { if (Matches $Path $pattern) { $yes=$true; break } }
    if (-not $yes) { return $false }
    foreach ($pattern in $script:Excludes) { if (Matches $Path $pattern) { return $false } }
    return $true
}
function LocalPath([string]$Root,[string]$Relative) {
    $p=FullPath (Join-Path $Root $Relative.Replace('/','\'))
    if (-not $p.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe relative path: $Relative" }
    $p
}
function Snapshot([string]$Root,[hashtable]$Cache=$null) {
    $files=@{}; $dirs=@{}; $stack=New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop)) {
            $rel=$item.FullName.Substring($Root.Length+1).Replace('\','/')
            if (Reserved $rel) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                # Expected where a '$' rule put a link; any other link is still a hard stop.
                if (IsLinked $rel) { continue }
                throw "Link/junction encountered: $($item.FullName). Move it outside this sync tree."
            }
            if ($item.PSIsContainer) {
                # A '$' rule on the folder itself means the destination holds one link for the whole tree,
                # so its contents are neither compared nor walked.
                if (IsLinked $rel) { continue }
                $stack.Push($item.FullName)
                if (Selected $rel) { $dirs[$rel]=$true }
            } elseif (Selected $rel) {
                $length=$item.Length; $modified=$item.LastWriteTimeUtc
                $known=$null
                if ($null -ne $Cache) { $known=$Cache[$rel] }
                if ($null -ne $known -and $known.Length -eq $length -and $known.Modified -eq $modified.ToString('o')) {
                    # Same length and same write time as a hash we already recorded: the file is not read at all.
                    # Hashes still decide every direction; metadata only decides whether a read is needed.
                    $files[$rel]=$known
                } else {
                    $before=Get-Item -LiteralPath $item.FullName -Force
                    $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                    $after=Get-Item -LiteralPath $item.FullName -Force
                    if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc -or
                        $after.Length -ne $length -or $after.LastWriteTimeUtc -ne $modified) {
                        throw "File changed while scanning: $($item.FullName)"
                    }
                    $files[$rel]=@{Hash=$hash; Length=$after.Length; Modified=$after.LastWriteTimeUtc.ToString('o')}
                }
            }
        }
    }
    @{Files=$files; Dirs=$dirs}
}
function Hash($Files,[string]$Key) { if ($Files.ContainsKey($Key)) { [string]$Files[$Key].Hash } else { $null } }
# Sorted union of key maps and key lists, without Sort-Object's per-element pipeline cost.
function UnionKeys([object[]]$Sources) {
    $unique=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($source in $Sources) {
        if ($null -eq $source) { continue }
        if ($source -is [string]) { $null=$unique.Add($source); continue }
        if ($source -is [hashtable]) {
            foreach ($key in $source.Keys) { $null=$unique.Add([string]$key) }
        } else {
            foreach ($key in $source) { $null=$unique.Add([string]$key) }
        }
    }
    $keys=New-Object 'string[]' $unique.Count
    $unique.CopyTo($keys)
    [Array]::Sort($keys)
    $keys
}
function ReadState([string]$Root) {
    $p=Join-Path $Root 'backup_version.txt'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $obj=Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($obj.Schema -ne 1 -and $obj.Schema -ne 2) { throw "Unsupported version file at $Root" }
    $files=@{}; $computers=@{}; $cache=@{}
    foreach ($prop in $obj.Files.PSObject.Properties) {
        $null=LocalPath $Root $prop.Name
        $files[$prop.Name]=@{Hash=[string]$prop.Value.Hash}
        # A complete record can skip hashing later; anything else is rehashed. Schema 1 has no sizes or times.
        $length=$prop.Value.PSObject.Properties['Length']; $modified=$prop.Value.PSObject.Properties['Modified']
        if ($null -ne $length -and $null -ne $modified) {
            $cache[$prop.Name]=@{Hash=[string]$prop.Value.Hash; Length=[long]$length.Value; Modified=[string]$modified.Value}
        }
    }
    foreach ($prop in $obj.Computers.PSObject.Properties) { $computers[$prop.Name]=[long]$prop.Value }
    @{PairId=[string]$obj.PairId; Generation=[long]$obj.Generation; Files=$files; Computers=$computers; Cache=$cache;
        RawHash=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
}
function AssertCurrent([string]$Path,$Expected) {
    if ($null -eq $Expected) {
        if (Test-Path -LiteralPath $Path) { throw "Path appeared after scan: $Path" }
    } else {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File disappeared: $Path" }
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) { throw "File changed after scan: $Path" }
    }
}
function Recover([string]$Root,[string]$Relative,[string]$Expected) {
    $from=LocalPath $Root $Relative
    $recovery=Join-Path (Join-Path $Root '.backup_sync_recovery') $script:RunId
    $to=LocalPath $recovery $Relative
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
    [IO.File]::Copy($from,$to,$false)
    if ((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -ne $Expected) { throw "Recovery verification failed: $Relative" }
}
function CopyChecked([string]$FromRoot,[string]$ToRoot,[string]$Relative,[string]$FromHash,$ToHash) {
    $from=LocalPath $FromRoot $Relative; $to=LocalPath $ToRoot $Relative
    AssertCurrent $from $FromHash; AssertCurrent $to $ToHash
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
    $temp=Join-Path (Split-Path -Parent $to) ('.backup-sync-tmp-'+[guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::Copy($from,$temp,$false)
        if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $FromHash) { throw "Copy verification failed: $Relative" }
        AssertCurrent $from $FromHash; AssertCurrent $to $ToHash
        if ($null -ne $ToHash) {
            Recover $ToRoot $Relative $ToHash
            AssertCurrent $to $ToHash
            [IO.File]::Replace($temp,$to,[System.Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temp,$to) }
        Write-Host "Copied $Relative -> $to"
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
# Resolved target of a symbolic link/junction, or $null for an ordinary file.
function LinkTargetOf([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return $null }
    $target=$item.PSObject.Properties['LinkTarget']
    if ($null -ne $target -and $target.Value) { return [string]($target.Value | Select-Object -First 1) }
    $legacy=$item.PSObject.Properties['Target']
    if ($null -ne $legacy -and $legacy.Value) { return [string]($legacy.Value | Select-Object -First 1) }
    return $null
}
# Symbolic link first (works across volumes), then a fallback that needs no rights: a hard link for a
# file, a junction for a folder. A junction keeps a whole folder in one place without elevation.
function NewLink([string]$Target,[string]$LinkPath,[switch]$Container) {
    $parent=Split-Path -Parent $LinkPath
    if ($parent) { $null=New-Item -ItemType Directory -Path $parent -Force }
    $symbolicError=''
    try {
        $null=New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop
        return 'Symbolic'
    } catch { $symbolicError=$_.Exception.Message }
    if ($Container) {
        try {
            $null=New-Item -ItemType Junction -Path $LinkPath -Target $Target -ErrorAction Stop
            return 'Junction'
        } catch {
            throw ("Could not link the folder '$LinkPath' to '$Target'. A folder symbolic link needs administrator " +
                "rights or Developer Mode; a junction needs a local volume. Symbolic: $symbolicError Junction: $($_.Exception.Message)")
        }
    }
    try {
        $null=New-Item -ItemType HardLink -Path $LinkPath -Target $Target -ErrorAction Stop
        return 'Hard'
    } catch {
        throw ("Could not link '$LinkPath' to '$Target'. A file symbolic link needs administrator rights or Developer Mode; " +
            "a hard link needs both paths on the same volume. Symbolic: $symbolicError Hard: $($_.Exception.Message)")
    }
}
# Removes whatever sits where a link belongs. Duplicate bytes are dropped so the space comes back;
# anything the source does not carry identically is kept in the recovery folder first.
function ClearForLink([string]$SourceRoot,[string]$DestinationRoot,[string]$Relative) {
    $linkPath=LocalPath $DestinationRoot $Relative
    $existing=Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $existing) { return }
    if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        # Remove the link itself: Remove-Item -Recurse on a folder link would follow it and empty the target.
        if ($existing.PSIsContainer) { [IO.Directory]::Delete($linkPath,$false) } else { [IO.File]::Delete($linkPath) }
        return
    }
    if (-not $existing.PSIsContainer) {
        Recover $DestinationRoot $Relative (Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash
        Remove-Item -LiteralPath $linkPath -Force
        return
    }
    $removed=0; $kept=0
    $items=@(Get-ChildItem -LiteralPath $linkPath -Recurse -Force -ErrorAction Stop)
    foreach ($item in $items) {
        if ($item.PSIsContainer) { continue }
        $sub=$item.FullName.Substring($DestinationRoot.Length+1).Replace('\','/')
        $sourceCopy=LocalPath $SourceRoot $sub
        $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        if ((Test-Path -LiteralPath $sourceCopy -PathType Leaf) -and
            (Get-FileHash -LiteralPath $sourceCopy -Algorithm SHA256).Hash -eq $hash) {
            Remove-Item -LiteralPath $item.FullName -Force
            $removed++
            continue
        }
        Recover $DestinationRoot $sub $hash
        Remove-Item -LiteralPath $item.FullName -Force
        $kept++
    }
    Remove-Item -LiteralPath $linkPath -Recurse -Force
    if ($removed -gt 0 -or $kept -gt 0) {
        Write-Host ("Replaced the real folder '{0}': {1} duplicate file(s) removed, {2} other file(s) kept in .backup_sync_recovery." -f $Relative,$removed,$kept)
    }
}
function WriteState([string]$Root,[string]$Json) {
    $path=Join-Path $Root 'backup_version.txt'
    $temp=Join-Path $Root ('.backup-sync-tmp-'+[guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temp,$Json,(New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path) {
            Recover $Root 'backup_version.txt' (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            [IO.File]::Replace($temp,$path,[System.Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temp,$path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
# Parse the same rule format for normal sync and initialization.
function SetSelectionRules([string[]]$Lines,[int]$Start=0) {
    $script:Includes=@(); $script:Excludes=@(); $script:LinkRules=@()
    for ($i=$Start; $i -lt $Lines.Count; $i++) {
        $line=$Lines[$i].Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^[+\-$].+') { throw "Invalid selection rule: $line" }
        $pattern=$line.Substring(1).Trim().Replace('\','/').TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($pattern) -or $pattern.StartsWith('/') -or $pattern -match '^[A-Za-z]:' -or ($pattern -split '/') -contains '..') {
            throw "Rules must be relative paths without a drive letter or '..': $line"
        }
        if ($line[0] -eq '+') { $script:Includes+=$pattern }
        elseif ($line[0] -eq '-') { $script:Excludes+=$pattern }
        else { $script:LinkRules+=$pattern }
    }
}

function InitializeSource([string]$Source,[string]$Destination) {
    $init=Join-Path $Destination 'backup_init.txt'
    $version=Join-Path $Source 'backup_version.txt'
    if ((Test-Path -LiteralPath $version) -or -not (Test-Path -LiteralPath $init -PathType Leaf)) { return }
    Write-Host "`nDestination initialization rules found: $init"
    if ((Ask "Initialize source '$Source' by copying matching files from '$Destination'?" @('Y','N')) -eq 'N') {
        Write-Host 'Initialization skipped; continuing setup.'
        return
    }
    $initLocks=New-Object 'Collections.Generic.List[IDisposable]'
    $script:RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-init-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    try {
        foreach ($root in @($Source,$Destination) | Sort-Object) {
            if (((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Initialization roots cannot be links/junctions.' }
            $initLocks.Add([IO.File]::Open((Join-Path $root '.backup_sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))
        }
        if (Test-Path -LiteralPath $version) { throw 'Source version file appeared during review; rerun setup.' }
        $initHash=(Get-FileHash -LiteralPath $init -Algorithm SHA256).Hash
        SetSelectionRules @(Get-Content -LiteralPath $init -Encoding UTF8)
        $from=Snapshot $Destination; $to=Snapshot $Source
        $plan=New-Object 'Collections.Generic.List[object]'
        foreach ($key in @($from.Files.Keys | Sort-Object)) {
            $fromHash=Hash $from.Files $key; $toHash=Hash $to.Files $key
            if ($fromHash -eq $toHash) { continue }
            if ($null -ne $toHash) {
                Write-Host "`nINITIALIZATION CONFLICT: $key" -ForegroundColor Yellow
                $choice=Ask 'Use (D)estination, keep (S)ource, or (A)bort setup' @('D','S','A')
                if ($choice -eq 'A') { throw 'Initialization cancelled before any files were copied.' }
                if ($choice -eq 'S') { continue }
            }
            $plan.Add(@{Path=$key; FromHash=$fromHash; ToHash=$toHash})
        }
        # Check both complete selected views again after interactive review.
        $checkFrom=Snapshot $Destination $from.Files; $checkTo=Snapshot $Source $to.Files
        foreach ($side in @(@{Old=$from.Files; New=$checkFrom.Files},@{Old=$to.Files; New=$checkTo.Files})) {
            if ($side.Old.Count -ne $side.New.Count) { throw 'Files changed during initialization review. Rerun setup.' }
            foreach ($key in $side.Old.Keys) {
                if ((Hash $side.Old $key) -ne (Hash $side.New $key)) { throw "File changed during initialization review: $key" }
            }
        }
        AssertCurrent $init $initHash
        if (Test-Path -LiteralPath $version) { throw 'Source version file appeared during review; rerun setup.' }
        foreach ($op in $plan) { CopyChecked $Destination $Source $op.Path $op.FromHash $op.ToHash }
        foreach ($key in @($from.Dirs.Keys | Sort-Object)) {
            $null=New-Item -ItemType Directory -Path (LocalPath $Source $key) -Force
        }
        Write-Host "Initialization complete: $($plan.Count) file(s) copied from destination to source."
        Write-Host 'No files were deleted. The normal sync will establish its own version baseline.'
    } finally { foreach ($handle in $initLocks) { $handle.Dispose() } }
}