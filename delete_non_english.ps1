param(
    [string]$ListFile = "non_english_files.txt",
    [string]$Dir = ".",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ListFile -PathType Leaf)) {
    Write-Error "List file '$ListFile' not found"
    exit 1
}

$count = 0
Get-Content $ListFile | ForEach-Object {
    $fname = $_.Trim()
    if (-not $fname) { return }
    $target = Join-Path $Dir $fname
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
