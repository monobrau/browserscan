<#
.SYNOPSIS
  Converts Chromium History and Firefox places.sqlite copies into CSV (offline / analyst machine).

.DESCRIPTION
  Walks a folder tree (or uses explicit database files) and writes:
    History_urls.csv, History_visits.csv next to each Chromium History file
    places_moz_places.csv, places_moz_historyvisits.csv next to each places.sqlite

  Requires sqlite3.exe: use -Sqlite3Path, PATH, or drop sqlite3.exe next to this script.
  Original databases are kept unless you pass -DeleteOriginalSqlite.

.PARAMETER InputPath
  Path to a folder (recursive scan) or to a single file named History or places.sqlite.

.PARAMETER Sqlite3Path
  Full path to sqlite3.exe when not beside this script and not on PATH.

.PARAMETER DeleteOriginalSqlite
  After successful export, remove History / places.sqlite and WAL/SHM sidecars from disk.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Export-BrowserHistoryToCsv.ps1 -InputPath 'D:\cases\host1\exported'

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Export-BrowserHistoryToCsv.ps1 -InputPath 'D:\History' -Sqlite3Path 'C:\Tools\sqlite3.exe'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$Sqlite3Path = '',
    [switch]$DeleteOriginalSqlite
)

$ErrorActionPreference = 'Continue'

function Test-FileExists([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [System.IO.File]::Exists($Path) } catch { return $false }
}

function Test-DirExists([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [System.IO.Directory]::Exists($Path) } catch { return $false }
}

function Resolve-Sqlite3ExeForExport {
    param([string]$Sqlite3Path)
    if (-not [string]::IsNullOrWhiteSpace($Sqlite3Path) -and (Test-FileExists $Sqlite3Path)) {
        return [System.IO.Path]::GetFullPath($Sqlite3Path)
    }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $bundled = Join-Path $PSScriptRoot 'sqlite3.exe'
        if (Test-FileExists $bundled) {
            return [System.IO.Path]::GetFullPath($bundled)
        }
    }
    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-FileExists $cmd.Source)) {
        return $cmd.Source
    }
    return $null
}

function Test-SqliteHasTable {
    param(
        [Parameter(Mandatory)][string]$Sqlite3Exe,
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Table
    )
    $sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$Table'"
    $rows = & $Sqlite3Exe -readonly $DbPath $sql 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    $last = ($rows | Select-Object -Last 1)
    try { return ([int][string]$last.Trim()) -gt 0 } catch { return $false }
}

