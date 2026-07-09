param(
    [switch]$f,
    [switch]$d,
    [switch]$v,
    [switch]$n,
    [switch]$s,
    [switch][Alias("1")]$one,
    [switch]$m,
    [switch]$c,
    [switch]$x,
    [switch]$z,
    [switch]$h,
    [string]$i = ".",
    [string]$o = "non_english_files.txt",
    [string]$l = "non_english_files.txt",
    [switch]$DryRun,
    [switch]$Verbose,
    [int]$j = 1,
    [string]$With = "",
    [switch]$Dat,
    [switch]$Tsv,
    [switch]$Keep
)

$ErrorActionPreference = "Stop"

if ($h) {
    Write-Host @"
archive_man.ps1 v2.0.0 — archive/ROM management tool

Usage: $($MyInvocation.MyCommand.Name) MODE [options]

MODES:
  -f         Find non-English files
  -d         Delete non-English files from list
  -v         Verify archive integrity (zip/7z/rar)
  -n         Normalize filenames (comma spacing, whitespace)
  -s         Sort files into A-Z/# subdirectories
  -1         1G1R: keep best version per game, flag duplicates
  -m         Merge/compare two directories
  -c         Generate SHA1 checksums
  -x         Build file index catalog (JSON)
  -z         Recompress archives (zip -> 7z)
  -h         Show this help

COMMON OPTIONS:
  -i <dir>     Target directory (default: .)
  -DryRun      Preview changes without executing
  -j <N>       Parallel jobs for -v, -c, -z (default: 1)

MODE-SPECIFIC:
  -f:  -o <file>    Output file (default: non_english_files.txt)
  -d:  -l <file>    Input list file (default: non_english_files.txt)
  -m:  -With <dir>  Second directory to compare against
  -v:  -Verbose     Show every archive, not just failures
  -c:  -Dat         Output No-Intro DAT XML format instead of plain SHA1
  -x:  -Tsv         Output TSV instead of JSON
  -z:  -Keep        Keep original after recompressing
"@
    exit 0
}

$modes = @($f, $d, $v, $n, $s, $one, $m, $c, $x, $z) | Where-Object { $_ }
if ($modes.Count -gt 1) {
    Write-Error "Cannot use multiple mode flags together"
    exit 1
}
if ($modes.Count -eq 0) {
    Write-Error "Must specify a mode (-f -d -v -n -s -1 -m -c -x -z). Use -h for help."
    exit 1
}
if ($j -lt 1) { $j = 1 }

# ---------- utility functions ----------
$engRegions = 'USA|Europe|Australia|UK|Canada'

function Get-GameName {
    param([string]$FileName)
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $idx = $base.IndexOf('(')
    if ($idx -gt 0) { return $base.Substring(0, $idx).TrimEnd() }
    return $base.TrimEnd()
}

function Get-RegionScore {
    param([string]$Region)
    switch ($Region.ToLower()) {
        'usa'         { 100 }
        'europe'      { 85 }
        'australia'   { 80 }
        'uk'          { 78 }
        'canada'      { 78 }
        'world'       { 60 }
        'japan'       { 50 }
        default       { 25 }
    }
}

function Get-VersionScore {
    param([string]$Ver)
    if ($Ver -match '^(\d{4})-(\d{2})-(\d{2})$') {
        return [int]("$($Matches[1])$($Matches[2])$($Matches[3])") + 100000
    }
    if ($Ver -match '^v?(\d+)\.(\d+(?:\.\d+)*)$') {
        $major = [int]$Matches[1]
        $rest = $Matches[2] -replace '\.', ''
        $minor = if ($rest) { [int]$rest } else { 0 }
        return ($major * 10000) + $minor
    }
    return 0
}

