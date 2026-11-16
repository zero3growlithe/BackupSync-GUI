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

# A template decides the pair's rules, but a link that was just created must stay a link: any '$' rule
# the template forgets is appended, because a configuration without it would trip over its own links.
function Add-MissingLinkRules($Lines, [string[]]$RuleLines, [switch]$Report) {
    if ($null -eq $RuleLines -or $RuleLines.Count -eq 0) { return }
    $present = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#') -or $trimmed.Length -lt 2) { continue }
        $present.Add($trimmed.Substring(1).Trim().Replace('\', '/').TrimEnd('/'))
    }
    foreach ($line in $RuleLines) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -lt 2 -or $trimmed[0] -ne '$') { continue }
        $pattern = $trimmed.Substring(1).Trim().Replace('\', '/').TrimEnd('/')
        if ($present -contains $pattern) { continue }
        $Lines.Add('$' + $pattern)
        if ($Report) { Write-Host "Added the link rule '$pattern' to the configuration so the created links keep working." }
    }
}

# The lines BackupSync.ps1 will read: destination, optional executable, optional delay, then rules.
function Build-ConfigurationLines([string]$SourcePath, [string]$DestinationPath, [string[]]$RuleLines, [string[]]$Template, [switch]$Report) {
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
        Add-MissingLinkRules $lines $RuleLines -Report:$Report
    } else {
        $lines.Add($DestinationPath); $lines.Add(''); $lines.Add('10')
        foreach ($line in $RuleLines) { $lines.Add($line) }
    }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines.RemoveAt($lines.Count - 1) }
    # Both settings slots always exist, so the trailing "# Script:" comment can never be read as one.
    $slots = 0
    $scan = 1
    while ($scan -lt $lines.Count -and $lines[$scan] -notmatch '^\s*[+\-$]') { $slots++; $scan++ }
    if ($slots -lt 2) {
        $insertAt = 1 + $slots
        $padding = $(if ($slots -eq 0) { @('', '10') } else { @('10') })
        foreach ($line in $padding) { $lines.Insert($insertAt, $line); $insertAt++ }
    }
    ,$lines.ToArray()
}

# The same positional read BackupSync.ps1 performs, so a bad template is rejected before any file moves.
function Test-ConfigurationShape([string[]]$Lines) {
    if ($Lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Lines[0])) { return 'It has no destination line.' }
    $index = 1
    $slots = 0
    while ($index -lt $Lines.Count -and $Lines[$index] -notmatch '^\s*[+\-$]') {
        if ($Lines[$index].Trim().StartsWith('#')) {
            # Once both settings are there, a comment simply starts the rules section.
            if ($slots -ge 2) { break }
            return "Line $($index + 1) is a comment where the configuration needs the executable or the delay. Comments belong below the settings."
        }
        $slots++
        if ($slots -gt 2) {
            return "Line $($index + 1) is an extra settings line. A configuration holds the destination, an optional executable, an optional delay, and then only rules."
        }
        if ($slots -eq 2) {
            $candidate = $Lines[$index].Trim()
            if ($candidate -ne '' -and $candidate -notmatch '^\d+$') {
                return "Line $($index + 1) has to be the delay in whole seconds, but reads '$candidate'."
            }
        }
        $index++
    }
    for ($i = $index; $i -lt $Lines.Count; $i++) {
        $trimmed = $Lines[$i].Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^[+\-$].+') { return "Line $($i + 1) is not a rule: '$trimmed'." }
    }
    return $null
}

# Writes <source>\backup_setup.txt from the lines Build-ConfigurationLines produced.
function Write-PairConfiguration([string]$SourcePath, [string]$DestinationPath, [string]$Path, [string[]]$Lines) {
    $all = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $Lines) { $all.Add($line) }
    $all.Add('# Script: ' + (Join-Path $PSScriptRoot 'BackupSync.ps1'))

    $text = ($all -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))

    $written = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    if ($written.Count -eq 0 -or [string]::IsNullOrWhiteSpace($written[0])) { throw 'The configuration was written without a destination line.' }
    $check = [Environment]::ExpandEnvironmentVariables($written[0].Trim().Trim('"'))
    if (-not [IO.Path]::IsPathRooted($check)) { $check = Join-Path $SourcePath $check }
    if ((FullPath $check) -ne $DestinationPath) {
        throw "The configuration does not point at the destination on line 1 (found '$($written[0])')."
    }
    $problem = Test-ConfigurationShape $written
    if ($problem) { throw "The configuration written from the template cannot be read by the sync engine. $problem" }
    $Path
}

