<#
Check-CanvasYaml.ps1

Usage examples:
  ./scripts/Check-CanvasYaml.ps1 -ConfigPath ".config/canvas-naming-rules.json" -Paths @("appsource/App1/src/Screens.yaml","appsource/App2/src/App.yaml")

  ./scripts/Check-CanvasYaml.ps1 -ConfigPath ".config/canvas-naming-rules.json" -Root "appsource"
#>

param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [string[]]$Paths,

    [string]$Root = ""
)

$failCount = 0
$warnCount = 0
$failures = @()
$warnings = @()

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Control prefix lookup: controlType(lower) -> prefix
$prefixByName = @{}
foreach ($c in $config.controls) { $prefixByName[$c.name.ToLower()] = $c.value }

$varPrefix = $config.variables.globalPrefix
$locPrefix = $config.variables.contextPrefix
$colPrefix = $config.variables.collectionPrefix
$checkNumericSuffix = [bool]$config.rules.disallowNumericSuffix

function Write-Fail {
    param(
        [string]$File,
        [int]$LineNumber,
        [string]$Name,
        [string]$Reason
    )
    $failure = [PSCustomObject]@{
        File = $file;
        Line = $LineNumber;
        Name = $Name;
        Error = $Reason;
    }
    $script:failures += $failure
    Write-Host ("{0}  {1,6}  {2,-50}  FAIL  {3}" -f $File, $LineNumber, $Name, $Reason) -ForegroundColor Red
    return $failure
}

function Write-Warn {
    param(
        [string]$File,
        [int]$LineNumber,
        [string]$Name,
        [string]$Reason
    )
    $warning = [PSCustomObject]@{
        File = $file;
        Line = $LineNumber;
        Name = $Name;
        Error = $Reason;
    }
    $script:warnings += $warning
    Write-Host ("{0}  {1,6}  {2,-50}  WARN  {3}" -f $File, $LineNumber, $Name, $Reason) -ForegroundColor Yellow
}

function Get-ControlNameFromAboveLine {
    param([string[]]$Lines,[int]$ControlLineIndex)

    for ($j = $ControlLineIndex - 1; $j -ge 0; $j--) {
        $l = $Lines[$j]
        if ($l -match '^\s*(?:-\s*)?(.+?)\s*:\s*$') {
            $key = $Matches[1].Trim()
            if ($key -in @('Children','Properties','Screens','Variant','MetadataKey')) { continue }
            return $key
        }
    }
    return $null
}

# Regexes for var/loc/col checks
$rxSet           = [regex]'(?i)\bSet\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,'
$rxClearCollect  = [regex]'(?i)\bClearCollect\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,'
$rxCollect       = [regex]'(?i)\bCollect\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,'
$rxUpdateContext = [regex]'(?i)\bUpdateContext\s*\(\s*\{([^}]*)\}'

# Resolve file list
$fileList = New-Object System.Collections.Generic.List[string]

if ($Paths -and $Paths.Count -gt 0) {
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p) { $fileList.Add((Resolve-Path $p).Path) }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($Root)) {
    if (-not (Test-Path -LiteralPath $Root)) { throw "Root not found: $Root" }

    # Scan: appsource/{appname}/src/**/*.yml|yaml
    Get-ChildItem -Path $Root -Directory -ErrorAction Stop |
        ForEach-Object {
            $src = Join-Path $_.FullName "Src"
            if (Test-Path $src) {
                Get-ChildItem -Path $src -Recurse -File -Include *.yml,*.yaml -ErrorAction SilentlyContinue
            }
        } |
        ForEach-Object { $fileList.Add($_.FullName) }
}
else {
    throw "Provide either -Paths or -Root"
}

if ($fileList.Count -eq 0) {
    Write-Host "No YAML files found to scan."
    exit 0
}



foreach ($file in $fileList) {
    $lines = Get-Content -LiteralPath $file

    # A) Control naming checks
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*Control:\s*([A-Za-z0-9_\/]+)\@') {
            $controlType = $Matches[1]
            $controlKey = $controlType.ToLower().Replace("classic/","")
            $controlName = Get-ControlNameFromAboveLine -Lines $lines -ControlLineIndex $i
            $lineNo = $i + 1

            if ([string]::IsNullOrWhiteSpace($controlName)) {
                $failCount++
                Write-Fail -File $file -LineNumber $lineNo -Name "<unknown>" -Reason ("Could not find control name above Control: {0}" -f $controlType)

                
                continue
            }

            $expectedPrefix = $null
            if ($prefixByName.ContainsKey($controlKey)) {
                $expectedPrefix = $prefixByName[$controlKey]
            } else {
                $warnCount++
                Write-Warn -File $file -LineNumber $lineNo -Name $controlName -Reason ("no prefix mapping for Control: {0}" -f $controlType)
            }

            $reasons = New-Object System.Collections.Generic.List[string]

            if (-not [string]::IsNullOrWhiteSpace($expectedPrefix)) {
                if (-not $controlName.ToLower().StartsWith($expectedPrefix.ToLower())) {
                    $reasons.Add(("PREFIX expected '{0}' for Control '{1}'" -f $expectedPrefix, $controlType))
                }
            }

            if ($checkNumericSuffix -and ($controlName -match '_\d+$')) {
                $reasons.Add("SUFFIX ends with _nn")
            }

            if ($reasons.Count -gt 0) {
                $failCount++
                Write-Fail -File $file -LineNumber $lineNo -Name $controlName -Reason ($reasons -join "; ")
            }
        }
    }

    # B) Variable / context / collection checks (per-line regex)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNo = $i + 1

        foreach ($m in $rxSet.Matches($line)) {
            $name = $m.Groups[1].Value
            if (-not $name.ToLower().StartsWith($varPrefix.ToLower())) {
                $failCount++
                Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason ("VAR PREFIX expected '{0}' (Set())" -f $varPrefix)
            }
        }

        foreach ($m in $rxClearCollect.Matches($line)) {
            $name = $m.Groups[1].Value
            if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) {
                $failCount++
                Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason ("COL PREFIX expected '{0}' (ClearCollect())" -f $colPrefix)
            }
        }

        foreach ($m in $rxCollect.Matches($line)) {
            $name = $m.Groups[1].Value
            if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) {
                $failCount++
                Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason ("COL PREFIX expected '{0}' (Collect())" -f $colPrefix)
            }
        }

        foreach ($m in $rxUpdateContext.Matches($line)) {
            $inner = $m.Groups[1].Value
            $keyMatches = [regex]::Matches($inner, '([A-Za-z_][A-Za-z0-9_]*)\s*:')
            foreach ($km in $keyMatches) {
                $key = $km.Groups[1].Value
                if (-not $key.ToLower().StartsWith($locPrefix.ToLower())) {
                    $failCount++
                    Write-Fail -File $file -LineNumber $lineNo -Name $key -Reason ("LOC PREFIX expected '{0}' (UpdateContext())" -f $locPrefix)
                }
            }
        }
    }
}

