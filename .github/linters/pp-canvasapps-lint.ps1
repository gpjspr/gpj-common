param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [string[]]$Paths,

    [string]$Root = ""
)

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Prefix lookup
$prefixByName = @{ }
foreach ($c in $config.controls) { $prefixByName[$c.name.ToLower()] = $c.value }

$varPrefix = $config.variables.globalPrefix
$locPrefix = $config.variables.contextPrefix
$colPrefix = $config.variables.collectionPrefix
$checkNumericSuffix = [bool]$config.rules.disallowNumericSuffix

# Lists to capture all issues
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

# Resolve files
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
            if ([string]::IsNullOrWhiteSpace($controlName)) { Write-Fail -File $file -LineNumber $lineNo -Name "<unknown>" -Reason "Cannot find control name above Control: $controlType"; continue }
            $expectedPrefix = if ($prefixByName.ContainsKey($controlKey)) { $prefixByName[$controlKey] } else { $null }
            if (-not $expectedPrefix) { Write-Warn -File $file -LineNumber $lineNo -Name $controlName -Reason "No prefix mapping for Control: $controlType" }

            $reasons = @()
            if ($expectedPrefix -and -not $controlName.ToLower().StartsWith($expectedPrefix.ToLower())) { $reasons += "PREFIX expected '$expectedPrefix' for Control '$controlType'" }
            if ($checkNumericSuffix -and ($controlName -match '_\d+$')) { $reasons += "SUFFIX ends with _nn" }
            if ($reasons.Count -gt 0) { Write-Fail -File $file -LineNumber $lineNo -Name $controlName -Reason ($reasons -join "; ") }
        }

        # Variable/Collection/Context checks
        foreach ($m in $rxSet.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($varPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "VAR PREFIX expected '$varPrefix' (Set())" } }
        foreach ($m in $rxClearCollect.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "COL PREFIX expected '$colPrefix' (ClearCollect())" } }
        foreach ($m in $rxCollect.Matches($line)) { $name=$m.Groups[1].Value; if (-not $name.ToLower().StartsWith($colPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $name -Reason "COL PREFIX expected '$colPrefix' (Collect())" } }
        foreach ($m in $rxUpdateContext.Matches($line)) {
            $inner=$m.Groups[1].Value
            [regex]::Matches($inner,'([A-Za-z_][A-Za-z0-9_]*)\s*:') | ForEach-Object { $key=$_.Groups[1].Value; if (-not $key.ToLower().StartsWith($locPrefix.ToLower())) { Write-Fail -File $file -LineNumber $lineNo -Name $key -Reason "LOC PREFIX expected '$locPrefix' (UpdateContext())" } }
        }
    }
}

# --- GitHub UI annotations (top 50) ---
$failList | Select-Object -First 50 | ForEach-Object { $f = $_; Write-Host "::error file=$($f.File),line=$($f.Line)::[FAIL] $($f.Name) - $($f.Reason)" }
$warnList | Select-Object -First 50 | ForEach-Object { $w = $_; Write-Host "::warning file=$($w.File),line=$($w.Line)::[WARN] $($w.Name) - $($w.Reason)" }

# --- Step summary ---
$summaryFile = $env:GITHUB_STEP_SUMMARY
if (-not [string]::IsNullOrEmpty($summaryFile)) {
    if ($failList.Count -gt 0) {
        Add-Content $summaryFile "`n### :x: Failures ($($failList.Count))"
        Add-Content $summaryFile "| File | Line | Name | Reason |"
        Add-Content $summaryFile "|------|------|------|--------|"
        $failList | ForEach-Object { Add-Content $summaryFile "| $($_.File) | $($_.Line) | $($_.Name) | $($_.Reason) |" }
    }
    if ($warnList.Count -gt 0) {
        Add-Content $summaryFile "`n### :warning: Warnings ($($warnList.Count))"
        Add-Content $summaryFile "| File | Line | Name | Reason |"
        Add-Content $summaryFile "|------|------|------|--------|"
        $warnList | ForEach-Object { Add-Content $summaryFile "| $($_.File) | $($_.Line) | $($_.Name) | $($_.Reason) |" }
    }

    # Write full artifact file for download
    $artifactPath = "./common/canvas-lint-full.md"
    Copy-Item -Path $summaryFile -Destination $artifactPath -Force
}
Write-Host "Lint completed. Failures: $($failList.Count), Warnings: $($warnList.Count)"

# Exit with code 1 if any failures
if ($failList.Count -gt 0) { exit 1 } else { exit 0 }
