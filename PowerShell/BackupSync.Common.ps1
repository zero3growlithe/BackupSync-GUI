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
    ($parts[0] -in @('backup_setup.txt','backup_init.txt','backup_version.txt','.backup_sync_recovery','.backup_sync.lock') -or
        $parts[-1] -like '*.backup-sync.lnk' -or $parts[-1] -like '.backup-sync-tmp-*')
}
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
function Selected([string]$Path) {
    if (Reserved $Path) { return $false }
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
function Snapshot([string]$Root) {
    $files=@{}; $dirs=@{}; $stack=New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop)) {
            $rel=$item.FullName.Substring($Root.Length+1).Replace('\','/')
            if (Reserved $rel) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Link/junction encountered: $($item.FullName). Move it outside this sync tree."
            }
            if ($item.PSIsContainer) {
                $stack.Push($item.FullName)
                if (Selected $rel) { $dirs[$rel]=$true }
            } elseif (Selected $rel) {
                $before=Get-Item -LiteralPath $item.FullName -Force
                $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                $after=Get-Item -LiteralPath $item.FullName -Force
                if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc) {
                    throw "File changed while scanning: $($item.FullName)"
                }
                $files[$rel]=@{Hash=$hash; Length=$after.Length; Modified=$after.LastWriteTimeUtc.ToString('o')}
            }
        }
    }
    @{Files=$files; Dirs=$dirs}
}
function Hash($Files,[string]$Key) { if ($Files.ContainsKey($Key)) { [string]$Files[$Key].Hash } else { $null } }
function ReadState([string]$Root) {
    $p=Join-Path $Root 'backup_version.txt'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $obj=Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($obj.Schema -ne 1) { throw "Unsupported version file at $Root" }
    $files=@{}; $computers=@{}
    foreach ($prop in $obj.Files.PSObject.Properties) {
        $null=LocalPath $Root $prop.Name
        $files[$prop.Name]=@{Hash=[string]$prop.Value.Hash}
    }
    foreach ($prop in $obj.Computers.PSObject.Properties) { $computers[$prop.Name]=[long]$prop.Value }
    @{PairId=[string]$obj.PairId; Generation=[long]$obj.Generation; Files=$files; Computers=$computers;
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
        Write-Host "Copied $Relative -> $ToRoot"
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
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
    $script:Includes=@(); $script:Excludes=@()
    for ($i=$Start; $i -lt $Lines.Count; $i++) {
        $line=$Lines[$i].Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^[+-].+') { throw "Invalid selection rule: $line" }
        $pattern=$line.Substring(1).Trim().Replace('\','/').TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($pattern) -or $pattern.StartsWith('/') -or $pattern.Contains(':') -or ($pattern -split '/') -contains '..') {
            throw "Rules must be relative paths without '..': $line"
        }
        if ($line[0] -eq '+') { $script:Includes+=$pattern } else { $script:Excludes+=$pattern }
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
        $checkFrom=Snapshot $Destination; $checkTo=Snapshot $Source
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