# --- GitHub Actions Step Summary (Markdown) ---
# Build a per-file aggregation of warnings and failures
$countsByFile = @{}
foreach ($w in $warnings) {
    if (-not $countsByFile.ContainsKey($w.File)) {
        $countsByFile[$w.File] = [PSCustomObject]@{ Warnings = 0; Errors = 0 }
    }
    $countsByFile[$w.File].Warnings++
}
foreach ($f in $failures) {
    if (-not $countsByFile.ContainsKey($f.File)) {
        $countsByFile[$f.File] = [PSCustomObject]@{ Warnings = 0; Errors = 0 }
    }
    $countsByFile[$f.File].Errors++
}

function Escape-MarkdownPipe {
    param([string]$s)
    # Escape '|' to prevent table column breaks
    return $s -replace '\|','\|'
}

$stepSummaryPath = $env:GITHUB_STEP_SUMMARY
if ([string]::IsNullOrWhiteSpace($stepSummaryPath)) {
    Write-Host "GITHUB_STEP_SUMMARY not set. Skipping Action summary markdown."
} else {
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("# Canvas YAML Naming Check Summary")
    $lines.Add("")
    $lines.Add(("**Files scanned:** {0} &nbsp;&nbsp; **Failures:** {1} &nbsp;&nbsp; **Warnings:** {2}" -f $fileList.Count, $failCount, $warnCount))
    $lines.Add("")
    $lines.Add("| File | Warnings | Errors |")
    $lines.Add("|--|--:|--:|")

    if ($countsByFile.Count -gt 0) {
        foreach ($kvp in $countsByFile.GetEnumerator() | Sort-Object { $_.Key }) {
            $fileName = Escape-MarkdownPipe $kvp.Key
            $w = $kvp.Value.Warnings
            $e = $kvp.Value.Errors
            $lines.Add(("| {0} | {1} | {2} |" -f $fileName, $w, $e))
        }
    } else {
        $lines.Add("| _No issues found_ | 0 | 0 |")
    }

    # Optional: Collapsible detail sections
    if ($countsByFile.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Details")
        foreach ($fileKey in ($countsByFile.Keys | Sort-Object)) {
            $fileHeader = Escape-MarkdownPipe $fileKey
            $lines.Add("")
            $lines.Add("<details>")
            $lines.Add("<summary><strong>$fileHeader</strong></summary>")
            $lines.Add("")
            # Per-file warnings
            $fileWarnings = $warnings | Where-Object { $_.File -eq $fileKey }
            if ($fileWarnings.Count -gt 0) {
                $lines.Add("**Warnings**")
                $lines.Add("")
                $lines.Add("| Line | Name | Message |")
                $lines.Add("|--:|--|--|")
                foreach ($w in $fileWarnings) {
                    $nm = Escape-MarkdownPipe $w.Name
                    $msg = Escape-MarkdownPipe $w.Error
                    $lines.Add(("| {0} | {1} | {2} |" -f $w.Line, $nm, $msg))
                }
                $lines.Add("")
            }
            # Per-file errors
            $fileErrors = $failures | Where-Object { $_.File -eq $fileKey }
            if ($fileErrors.Count -gt 0) {
                $lines.Add("**Errors**")
                $lines.Add("")
                $lines.Add("| Line | Name | Message |")
                $lines.Add("|--:|--|--|")
                foreach ($e in $fileErrors) {
                    $nm = Escape-MarkdownPipe $e.Name
                    $msg = Escape-MarkdownPipe $e.Error
                    $lines.Add(("| {0} | {1} | {2} |" -f $e.Line, $nm, $msg))
                }
                $lines.Add("")
            }
            $lines.Add("</details>")
        }
    }

    $lines.Add("")

    # Append to GITHUB_STEP_SUMMARY
    $content = [string]::Join([Environment]::NewLine, $lines)
    $content | Out-File -FilePath $stepSummaryPath -Encoding utf8 -Append
}

Write-Host ""
Write-Host ("Completed. Files scanned: {0}   Failures: {1}   Warnings: {2}" -f $fileList.Count, $failCount, $warnCount)


exit ([int]($failCount -gt 0))