param(
    [string]$Dir = ".",
    [string]$OutFile = "non_english_files.txt"
)

$ErrorActionPreference = "Stop"

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

Get-ChildItem -Path $Dir -File | ForEach-Object {
    $total++
    if (-not (Has-English $_.Name)) {
        $results += $_.Name
        $count++
    }
}

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($OutFile, $results, $utf8)
Write-Host "Non-English: $count  /  Total: $total  ->  $OutFile"