# ============================================================
# MODE: find
# ============================================================
if ($f) {
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

    $count = 0; $total = 0; $results = @()
    Get-ChildItem -Path $i -File | ForEach-Object {
        $total++
        if (-not (Has-English $_.Name)) {
            $results += $_.Name
            $count++
        }
    }

    [System.IO.File]::WriteAllLines($o, $results, [Text.Encoding]::UTF8)
    Write-Host "Non-English: $count  /  Total: $total  ->  $o"

# ============================================================
# MODE: delete
# ============================================================
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

# ============================================================
# MODE: verify
# ============================================================
} elseif ($v) {
    function Test-Archive {
        param([string]$FilePath)
        $name = [IO.Path]::GetFileName($FilePath)
        $ext = [IO.Path]::GetExtension($FilePath).ToLower()
        try {
            switch ($ext) {
                '.zip' {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                    $z = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
                    $z.Dispose()
                    return "OK:$name"
                }
                '.7z' {
                    & 7z t $FilePath *>$null
                    if ($LASTEXITCODE -eq 0) { return "OK:$name" }
                    return "BAD:$name"
                }
                '.rar' {
                    & unrar t $FilePath *>$null
                    if ($LASTEXITCODE -eq 0) { return "OK:$name" }
                    return "BAD:$name"
                }
                default { return "SKIP:$name" }
            }
        } catch {
            return "BAD:$name"
        }
    }

    $ok = 0; $bad = 0; $skip = 0

    if ($j -gt 1) {
        $files = Get-ChildItem -Path $i -File
        $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $j)
        $runspacePool.Open()
        $jobs = @()

        foreach ($file in $files) {
            $ps = [PowerShell]::Create().AddScript({
                param($f)
                function Test-Archive {
                    param([string]$FilePath)
                    $name = [IO.Path]::GetFileName($FilePath)
                    $ext = [IO.Path]::GetExtension($FilePath).ToLower()
                    try {
                        switch ($ext) {
                            '.zip' {
                                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                                $z = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
                                $z.Dispose()
                                return "OK:$name"
                            }
                            '.7z' {
                                & 7z t $FilePath *>$null
                                if ($LASTEXITCODE -eq 0) { return "OK:$name" }
                                return "BAD:$name"
                            }
                            '.rar' {
                                & unrar t $FilePath *>$null
                                if ($LASTEXITCODE -eq 0) { return "OK:$name" }
                                return "BAD:$name"
                            }
                            default { return "SKIP:$name" }
                        }
                    } catch { return "BAD:$name" }
                }
                Test-Archive $f
            })
            $ps.RunspacePool = $runspacePool
            $jobs += [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }

        foreach ($job in $jobs) {
            $result = $job.PS.EndInvoke($job.Handle)
            $job.PS.Dispose()
            $status, $fname = $result -split ':', 2
            switch ($status) {
                'OK'   { $ok++; if ($Verbose) { Write-Host "  [OK]   $fname" } }
                'BAD'  { $bad++; Write-Host "  [BAD]  $fname" }
                'SKIP' { $skip++; if ($Verbose) { Write-Host "  [SKIP] $fname" } }
            }
        }
        $runspacePool.Dispose()
    } else {
        Get-ChildItem -Path $i -File | ForEach-Object {
            $result = Test-Archive $_.FullName
            $status, $fname = $result -split ':', 2
            switch ($status) {
                'OK'   { $ok++; if ($Verbose) { Write-Host "  [OK]   $fname" } }
                'BAD'  { $bad++; Write-Host "  [BAD]  $fname" }
                'SKIP' { $skip++; if ($Verbose) { Write-Host "  [SKIP] $fname" } }
            }
        }
    }
    Write-Host ""
    Write-Host "OK: $ok  BAD: $bad  Skipped: $skip"

# ============================================================
# MODE: normalize
# ============================================================
} elseif ($n) {
    function Normalize-Name {
        param([string]$FileName)
        $new = $FileName
        $groups = [regex]::Matches($FileName, '\([^)]+\)')
        foreach ($g in $groups) {
            $fixed = $g.Value -replace ',\s*(\w)', ', $1'
            $fixed = $fixed -replace '\s{2,}', ' '
            $new = $new.Replace($g.Value, $fixed)
        }
        $new = $new -replace '\s{2,}', ' '
        $new = $new.Trim()
        return $new
    }

    $count = 0; $total = 0
    Get-ChildItem -Path $i -File | ForEach-Object {
        $total++
        $newname = Normalize-Name $_.Name
        if ($_.Name -ne $newname) {
            $target = Join-Path $i $newname
            if (Test-Path $target) {
                Write-Host "  [conflict] $($_.Name) -> $newname (target exists)"
                return
            }
            if ($DryRun) {
                Write-Host "  [dry] mv $($_.Name) -> $newname"
            } else {
                Rename-Item -Path $_.FullName -NewName $newname
                Write-Host "  mv $($_.Name) -> $newname"
            }
            $count++
        }
    }
    Write-Host ""
    Write-Host "Renamed: $count  /  Total: $total"

# ============================================================
# MODE: sort
# ============================================================
} elseif ($s) {
    $count = 0; $total = 0
    Get-ChildItem -Path $i -File | ForEach-Object {
        $total++
        $first = $_.Name[0].ToString().ToUpper()
        if ($first -cmatch '[A-Z]') { $subdir = $first } else { $subdir = "#" }

        if ((Get-Item $_.FullName).DirectoryName -ne (Resolve-Path $i).Path) {
            if ($Verbose) { Write-Host "  [skip] $($_.Name) (already nested)" }
            return
        }

        if ($DryRun) {
            Write-Host "  [dry] mv $($_.Name) -> $subdir/$($_.Name)"
        } else {
            $targetDir = Join-Path $i $subdir
            New-Item -ItemType Directory -Force -Path $targetDir *>$null
            Move-Item -Path $_.FullName -Destination $targetDir
            Write-Host "  mv $($_.Name) -> $subdir/$($_.Name)"
        }
        $count++
    }
    Write-Host ""
    Write-Host "Sorted: $count  /  Total: $total"

# ============================================================
# MODE: 1G1R
# ============================================================
} elseif ($one) {
    $groups = @{}; $scores = @{}; $order = @()

    Get-ChildItem -Path $i -File | ForEach-Object {
        $fname = $_.Name
        $game = Get-GameName $fname
        if (-not $groups.ContainsKey($game)) {
            $groups[$game] = @()
            $order += $game
        }
        $groups[$game] += $fname

        $parens = [regex]::Matches($fname, '\([^)]+\)')
        $region = ""; $version = ""; $isDemo = 0; $isAlt = 0; $isRerelease = 0; $yearTag = ""

        foreach ($p in $parens) {
            $inner = $p.Value.Substring(1, $p.Value.Length - 2)
            $lower = $inner.ToLower()
            $regionPattern = '^(usa|europe|australia|uk|canada|japan|china|taiwan|thailand|spain|korea|world|brazil|italy|france|germany|netherlands|sweden|norway|denmark|finland|russia)$'
            if ($lower -match $regionPattern -and -not $region) {
                $region = $inner
            } elseif ($lower -match '^(demo|sample|trial|beta|proto)$') {
                $isDemo = 1
            } elseif ($lower -eq 'alt' -or $lower -match '^alt \d+$') {
                $isAlt = 1
            } elseif ($lower -eq 'rerelease') {
                $isRerelease = 1
            } elseif ($lower -match '^\d{4}-\d{2}-\d{2}$') {
                $yearTag = $inner
            } elseif ($lower -match '^v?\d+(\.\d+)+$') {
                $version = $inner
            }
        }

        $score = Get-RegionScore $region
        if ($isRerelease) { $score += 15 }
        if ($isDemo)      { $score -= 50 }
        if ($isAlt)       { $score -= 10 }
        if ($yearTag)     { $score += (Get-VersionScore $yearTag) }
        if ($version)     { $score += (Get-VersionScore $version) }
        $scores[$fname] = $score
    }

    $kept = 0; $removed = 0
    foreach ($game in $order) {
        $candidates = $groups[$game]
        if ($candidates.Count -le 1) {
            if ($Verbose) { Write-Host "  [only] $($candidates[0])" }
            $kept++
            continue
        }

        $best = ""; $bestScore = -999999
        foreach ($c in $candidates) {
            $sc = $scores[$c]
            if ($sc -gt $bestScore) {
                $bestScore = $sc
                $best = $c
            }
        }

        Write-Host "  [game] $game"
        foreach ($c in $candidates) {
            if ($c -eq $best) {
                Write-Host "    KEEP  $c"
                $kept++
            } else {
                Write-Host "    DROP  $c"
                if (-not $DryRun) {
                    $target = Join-Path $i $c
                    if (Test-Path $target) { Remove-Item -Force $target }
                }
                $removed++
            }
        }
    }

    if ($DryRun) { Write-Host ""; Write-Host "[dry-run] would remove $removed, keep $kept" }
    Write-Host ""
    Write-Host "Kept: $kept  Dropped: $removed"

# ============================================================
# MODE: merge
# ============================================================
} elseif ($m) {
    if (-not $With) { Write-Error "--With <dir> required for merge mode"; exit 1 }
    if (-not (Test-Path $With -PathType Container)) { Write-Error "--With '$With' not found"; exit 1 }
    Write-Host "Merging: $i  <->  $With"
    Write-Host ""

    $d1 = @{}; $d2 = @{}
    Get-ChildItem -Path $i -File | ForEach-Object { $d1[$_.Name] = $true }
    Get-ChildItem -Path $With -File | ForEach-Object { $d2[$_.Name] = $true }

    $only1 = 0; $only2 = 0; $both = 0
    foreach ($f in $d1.Keys) {
        if ($d2.ContainsKey($f)) {
            $both++
        } else {
            Write-Host "  < $f  (only in $i)"
            $only1++
        }
    }
    foreach ($f in $d2.Keys) {
        if (-not $d1.ContainsKey($f)) {
            Write-Host "  > $f  (only in $With)"
            $only2++
        }
    }
    Write-Host ""
    Write-Host "Only in $i   : $only1"
    Write-Host "Only in $With: $only2"
    Write-Host "In both      : $both"

# ============================================================
# MODE: checksum
# ============================================================
} elseif ($c) {
    if ($Dat) {
        Write-Host '<?xml version="1.0"?>'
        Write-Host '<datafile>'
    }

    if ($j -gt 1) {
        $files = Get-ChildItem -Path $i -File
        $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $j)
        $runspacePool.Open()
        $jobs = @()

        foreach ($file in $files) {
            $ps = [PowerShell]::Create().AddScript({
                param($p, $dat)
                $hash = (Get-FileHash -Path $p -Algorithm SHA1).Hash
                $name = [IO.Path]::GetFileName($p)
                $size = (Get-Item $p).Length
                if ($dat) {
                    "    <game name=`"$name`">`n      <rom name=`"$name`" size=`"$size`" sha1=`"$hash`"/>`n    </game>"
                } else {
                    "$hash  $name"
                }
            })
            $ps.AddArgument($file.FullName) | Out-Null
            $ps.AddArgument($Dat.IsPresent) | Out-Null
            $ps.RunspacePool = $runspacePool
            $jobs += [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }

        foreach ($job in $jobs) {
            $result = $job.PS.EndInvoke($job.Handle)
            $job.PS.Dispose()
            Write-Host $result
        }
        $runspacePool.Dispose()
    } else {
        Get-ChildItem -Path $i -File | ForEach-Object {
            $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA1).Hash
            $size = $_.Length
            if ($Dat) {
                Write-Host "    <game name=`"$($_.Name)`">"
                Write-Host "      <rom name=`"$($_.Name)`" size=`"$size`" sha1=`"$hash`"/>"
                Write-Host "    </game>"
            } else {
                Write-Host "$hash  $($_.Name)"
            }
        }
    }

    if ($Dat) { Write-Host '</datafile>' }

# ============================================================
# MODE: index
# ============================================================
} elseif ($x) {
    function Parse-Meta {
        param([string]$FileName, [string]$FullPath)
        $game = Get-GameName $FileName
        $ext = [IO.Path]::GetExtension($FileName)
        $region = ""; $version = ""; $year = ""; $disc = $null
        $demo = $false; $alt = $false; $rerelease = $false
        $lang = ""; $size = (Get-Item $FullPath -ErrorAction SilentlyContinue).Length

        $parens = [regex]::Matches($FileName, '\([^)]+\)')
        foreach ($p in $parens) {
            $inner = $p.Value.Substring(1, $p.Value.Length - 2)
            $lower = $inner.ToLower()
            $regionPattern = '^(usa|europe|australia|uk|canada|japan|china|taiwan|thailand|spain|korea|world|brazil|italy|france|germany|netherlands|sweden|norway|denmark|finland|russia)$'
            if ($lower -match $regionPattern -and -not $region) {
                $region = $inner
            } elseif ($lower -match '^en(,.*)?$' -or $lower -match '^.*,en$' -or $lower -eq 'en') {
                $lang = $inner
            } elseif ($lower -match '^(demo|sample|trial|beta|proto)$') {
                $demo = $true
            } elseif ($lower -eq 'alt' -or $lower -match '^alt \d+$') {
                $alt = $true
            } elseif ($lower -eq 'rerelease') {
                $rerelease = $true
            } elseif ($lower -match '^disc? \d+$') {
                $disc = ($lower -split ' ')[-1]
            } elseif ($lower -match '^\d{4}-\d{2}-\d{2}$') {
                $year = $inner
            } elseif ($lower -match '^v?\d+(\.\d+)+$') {
                $version = $inner
            } elseif (-not $lang -and $lower -match '^([a-z]{2},? ?)+$') {
                $lang = $inner
            }
        }

        if ($Tsv) {
            return "$game`t$region`t$($lang -replace ',', ' ')`t$version`t$year`t$disc`t$demo`t$alt`t$rerelease`t$($ext -replace '^\.', '')`t$size"
        } else {
            $obj = [PSCustomObject]@{
                name       = $game
                region     = if ($region) { $region } else { $null }
                languages  = if ($lang) { $lang } else { "" }
                version    = if ($version) { $version } else { $null }
                year       = if ($year) { $year } else { $null }
                disc       = if ($disc) { [int]$disc } else { $null }
                demo       = $demo
                alt        = $alt
                rerelease  = $rerelease
                ext        = $ext -replace '^\.', ''
                size       = $size
            }
            return $obj
        }
    }

    if ($Tsv) {
        Write-Host "game`tregion`tlanguages`tversion`tyear`tdisc`tdemo`talt`trerelease`text`tsize"
    } else {
        Write-Host "["
    }

    $items = @()
    Get-ChildItem -Path $i -File | ForEach-Object {
        $result = Parse-Meta $_.Name $_.FullName
        if ($Tsv) {
            Write-Host $result
        } else {
            $items += $result
        }
    }

    if (-not $Tsv) {
        $json = ($items | ConvertTo-Json -Depth 3)
        Write-Host ($json -replace '^\[', '' -replace '\]$', '')
        Write-Host "]"
    }

# ============================================================
# MODE: recompress
# ============================================================
} elseif ($z) {
    if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
        Write-Error "7z not found — required for recompress mode"
        exit 1
    }

    $ok = 0; $fail = 0

    Get-ChildItem -Path $i -File -Filter "*.zip" | ForEach-Object {
        $file = $_
        $fname = $file.Name
        $outname = $fname -replace '\.zip$', '.7z'
        $target = Join-Path $i $outname

        if (Test-Path $target) {
            Write-Host "  [skip] $fname (target $outname exists)"
            return
        }

        if ($DryRun) {
            Write-Host "  [dry] 7z  $fname -> $outname"
            return
        }

        $workdir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        try {
            New-Item -ItemType Directory -Path $workdir -Force *>$null

            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($file.FullName, $workdir)
            } catch {
                Write-Host "  [FAIL] $fname (extraction failed)"
                $fail++
                return
            }

            $tmpOut = Join-Path $workdir "tmp.7z"
            & 7z a -mx=9 -ms=on -mmt=on $tmpOut "$workdir\*" *>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpOut)) {
                Move-Item $tmpOut $target -Force
                $origSize = $file.Length
                $newSize = (Get-Item $target).Length
                $pct = [math]::Round(100 - ($newSize * 100.0 / $origSize))
                Write-Host "  [OK] $fname -> $outname  (${pct}% smaller)"

                if (-not $Keep) {
                    Remove-Item -Force $file.FullName -ErrorAction SilentlyContinue
                }
                $ok++
            } else {
                Write-Host "  [FAIL] $fname (7z compression failed)"
                Remove-Item $target -Force -ErrorAction SilentlyContinue
                $fail++
            }
        } finally {
            Remove-Item -Recurse -Force $workdir -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "Recompressed: $ok  Failed: $fail"
}
