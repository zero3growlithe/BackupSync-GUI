#requires -Version 5.1
<#
.SYNOPSIS
    Creates the first copy of a folder pair without asking any questions.

.DESCRIPTION
    The desktop front-end collects the answers in dialogs, so this helper does the work of the
    "Create synced copy" button: it reads create_copy_setup.txt from the source folder, copies every
    selected file, creates a link instead of a copy for every '$' rule, and writes the pair's
    backup_setup.txt so the ordinary sync can take over from there.

    create_copy_setup.txt uses the same rule syntax as backup_init.txt and backup_setup.txt:

        +Saves              include (no '+' rules at all means "everything")
        -**/cache/**        exclude
        $**/roms/**         do not copy; the destination keeps a link to the source file

    A template for the pair's configuration may follow a marker line:

        # backup_setup.txt template
        {Destination}

        Steam.exe
        10
        +Saves
        # end backup_setup.txt

    '{Destination}' and '{Source}' are replaced. When the template's first effective line is not a
    rooted path, the destination, an empty executable slot and the default delay are prepended. With
    no template, the setup file's own rules become the pair's rules.

.PARAMETER CopyAll
    Ignore create_copy_setup.txt entirely and copy every file, as if the file did not exist.

.PARAMETER SetupFile
    A different setup file to read instead of <source>\create_copy_setup.txt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$SetupFile,
    [switch]$CopyAll
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupSync.Common.ps1')

$locks = New-Object 'Collections.Generic.List[IDisposable]'
$script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-copy-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

function Test-TemplateStart([string]$Line) {
    $Line -match '^\s*#\s*-*\s*(backup_setup|backup_sync)(\.txt)?\s*(template)?\s*-*\s*$'
}
function Test-TemplateEnd([string]$Line) {
    $Line -match '^\s*#\s*-*\s*end\s+(backup_setup|backup_sync)(\.txt)?\s*-*\s*$'
}

# Splits the setup file into rule lines (everything outside the template block) and the template body.
function Split-SetupFile([string[]]$Lines) {
    $rules = New-Object 'Collections.Generic.List[string]'
    $template = New-Object 'Collections.Generic.List[string]'
    $inTemplate = $false
    $sawTemplate = $false
    foreach ($line in $Lines) {
        if ($inTemplate) {
            if (Test-TemplateEnd $line) { $inTemplate = $false; continue }
            $template.Add($line)
            continue
        }
        if (Test-TemplateStart $line) { $inTemplate = $true; $sawTemplate = $true; continue }
        $rules.Add($line)
    }
    if ($inTemplate) { throw 'The template in the setup file has no closing "# end backup_setup.txt" line.' }
    @{Rules = $rules.ToArray(); Template = $(if ($sawTemplate) { $template.ToArray() } else { $null }) }
}

function Expand-Template([string[]]$Lines, [string]$SourcePath, [string]$DestinationPath) {
    $expanded = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        $expanded.Add($line.Replace('{Destination}', $DestinationPath).Replace('{Source}', $SourcePath))
    }
    $expanded.ToArray()
}

function Test-DestinationLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    $value = [Environment]::ExpandEnvironmentVariables($Line.Trim().Trim('"'))
    [IO.Path]::IsPathRooted($value) -or $value.StartsWith('\\')
}

# Writes <source>\backup_setup.txt, then reads it back the way the engine does to prove it is usable.
function Write-PairConfiguration([string]$SourcePath, [string]$DestinationPath, [string[]]$RuleLines, [string[]]$Template) {
    $lines = New-Object 'Collections.Generic.List[string]'
    if ($null -ne $Template) {
        $rendered = Expand-Template $Template $SourcePath $DestinationPath
        $first = ''
        foreach ($candidate in $rendered) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Trim().StartsWith('#')) { continue }
            $first = $candidate
            break
        }
        if (Test-DestinationLine $first) {
            foreach ($line in $rendered) { $lines.Add($line) }
        } else {
            # No destination of its own: the template only carries the settings and rules.
            $lines.Add($DestinationPath); $lines.Add(''); $lines.Add('10')
            foreach ($line in $rendered) { $lines.Add($line) }
        }
    } else {
        $lines.Add($DestinationPath); $lines.Add(''); $lines.Add('10')
        foreach ($line in $RuleLines) { $lines.Add($line) }
    }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines.RemoveAt($lines.Count - 1) }
    $lines.Add('# Script: ' + (Join-Path $PSScriptRoot 'BackupSync.ps1'))

    $path = Join-Path $SourcePath 'backup_setup.txt'
    $text = ($lines -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true)))

    # Same positional parse as BackupSync.ps1, so a template that cannot work fails here and not later.
    $written = @(Get-Content -LiteralPath $path -Encoding UTF8)
    if ($written.Count -eq 0 -or [string]::IsNullOrWhiteSpace($written[0])) { throw 'The configuration was written without a destination line.' }
    $check = [Environment]::ExpandEnvironmentVariables($written[0].Trim().Trim('"'))
    if (-not [IO.Path]::IsPathRooted($check)) { $check = Join-Path $SourcePath $check }
    if ((FullPath $check) -ne $DestinationPath) {
        throw "The template did not produce the destination on line 1 (found '$($written[0])')."
    }
    $path
}

try {
    $Source = FullPath (Resolve-Path -LiteralPath $Source).ProviderPath
    $Destination = FullPath (Resolve-Path -LiteralPath $Destination).ProviderPath
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw 'Source must be a folder.' }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw 'Destination must be an existing folder.' }
    if ($Source -eq $Destination -or $Source.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $Destination.StartsWith($Source + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and destination must be separate, non-nested folders.'
    }
    foreach ($root in @($Source, $Destination)) {
        if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { throw 'Use dedicated folders, not drive/share roots.' }
        if (((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Copy roots cannot be links/junctions.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($SetupFile)) { $SetupFile = Join-Path $Source 'create_copy_setup.txt' }
    $ruleLines = @()
    $template = $null
    $readSetup = $false
    $setupHash = $null
    if (-not $CopyAll -and (Test-Path -LiteralPath $SetupFile -PathType Leaf)) {
        $readSetup = $true
        $setupHash = (Get-FileHash -LiteralPath $SetupFile -Algorithm SHA256).Hash
        $split = Split-SetupFile @(Get-Content -LiteralPath $SetupFile -Encoding UTF8)
        $ruleLines = @($split.Rules)
        $template = $split.Template
        Write-Host "Setup file: $SetupFile"
    } elseif ($CopyAll) {
        Write-Host 'Copying every file: the setup file is ignored.'
    } else {
        Write-Host 'No create_copy_setup.txt found: copying every file.'
    }

    SetSelectionRules $ruleLines
    Write-Host ("Rules: {0} include, {1} exclude, {2} link." -f $script:Includes.Count, $script:Excludes.Count, $script:LinkRules.Count)

    foreach ($root in @($Source, $Destination) | Sort-Object) {
        $locks.Add([IO.File]::Open((Join-Path $root '.backup_sync.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
    }

    # ── Walk the source ───────────────────────────────────────────────────
    $files = New-Object 'Collections.Generic.List[string]'
    $links = New-Object 'Collections.Generic.List[string]'
    $dirs = New-Object 'Collections.Generic.List[string]'
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($Source)
    while ($stack.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop)) {
            $rel = $item.FullName.Substring($Source.Length + 1).Replace('\', '/')
            if (Reserved $rel) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (IsLinked $rel) { continue }
                throw "Link/junction encountered: $($item.FullName). Move it outside this folder."
            }
            if ($item.PSIsContainer) {
                $stack.Push($item.FullName)
                if (Selected $rel) { $dirs.Add($rel) }
            } elseif (IsLinked $rel) { $links.Add($rel) }
            elseif (Selected $rel) { $files.Add($rel) }
        }
    }

    # ── Copy the selected files, then create the links ────────────────────
    foreach ($rel in $files) {
        $from = LocalPath $Source $rel
        $hash = (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
        $toHash = $null
        $existing = Get-Item -LiteralPath (LocalPath $Destination $rel) -Force -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            if ($null -ne (LinkTargetOf $existing.FullName)) {
                # a link sits where a real copy belongs now: drop it, the copy below recreates the path
                Remove-Item -LiteralPath $existing.FullName -Force
            } else {
                $toHash = (Get-FileHash -LiteralPath $existing.FullName -Algorithm SHA256).Hash
            }
        }
        CopyChecked $Source $Destination $rel $hash $toHash
    }
    $linked = 0
    foreach ($rel in $links) {
        $target = LocalPath $Source $rel
        $linkPath = LocalPath $Destination $rel
        $existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            if ($null -eq (LinkTargetOf $linkPath)) {
                # a previous copy put real bytes there: keep them in recovery before replacing them
                Recover $Destination $rel (Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash
            }
            Remove-Item -LiteralPath $linkPath -Force
        }
        $kind = NewLink $target $linkPath
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash -ne $targetHash) {
            throw "Link verification failed: $rel"
        }
        $linked++
        Write-Host "Linked ($kind) $rel -> $Source"
    }
    foreach ($rel in $dirs) { $null = New-Item -ItemType Directory -Path (LocalPath $Destination $rel) -Force }

    if ($readSetup) { AssertCurrent $SetupFile $setupHash }
    $configurationPath = Write-PairConfiguration $Source $Destination $ruleLines $template

    Write-Host ''
    Write-Host ("Synced copy complete: {0} file(s) copied, {1} link(s) created, {2} folder(s) created." -f $files.Count, $linked, $dirs.Count)
    Write-Host "Configuration: $configurationPath"
    Write-Host 'No version baseline was written; the first sync establishes it.'
    exit 0
} catch {
    Write-Host "Create synced copy stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally { foreach ($handle in $locks) { $handle.Dispose() } }
