param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [string[]]$Paths,

    [string]$Root = ""
)

if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# --- Prefix lookups ---
$prefixByName = @{}
foreach ($c in $config.controls) { $prefixByName[$c.name.ToLower()] = $c.value }

$varPrefix = $config.variables.globalPrefix
$locPrefix = $config.variables.contextPrefix
$colPrefix = $config.variables.collectionPrefix
$checkNumericSuffix = [bool]$config.rules.disallowNumericSuffix

# --- Lists for issues ---
$failList = @()
$warnList = @()

function Write-Fail { param($File, $LineNumber, $Name, $Reason)
    $failList += [PSCustomObject]@{ File=$File; Line=$LineNumber; Name=$Name; Reason=$Reason }
}

function Write-Warn { param($File, $LineNumber, $Name, $Reason)
    $warnList += [PSCustomObject]@{ File=$File; Line=$LineNumber; Name=$Name; Reason=$Reason }
}

function Get-ControlNameFromAboveLine { param([string[]]$Lines,[int]$ControlLineIndex)
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

# Regexes
$rxSet           = [regex]'(?i)\bSet\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,'
$rxClearCollect  = [regex]'(?i)\bClearCollect\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,'
$rxCollect       = [regex]'(?i)\bCollect\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,'
$rxUpdateContext = [regex]'(?i)\bUpdateContext\s*\(\s*\{([^}]*)\}'

# --- Resolve files ---
$fileList = New-Object System.Collections.Generic.List[string]
if ($Paths -and $Paths.Count -gt 0) {
    foreach ($p in $Paths) { if (Test-Path $p) { $fileList.Add((Resolve-Path $p).Path) } }
} elseif (-not [string]::IsNullOrWhiteSpace($Root)) {
    if (-not (Test-Path $Root)) { throw "Root not found: $Root" }
    Get-ChildItem -Path $Root -Directory | ForEach-Object {
        $src = Join-Path $_.FullName "Src"
        if (Test-Path $src) { 
            Get-ChildItem -Path $src -Recurse -File -Include *.yml,*.yaml | ForEach-Object { $fileList.Add($_.FullName) }
        }
    }
} else { throw "Provide either -Paths or -Root" }

if ($fileList.Count -eq 0) { Write-Host "No YAML files found."; exit 0 }

# --- Scan files ---
foreach ($file in $fileList) {
    $lines = Get-Content -LiteralPath $file
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]; $lineNo = $i + 1

        # Control checks
        if ($line -match '^\s*Control:\s*([A-Za-z0-9_\/]+)\@') {
            $controlType = $Matches[1]
            $controlKey = $controlType.ToLower().Replace("classic/","")
            $controlName = Get-ControlNameFromAboveLine -Lines $lines -ControlLineIndex $i
            if (-not $controlName) { Write-Fail -File $file -LineNumber $lineNo -Name "<unknown>" -Reason "Cannot find control name above Control: $controlType"; continue }
            $expectedPrefix = if ($prefixByName.ContainsKey($controlKey)) { $prefixByName[$controlKey] } else { $null }
            if (-not $expectedPrefix) { Write-Warn -File $file -LineNumber $lineNo -Name $controlName -Reason "No prefix mapping for Control: $controlType" }

            $reasons = @()
            if ($expectedPrefix -and -not $controlName.ToLower().StartsWith($expectedPrefix.ToLower())) { $reasons += "PREFIX expected '$expectedPrefix' for Control '$controlType'" }
            if ($checkNumericSuffix -and ($controlName -match '_\d+$')) { $reasons += "SUFFIX ends with _nn" }
            if ($reasons.Count -gt 0) { Write-Fail -File $file -LineNumber $lineNo -Name $controlName -Reason ($reasons -join "; ") }
        }

        # Variable / Collection / Context checks
        foreach ($m in $rxSet.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($varPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "VAR PREFIX expected '$varPrefix' (Set())" } }
        foreach ($m in $rxClearCollect.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "COL PREFIX expected '$colPrefix' (ClearCollect())" } }
        foreach ($m in $rxCollect.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "COL PREFIX expected '$colPrefix' (Collect())" } }
        foreach ($m in $rxUpdateContext.Matches($line)) {
            $inner=$m.Groups[1].Value
            [regex]::Matches($inner,'([A-Za-z_][A-Za-z0-9_]*)\s*:') | ForEach-Object { $key=$_.Groups[1].Value; if (-not $key.ToLower().StartsWith($locPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $key -Reason "LOC PREFIX expected '$locPrefix' (UpdateContext())" } }
        }
    }
}

# --- Step summary: Table of file-level counts ---
$summaryFile = $env:GITHUB_STEP_SUMMARY
if (-not $summaryFile) { $summaryFile = "./canvas-lint-summary.md" }

# Calculate counts per file
$files = $failList + $warnList | Select-Object -ExpandProperty File -Unique
Add-Content $summaryFile "`n### :clipboard: Canvas App Lint Summary"
Add-Content $summaryFile "| File Name | Count of Errors | Count of Warnings |"
Add-Content $summaryFile "|-----------|----------------|-----------------|"
foreach ($f in $files) {
    $errorCount = ($failList | Where-Object { $_.File -eq $f }).Count
    $warnCount  = ($warnList | Where-Object { $_.File -eq $f }).Count
    Add-Content $summaryFile "| $f | $errorCount | $warnCount |"
}

# --- Optionally output each issue to console ---
$failList | ForEach-Object { Write-Host "[FAIL] $($_.File):$($_.Line) $($_.Name) - $($_.Reason)" -ForegroundColor Red }
$warnList | ForEach-Object { Write-Host "[WARN] $($_.File):$($_.Line) $($_.Name) - $($_.Reason)" -ForegroundColor Yellow }

# --- Artifact: full markdown tables ---
$artifactDir = "./common"
if (-not (Test-Path $artifactDir)) { New-Item -ItemType Directory -Path $artifactDir | Out-Null }
$artifactPath = Join-Path $artifactDir "canvas-lint-full.md"

# Write failures
@"
# Canvas App Lint Full Report

## Failures ($($failList.Count))
| File | Line | Name | Reason |
|------|------|------|--------|
"@ | Set-Content -Path $artifactPath -Encoding utf8
$failList | ForEach-Object { "| $($_.File) | $($_.Line) | $($_.Name) | $($_.Reason) |" | Add-Content -Path $artifactPath -Encoding utf8 }

# Write warnings
if ($warnList.Count -gt 0) {
    Add-Content -Path $artifactPath -Value "`n## Warnings ($($warnList.Count))"
    Add-Content -Path $artifactPath -Value "| File | Line | Name | Reason |"
    Add-Content -Path $artifactPath -Value "|------|------|------|--------|"
    $warnList | ForEach-Object { "| $($_.File) | $($_.Line) | $($_.Name) | $($_.Reason) |" | Add-Content -Path $artifactPath -Encoding utf8 }
}

Write-Host "Lint completed. Failures: $($failList.Count), Warnings: $($warnList.Count)"
Write-Host "Full artifact available at $artifactPath"

# Exit code
if ($failList.Count -gt 0) { exit 1 } else { exit 0 }
