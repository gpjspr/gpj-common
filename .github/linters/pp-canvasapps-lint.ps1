<#
Check-CanvasYaml.ps1

Usage:
  ./Check-CanvasYaml.ps1 -ConfigPath ".config/canvas-naming-rules.json" -Root "appsource"
  ./Check-CanvasYaml.ps1 -ConfigPath ".config/canvas-naming-rules.json" -Paths @("appsource/App1/src/Screens.yaml")
#>

param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [string[]]$Paths,

    [string]$Root = ""
)

# --- Load config ---
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Prefix lookup
$prefixByName = @{ }
foreach ($c in $config.controls) { $prefixByName[$c.name.ToLower()] = $c.value }

$varPrefix = $config.variables.globalPrefix
$locPrefix = $config.variables.contextPrefix
$colPrefix = $config.variables.collectionPrefix
$checkNumericSuffix = [bool]$config.rules.disallowNumericSuffix

# --- Lists for errors/warnings ---
$failList = @()
$warnList = @()

function Write-Fail {
    param($File, $LineNumber, $Name, $Reason)
    $failList += [PSCustomObject]@{ File=$File; Line=$LineNumber; Name=$Name; Reason=$Reason }
    if ($failList.Count -le 50) {
        Write-Host "::error file=$File,line=$LineNumber::[FAIL] $Name - $Reason"
    }
}

function Write-Warn {
    param($File, $LineNumber, $Name, $Reason)
    $warnList += [PSCustomObject]@{ File=$File; Line=$LineNumber; Name=$Name; Reason=$Reason }
    if ($warnList.Count -le 50) {
        Write-Host "::warning file=$File,line=$LineNumber::[WARN] $Name - $Reason"
    }
}

# --- Helper: get control name ---
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

# --- Regexes for variable/collection/context ---
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

# --- Scan all files ---
foreach ($file in $fileList) {
    $lines = Get-Content -LiteralPath $file
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]; $lineNo = $i + 1

        # Control checks
        if ($line -match '^\s*Control:\s*([A-Za-z0-9_\/]+)\@') {
            $controlType = $Matches[1]
            $controlKey = $controlType.ToLower().Replace("classic/","")
            $controlName = Get-ControlNameFromAboveLine -Lines $lines -ControlLineIndex $i
            if ([string]::IsNullOrWhiteSpace($controlName)) {
                Write-Fail -File $file -LineNumber $lineNo -Name "<unknown>" -Reason "Cannot find control name above Control: $controlType"
                continue
            }
            $expectedPrefix = if ($prefixByName.ContainsKey($controlKey)) { $prefixByName[$controlKey] } else { $null }
            if (-not $expectedPrefix) { Write-Warn -File $file -LineNumber $lineNo -Name $controlName -Reason "No prefix mapping for Control: $controlType" }

            $reasons = @()
            if ($expectedPrefix -and -not $controlName.ToLower().StartsWith($expectedPrefix.ToLower())) { $reasons += "PREFIX expected '$expectedPrefix' for Control '$controlType'" }
            if ($checkNumericSuffix -and ($controlName -match '_\d+$')) { $reasons += "SUFFIX ends with _nn" }
            if ($reasons.Count -gt 0) { Write-Fail -File $file -LineNumber $lineNo -Name $controlName -Reason ($reasons -join "; ") }
        }

        # Variable / collection / context checks
        foreach ($m in $rxSet.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($varPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "VAR PREFIX expected '$varPrefix' (Set())" } }
        foreach ($m in $rxClearCollect.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "COL PREFIX expected '$colPrefix' (ClearCollect())" } }
        foreach ($m in $rxCollect.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "COL PREFIX expected '$colPrefix' (Collect())" } }
        foreach ($m in $rxUpdateContext.Matches($line)) {
            $inner=$m.Groups[1].Value
            [regex]::Matches($inner,'([A-Za-z_][A-Za-z0-9_]*)\s*:') | ForEach-Object {
                $key=$_.Groups[1].Value
                if (-not $key.ToLower().StartsWith($locPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $key -Reason "LOC PREFIX expected '$locPrefix' (UpdateContext())" }
            }
        }
    }
}

# --- Artifact file ---
$artifactFile = "./common/canvas-lint-full.md"
"# Canvas App Lint Full Report" | Out-File -FilePath $artifactFile -Encoding UTF8

# Write failures
if ($failList.Count -gt 0) {
    Add-Content $artifactFile "`n### :x: Failures ($($failList.Count))"
    Add-Content $artifactFile "| File | Line | Name | Reason |"
    Add-Content $artifactFile "|------|------|------|--------|"
    foreach ($f in $failList) {
        Add-Content $artifactFile "| $($f.File) | $($f.Line) | $($f.Name) | $($f.Reason) |"
    }
}

# Write warnings
if ($warnList.Count -gt 0) {
    Add-Content $artifactFile "`n### :warning: Warnings ($($warnList.Count))"
    Add-Content $artifactFile "| File | Line | Name | Reason |"
    Add-Content $artifactFile "|------|------|------|--------|"
    foreach ($w in $warnList) {
        Add-Content $artifactFile "| $($w.File) | $($w.Line) | $($w.Name) | $($w.Reason) |"
    }
}

# --- Step summary ---
if ($env:GITHUB_STEP_SUMMARY) {
    # Full artifact
    Get-Content $artifactFile | Add-Content $env:GITHUB_STEP_SUMMARY

    # File-level summary
    $files = ($failList + $warnList | Select-Object -ExpandProperty File -Unique)
    Add-Content $env:GITHUB_STEP_SUMMARY "`n### :clipboard: File Summary"
    Add-Content $env:GITHUB_STEP_SUMMARY "| File Name | Count of Errors | Count of Warnings |"
    Add-Content $env:GITHUB_STEP_SUMMARY "|-----------|----------------|-----------------|"
    foreach ($f in $files) {
        $errors = ($failList | Where-Object { $_.File -eq $f }).Count
        $warns  = ($warnList | Where-Object { $_.File -eq $f }).Count
        Add-Content $env:GITHUB_STEP_SUMMARY "| $f | $errors | $warns |"
    }
}

Write-Host "Lint completed. Failures: $($failList.Count), Warnings: $($warnList.Count)"

# Exit code
if ($failList.Count -gt 0) { exit 1 } else { exit 0 }
