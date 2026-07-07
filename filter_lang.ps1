param(
    [switch]$f,
    [switch]$d,
    [switch]$h,
    [string]$i = ".",
    [string]$o = "non_english_files.txt",
    [string]$l = "non_english_files.txt",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($h) {
    Write-Host @"
Usage: $($MyInvocation.MyCommand.Name) -f | -d | -h

  -f               Find non-English files
     -i <dir>        Directory to scan (default: .)
     -o <file>       Output file path (default: non_english_files.txt)

  -d               Delete non-English files listed in output file
     -l <file>       List file from -f run (default: non_english_files.txt)
     -i <dir>        Directory containing the files (default: .)
     -DryRun         Show what would be deleted without deleting

  -h               Show this help
"@
    exit 0
}

if ($f -and $d) {
    Write-Error "Cannot use -f and -d together"
    exit 1
}
if (-not ($f -or $d)) {
    Write-Error "Must specify -f or -d (use -h for help)"
    exit 1
}

# -------------------------------------------------------
# MODE: find
# -------------------------------------------------------
if ($f) {
    $engRegions = 'USA|Europe|Australia|UK|Canada'

    function Has-English {
        param([string]$FileName)

        $groups = [regex]::Matches($FileName, '\([^)]+\)')
        $foundTags = $false

        foreach ($g in $groups) {
            $foundTags = $true
            if ($g.Value -cmatch '\bEn\b') { return $true }
            if ($g.Value -cmatch "\b($engRegions)\b") { return $true }
        }

        if (-not $foundTags) { return $true }
        return $false
    }

    $count = 0
    $total = 0
    $results = @()

    Get-ChildItem -Path $i -File | ForEach-Object {
        $total++
        if (-not (Has-English $_.Name)) {
            $results += $_.Name
            $count++
        }
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($o, $results, $utf8)
    Write-Host "Non-English: $count  /  Total: $total  ->  $o"

# -------------------------------------------------------
# MODE: delete
# -------------------------------------------------------
} elseif ($d) {
    if (-not (Test-Path $l -PathType Leaf)) {
        Write-Error "List file '$l' not found"
        exit 1
    }

    $count = 0
    Get-Content $l | ForEach-Object {
        $fname = $_.Trim()
        if (-not $fname) { return }
        $target = Join-Path $i $fname
        if (Test-Path $target -PathType Leaf) {
            if ($DryRun) {
                Write-Host "  [dry] rm -f $target"
            } else {
                Remove-Item -Force $target
                Write-Host "  rm -f $target"
            }
            $count++
        } else {
            Write-Host "  [missing] $target"
        }
    }

    Write-Host ""
    Write-Host "Removed: $count"
}
