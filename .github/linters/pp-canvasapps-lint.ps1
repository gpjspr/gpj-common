# Initialize lists
$failList = @()
$warnList = @()

function Write-Fail {
    param($File, $LineNumber, $Name, $Reason)
    $failList += [PSCustomObject]@{
        File = $File
        Line = $LineNumber
        Name = $Name
        Reason = $Reason
    }
    Write-Host "::error file=$File,line=$LineNumber::[FAIL] $Name - $Reason"
}

function Write-Warn {
    param($File, $LineNumber, $Name, $Reason)
    $warnList += [PSCustomObject]@{
        File = $File
        Line = $LineNumber
        Name = $Name
        Reason = $Reason
    }
    Write-Host "::warning file=$File,line=$LineNumber::[WARN] $Name - $Reason"
}

# ... run your lint logic as before ...

# After scanning all files, output tables to step summary
$summaryFile = $env:GITHUB_STEP_SUMMARY

if ($failList.Count -gt 0) {
    Add-Content $summaryFile "`n### :x: Failures"
    Add-Content $summaryFile "| File | Line | Name | Reason |"
    Add-Content $summaryFile "|------|------|------|--------|"
    foreach ($f in $failList) {
        Add-Content $summaryFile "| $($f.File) | $($f.Line) | $($f.Name) | $($f.Reason) |"
    }
}

if ($warnList.Count -gt 0) {
    Add-Content $summaryFile "`n### :warning: Warnings"
    Add-Content $summaryFile "| File | Line | Name | Reason |"
    Add-Content $summaryFile "|------|------|------|--------|"
    foreach ($w in $warnList) {
        Add-Content $summaryFile "| $($w.File) | $($w.Line) | $($w.Name) | $($w.Reason) |"
    }
}

# Exit 1 only if there are failures
exit ([int]($failList.Count -gt 0))