function Invoke-SqliteQueryToCsvFile {
    param(
        [Parameter(Mandatory)][string]$Sqlite3Exe,
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$OutCsv
    )
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('sqlite3_stderr_{0}.txt' -f ([guid]::NewGuid().ToString('N')))
    try {
        if (Test-FileExists $OutCsv) {
            Remove-Item -LiteralPath $OutCsv -Force -ErrorAction Stop
        }
        $q = $Query.Trim().TrimEnd(';')

        & $Sqlite3Exe -readonly -bail -header -csv $DbPath $q 2>$stderrPath |
            Out-File -LiteralPath $OutCsv -Encoding utf8

        if ($LASTEXITCODE -ne 0) {
            $err = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
            throw "sqlite3 exit $LASTEXITCODE $err"
        }
        if (-not (Test-FileExists $OutCsv)) {
            throw 'sqlite3 produced no output file'
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Export-OneChromiumHistory {
    param(
        [Parameter(Mandatory)]$HistoryFileInfo,
        [Parameter(Mandatory)][string]$Sqlite3Exe,
        [switch]$DeleteOriginalSqlite
    )
    $dir = $HistoryFileInfo.DirectoryName
    $dbPath = $HistoryFileInfo.FullName
    $urlsOk = $false
    try {
        if (Test-SqliteHasTable -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Table 'urls') {
            $outUrls = Join-Path $dir 'History_urls.csv'
            Invoke-SqliteQueryToCsvFile -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Query 'SELECT * FROM urls' -OutCsv $outUrls
            Write-Host "CSV OK  History_urls -> $outUrls"
            $urlsOk = $true
        }
        if (Test-SqliteHasTable -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Table 'visits') {
            $outVisits = Join-Path $dir 'History_visits.csv'
            Invoke-SqliteQueryToCsvFile -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Query 'SELECT * FROM visits' -OutCsv $outVisits
            Write-Host "CSV OK  History_visits -> $outVisits"
        }
    }
    catch {
        Write-Warning "CSV FAIL Chromium History under $dir :: $($_.Exception.Message)"
        return
    }

    if ($urlsOk -and $DeleteOriginalSqlite) {
        foreach ($suffix in @('', '-wal', '-shm', '-journal')) {
            $p = "${dbPath}${suffix}"
            if (Test-FileExists $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Host "CSV: removed Chromium History DB files under $dir"
    }
}

function Export-OneFirefoxPlaces {
    param(
        [Parameter(Mandatory)]$PlacesFileInfo,
        [Parameter(Mandatory)][string]$Sqlite3Exe,
        [switch]$DeleteOriginalSqlite
    )
    $dir = $PlacesFileInfo.DirectoryName
    $dbPath = $PlacesFileInfo.FullName
    $placesOk = $false
    try {
        if (Test-SqliteHasTable -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Table 'moz_places') {
            $outPl = Join-Path $dir 'places_moz_places.csv'
            Invoke-SqliteQueryToCsvFile -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Query 'SELECT * FROM moz_places' -OutCsv $outPl
            Write-Host "CSV OK  places_moz_places -> $outPl"
            $placesOk = $true
        }
        if (Test-SqliteHasTable -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Table 'moz_historyvisits') {
            $outVis = Join-Path $dir 'places_moz_historyvisits.csv'
            Invoke-SqliteQueryToCsvFile -Sqlite3Exe $Sqlite3Exe -DbPath $dbPath -Query 'SELECT * FROM moz_historyvisits' -OutCsv $outVis
            Write-Host "CSV OK  places_moz_historyvisits -> $outVis"
        }
    }
    catch {
        Write-Warning "CSV FAIL Firefox places.sqlite under $dir :: $($_.Exception.Message)"
        return
    }

    if ($placesOk -and $DeleteOriginalSqlite) {
        foreach ($name in @('places.sqlite', 'places.sqlite-wal', 'places.sqlite-shm')) {
            $p = Join-Path $dir $name
            if (Test-FileExists $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Host "CSV: removed Firefox places.sqlite DB files under $dir"
    }
}

# --- main ---
if (-not (Test-Path -LiteralPath $InputPath)) {
    Write-Error "InputPath not found: $InputPath"
    exit 1
}

$sqliteExe = Resolve-Sqlite3ExeForExport -Sqlite3Path $Sqlite3Path
if (-not $sqliteExe) {
    Write-Error 'sqlite3.exe not found. Download SQLite command-line tools from https://www.sqlite.org/download.html , extract sqlite3.exe next to this script or on PATH, or pass -Sqlite3Path.'
    exit 2
}

Write-Host "Using sqlite3: $sqliteExe"

$item = Get-Item -LiteralPath $InputPath -ErrorAction Stop
if ($item.PSIsContainer) {
    $histories = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'History' })
    foreach ($h in $histories) {
        Export-OneChromiumHistory -HistoryFileInfo $h -Sqlite3Exe $sqliteExe -DeleteOriginalSqlite:$DeleteOriginalSqlite
    }

    $placesFiles = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'places.sqlite' })
    foreach ($p in $placesFiles) {
        Export-OneFirefoxPlaces -PlacesFileInfo $p -Sqlite3Exe $sqliteExe -DeleteOriginalSqlite:$DeleteOriginalSqlite
    }

    Write-Host "`nDone scanning folder: $($item.FullName)"
}
else {
    switch ($item.Name) {
        'History' {
            Export-OneChromiumHistory -HistoryFileInfo $item -Sqlite3Exe $sqliteExe -DeleteOriginalSqlite:$DeleteOriginalSqlite
        }
        'places.sqlite' {
            Export-OneFirefoxPlaces -PlacesFileInfo $item -Sqlite3Exe $sqliteExe -DeleteOriginalSqlite:$DeleteOriginalSqlite
        }
        default {
            Write-Error "Expected a folder, or a file named History or places.sqlite. Got: $($item.Name)"
            exit 3
        }
    }
    Write-Host "`nDone."
}