# Windows only lets administrators create file symbolic links unless Developer Mode is on, and a hard
# link needs both paths on one volume. The remaining set goes to a single elevated helper, so the user
# answers one permission prompt instead of one per file.
function New-LinkElevated([string]$SourcePath, [string]$DestinationPath, [string[]]$Patterns) {
    $helper = Join-Path $PSScriptRoot 'New-SyncLinks.ps1'
    if (-not (Test-Path -LiteralPath $helper)) {
        throw "Administrator rights are needed to create the links, but $helper is missing from the scripts folder."
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Patterns -join "`n")))
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $shell)) { $shell = 'powershell.exe' }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $helper + '"'),
        '-Source', ('"' + $SourcePath + '"'), '-Destination', ('"' + $DestinationPath + '"'), '-LinkRulesBase64', $encoded)
    Write-Host 'A Windows permission prompt is opening now: creating symbolic links needs administrator rights.'
    try {
        $process = Start-Process -FilePath $shell -ArgumentList $arguments -Verb RunAs -PassThru -Wait -ErrorAction Stop
    } catch {
        throw ('Creating symbolic links needs administrator rights, and Windows did not grant them (' +
            $_.Exception.Message + '). Turn on Developer Mode, or run this copy as administrator.')
    }
    if ($null -eq $process) { throw 'The permission prompt did not start the link helper.' }
    if ($process.ExitCode -ne 0) {
        throw ("The elevated link helper stopped with exit code $($process.ExitCode). Turn on Developer Mode, " +
            'or run this copy as administrator.')
    }
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

    # A template that cannot become a configuration is refused now, not after copying gigabytes.
    $configurationPath = Join-Path $Source 'backup_setup.txt'
    $plannedLines = Build-ConfigurationLines $Source $Destination $ruleLines $template
    $plannedProblem = Test-ConfigurationShape $plannedLines
    if ($plannedProblem) { throw "The setup file's backup_setup.txt template cannot be used. $plannedProblem" }

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
    $pending = New-Object 'Collections.Generic.List[string]'
    foreach ($rel in $links) {
        $target = LocalPath $Source $rel
        $linkPath = LocalPath $Destination $rel
        $existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            if ($null -eq (LinkTargetOf $linkPath)) {
                # a previous copy put real bytes there: keep them in recovery before replacing them
                Recover $Destination $rel (Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash
            }
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        }
        try {
            $kind = NewLink $target $linkPath
        } catch {
            # Both a symbolic and a hard link were refused: this path needs administrator rights.
            $pending.Add($rel)
            continue
        }
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash -ne $targetHash) {
            throw "Link verification failed: $rel"
        }
        $linked++
        Write-Host "Linked ($kind) $rel -> $Source"
    }
    if ($pending.Count -gt 0) {
        Write-Host ("Windows refused {0} link(s) for lack of rights." -f $pending.Count)
        New-LinkElevated $Source $Destination @($script:LinkRules)
        foreach ($rel in $pending) {
            $linkPath = LocalPath $Destination $rel
            $target = LocalPath $Source $rel
            if (-not (Test-Path -LiteralPath $linkPath)) {
                throw "The link for '$rel' was not created even with administrator rights."
            }
            if ((Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
                throw "Link verification failed after elevation: $rel"
            }
            $linked++
            Write-Host "Linked $rel -> $Source"
        }
    }
    foreach ($rel in $dirs) { $null = New-Item -ItemType Directory -Path (LocalPath $Destination $rel) -Force }

    if ($readSetup) { AssertCurrent $SetupFile $setupHash }
    $finalLines = Build-ConfigurationLines $Source $Destination $ruleLines $template -Report
    $configurationPath = Write-PairConfiguration $Source $Destination $configurationPath $finalLines

    Write-Host ''
    Write-Host ("Synced copy complete: {0} file(s) copied, {1} link(s) created, {2} folder(s) created." -f $files.Count, $linked, $dirs.Count)
    Write-Host "Configuration: $configurationPath"
    Write-Host 'No version baseline was written; the first sync establishes it.'
    exit 0
} catch {
    Write-Host "Create synced copy stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally { foreach ($handle in $locks) { $handle.Dispose() } }
