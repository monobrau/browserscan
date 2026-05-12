<#
.SYNOPSIS
  Copies browser history databases and related SQLite sidecars for offline analysis.

.DESCRIPTION
  Intended for ScreenConnect Backstage / SYSTEM context: walks C:\Users\*\AppData and
  gathers Chromium-family History (+wal/shm), Firefox places.sqlite (+wal/shm), plus
  lightweight extras (Bookmarks, Preferences). Output: C:\Temp\<yyyy-MM-dd_HHmmss>\
  One or more ZIP parts (<computer>_BrowserArtifacts_PartNNN.zip), each holding at most
  -MaxFilesPerZip files (paths inside archives mirror the staging layout). Use -ExportCsv to
  emit history tables as CSV via sqlite3.exe and drop copied SQLite history databases from staging.

  Note: If a browser is open, SQLite files may be locked and copy can fail—close
  browsers on the endpoint first when possible, or collect again after a reboot.

.PARAMETER OutputRoot
  Parent folder for the dated collection directory (default: C:\Temp).

.PARAMETER IncludeExtras
  Also copy Bookmarks, Preferences, Top Sites, Favicons where present (larger).

.PARAMETER MaxFilesPerZip
  Maximum number of files placed in each ZIP part (default: 10).

.PARAMETER KeepUncompressed
  Keep the staging folder after creating ZIPs (default: staging folder is removed).

.PARAMETER ExportCsv
  After staging copies, export browsing history from SQLite files to CSV using sqlite3.exe,
  then remove those SQLite files from staging (WebCache and non-history extras are unchanged).
  Requires sqlite3.exe beside this script, on PATH, or -Sqlite3Path.

.PARAMETER Sqlite3Path
  Full path to sqlite3.exe when it is not on PATH.

.PARAMETER IncludeRecoveryArtifacts
  Collect extra artifacts that may survive or complement cleared History: Chromium session/tab
  restore files, Media History, Visited Links, Network Action Predictor; Firefox session store
  snapshots and prefs.js; Windows Timeline ActivitiesCache (if present); and browser-related
  Prefetch files (requires read access to %SystemRoot%\Prefetch).

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\Collect-BrowserArtifacts.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = 'C:\Temp',
    [switch]$IncludeExtras,
    [switch]$IncludeRecoveryArtifacts,
    [ValidateRange(1, 9999)][int]$MaxFilesPerZip = 10,
    [switch]$KeepUncompressed,
    [switch]$ExportCsv,
    [string]$Sqlite3Path = ''
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$destRoot = Join-Path $OutputRoot $stamp
$computer = $env:COMPUTERNAME

function Test-DirExists([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [System.IO.Directory]::Exists($Path) } catch { return $false }
}

function Test-FileExists([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [System.IO.File]::Exists($Path) } catch { return $false }
}

function Ensure-Dir([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Copy-Artifact {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath,
        [string]$LogLabel
    )
    if (-not (Test-FileExists $SourcePath)) { return }
    Ensure-Dir (Split-Path -Parent $DestPath)
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $DestPath -Force
        Write-Host "OK  $LogLabel"
    }
    catch {
        Write-Warning "FAIL $LogLabel :: $($_.Exception.Message)"
    }
}

function Copy-ChromiumProfileArtifacts {
    param(
        [string]$BrowserLabel,
        [string]$UserFolderName,
        [string]$UserDataPath  # ...\User Data
    )
    if (-not (Test-DirExists $UserDataPath)) { return }

    $profiles = Get-ChildItem -LiteralPath $UserDataPath -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            Test-FileExists (Join-Path $_.FullName 'History')
        }

    foreach ($prof in $profiles) {
        $rel = "Users\$UserFolderName\$BrowserLabel\$($prof.Name)"
        $baseDest = Join-Path (Join-Path $destRoot $computer) $rel
        Ensure-Dir $baseDest

        $historyBase = Join-Path $prof.FullName 'History'
        foreach ($suffix in @('', '-wal', '-shm', '-journal')) {
            Copy-Artifact -SourcePath "$historyBase$suffix" -DestPath (Join-Path $baseDest "History$suffix") -LogLabel "$BrowserLabel\$($prof.Name)\History$suffix"
        }

        if ($IncludeExtras) {
            $extras = @(
                @{ Name = 'Bookmarks'; Dest = 'Bookmarks' },
                @{ Name = 'Bookmarks.bak'; Dest = 'Bookmarks.bak' },
                @{ Name = 'Preferences'; Dest = 'Preferences' },
                @{ Name = 'Secure Preferences'; Dest = 'Secure Preferences' },
                @{ Name = 'Top Sites'; Dest = 'Top Sites' },
                @{ Name = 'Top Sites-journal'; Dest = 'Top Sites-journal' },
                @{ Name = 'Favicons'; Dest = 'Favicons' },
                @{ Name = 'Favicons-wal'; Dest = 'Favicons-wal' },
                @{ Name = 'Favicons-shm'; Dest = 'Favicons-shm' },
                @{ Name = 'Favicons-journal'; Dest = 'Favicons-journal' },
                @{ Name = 'Login Data'; Dest = 'Login Data' },
                @{ Name = 'Login Data-journal'; Dest = 'Login Data-journal' },
                @{ Name = 'Web Data'; Dest = 'Web Data' },
                @{ Name = 'Web Data-wal'; Dest = 'Web Data-wal' },
                @{ Name = 'Web Data-shm'; Dest = 'Web Data-shm' },
                @{ Name = 'Web Data-journal'; Dest = 'Web Data-journal' }
            )
            foreach ($x in $extras) {
                $src = Join-Path $prof.FullName $x.Name
                Copy-Artifact -SourcePath $src -DestPath (Join-Path $baseDest $x.Dest) -LogLabel "$BrowserLabel\$($prof.Name)\$($x.Name)"
            }
        }

        if ($IncludeRecoveryArtifacts) {
            foreach ($n in @('Current Session', 'Last Session', 'Current Tabs', 'Last Tabs', 'Visited Links')) {
                $src = Join-Path $prof.FullName $n
                Copy-Artifact -SourcePath $src -DestPath (Join-Path $baseDest $n) -LogLabel "$BrowserLabel\$($prof.Name)\$n"
            }

            $napBase = Join-Path $prof.FullName 'Network Action Predictor'
            foreach ($suffix in @('', '-wal', '-shm', '-journal')) {
                Copy-Artifact -SourcePath "$napBase$suffix" -DestPath (Join-Path $baseDest "Network Action Predictor$suffix") -LogLabel "$BrowserLabel\$($prof.Name)\Network Action Predictor$suffix"
            }

            $mediaBase = Join-Path $prof.FullName 'Media History'
            foreach ($suffix in @('', '-wal', '-shm', '-journal')) {
                Copy-Artifact -SourcePath "$mediaBase$suffix" -DestPath (Join-Path $baseDest "Media History$suffix") -LogLabel "$BrowserLabel\$($prof.Name)\Media History$suffix"
            }
        }
    }
}

function Copy-FirefoxArtifacts {
    param([string]$UserFolderName)

    $ffRoot = "C:\Users\$UserFolderName\AppData\Roaming\Mozilla\Firefox"
    $profilesIni = Join-Path $ffRoot 'profiles.ini'
    if (-not (Test-FileExists $profilesIni)) { return }

    $sections = @{}
    $current = $null
    foreach ($line in Get-Content -LiteralPath $profilesIni -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $current = $matches[1]
            $sections[$current] = @{}
        }
        elseif ($current -and $line -match '^\s*(\w+)\s*=\s*(.+)\s*$') {
            $sections[$current][$matches[1]] = $matches[2].Trim()
        }
    }

    $seen = @{}
    foreach ($secName in $sections.Keys) {
        $sec = $sections[$secName]
        if (-not $sec.Path) { continue }
        $pathType = if ($sec.IsRelative -eq '1') { 'relative' } else { 'absolute' }

        $profPath = if ($pathType -eq 'relative') {
            Join-Path $ffRoot $sec.Path
        }
        else {
            $sec.Path
        }

        if (-not (Test-DirExists $profPath)) { continue }
        $key = $profPath.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $leaf = Split-Path -Leaf $profPath
        $destDir = Join-Path (Join-Path (Join-Path $destRoot $computer) "Users\$UserFolderName\Firefox") $leaf
        Ensure-Dir $destDir

        foreach ($name in @('places.sqlite', 'places.sqlite-wal', 'places.sqlite-shm')) {
            Copy-Artifact -SourcePath (Join-Path $profPath $name) -DestPath (Join-Path $destDir $name) -LogLabel "Firefox\$leaf\$name"
        }

        if ($IncludeExtras) {
            foreach ($name in @('cookies.sqlite', 'cookies.sqlite-wal', 'cookies.sqlite-shm', 'formhistory.sqlite', 'permissions.sqlite')) {
                Copy-Artifact -SourcePath (Join-Path $profPath $name) -DestPath (Join-Path $destDir $name) -LogLabel "Firefox\$leaf\$name"
            }
        }

        if ($IncludeRecoveryArtifacts) {
            Copy-Artifact -SourcePath (Join-Path $profPath 'sessionstore.jsonlz4') -DestPath (Join-Path $destDir 'sessionstore.jsonlz4') -LogLabel "Firefox\$leaf\sessionstore.jsonlz4"
            Copy-Artifact -SourcePath (Join-Path $profPath 'prefs.js') -DestPath (Join-Path $destDir 'prefs.js') -LogLabel "Firefox\$leaf\prefs.js"

            $sbSrc = Join-Path $profPath 'sessionstore-backups'
            if (Test-DirExists $sbSrc) {
                $sbDest = Join-Path $destDir 'sessionstore-backups'
                Ensure-Dir $sbDest
                try {
                    robocopy $sbSrc $sbDest /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
                    Write-Host "OK  Firefox\$leaf\sessionstore-backups (robocopy)"
                }
                catch {
                    Write-Warning "FAIL Firefox\$leaf\sessionstore-backups :: $($_.Exception.Message)"
                }
            }
        }
    }
}

function Compress-ToMultipartZips {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ZipOutputFolder,
        [Parameter(Mandatory)][string]$ArchiveBaseName,
        [ValidateRange(1, 9999)][int]$MaxFilesPerPart,
        [switch]$KeepSourceFolder
    )

    if (-not (Test-DirExists $SourceRoot)) { return }

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
    catch {
        Write-Warning "ZIP skipped (System.IO.Compression.FileSystem unavailable): $($_.Exception.Message)"
        return
    }

    $srcRootFull = [System.IO.Path]::GetFullPath($SourceRoot)
    $files = @(Get-ChildItem -LiteralPath $srcRootFull -Recurse -File -ErrorAction SilentlyContinue | Sort-Object -Property FullName)
    if ($files.Count -eq 0) {
        Write-Host "ZIP: no files under staging root; skipping archives."
        return
    }

    $part = 1
    for ($i = 0; $i -lt $files.Count; $i += $MaxFilesPerPart) {
        $take = [Math]::Min($MaxFilesPerPart, $files.Count - $i)
        $chunk = @($files[$i..($i + $take - 1)])
        $zipName = '{0}_Part{1:D3}.zip' -f $ArchiveBaseName, $part
        $zipPath = Join-Path $ZipOutputFolder $zipName

        $zip = $null
        try {
            if (Test-FileExists $zipPath) {
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
            }

            $zip = [System.IO.Compression.ZipFile]::Open(
                $zipPath,
                [System.IO.Compression.ZipArchiveMode]::Create
            )

            foreach ($f in $chunk) {
                $full = $f.FullName
                $rel = $full.Substring($srcRootFull.Length).TrimStart('\', '/')
                $entryName = $rel.Replace('\', '/')
                $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $outStream = $entry.Open()
                $fileStream = $null
                try {
                    $fileStream = [System.IO.File]::OpenRead($full)
                    $fileStream.CopyTo($outStream)
                }
                finally {
                    if ($null -ne $fileStream) { $fileStream.Dispose() }
                    $outStream.Dispose()
                }
            }

            Write-Host "ZIP OK  $zipName ($take files)"
        }
        catch {
            Write-Warning "ZIP FAIL $zipName :: $($_.Exception.Message)"
            if (Test-FileExists $zipPath) {
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            }
            throw
        }
        finally {
            if ($null -ne $zip) {
                $zip.Dispose()
            }
        }

        $part++
    }

    if (-not $KeepSourceFolder) {
        try {
            Remove-Item -LiteralPath $srcRootFull -Recurse -Force -ErrorAction Stop
            Write-Host "ZIP: removed staging folder $srcRootFull"
        }
        catch {
            Write-Warning "ZIP: could not remove staging folder: $($_.Exception.Message)"
        }
    }
}

function Copy-BrowserPrefetchHints {
    param(
        [Parameter(Mandatory)][string]$UserFolderName
    )
    if (-not $IncludeRecoveryArtifacts) { return }

    $pfRoot = Join-Path $env:SystemRoot 'Prefetch'
    if (-not (Test-DirExists $pfRoot)) { return }

    $dest = Join-Path (Join-Path (Join-Path $destRoot $computer) "Users\$UserFolderName") '_Prefetch_Browsers'
    Ensure-Dir $dest

    $filters = @(
        'CHROME.EXE-*.pf',
        'CHROMIUM.EXE-*.pf',
        'MSEDGE.EXE-*.pf',
        'MICROSOFTEDGE.EXE-*.pf',
        'BRAVE.EXE-*.pf',
        'FIREFOX.EXE-*.pf',
        'OPERA.EXE-*.pf',
        'VIVALDI.EXE-*.pf',
        'YANDEX_BROWSER.EXE-*.pf'
    )

    foreach ($pat in $filters) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pfRoot -File -Filter $pat -ErrorAction SilentlyContinue)) {
            Copy-Artifact -SourcePath $f.FullName -DestPath (Join-Path $dest $f.Name) -LogLabel "Prefetch\$($f.Name)"
        }
    }
}

function Copy-ActivitiesCacheArtifact {
    param(
        [Parameter(Mandatory)][string]$UserFolderName,
        [Parameter(Mandatory)][string]$UserProfileFullPath
    )
    if (-not $IncludeRecoveryArtifacts) { return }

    $cdp = Join-Path $UserProfileFullPath 'AppData\Local\ConnectedDevicesPlatform'
    if (-not (Test-DirExists $cdp)) { return }

    $lDir = Join-Path $cdp "L.$UserFolderName"
    if (-not (Test-DirExists $lDir)) {
        $first = Get-ChildItem -LiteralPath $cdp -Directory -Filter 'L.*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^L\.' } |
            Select-Object -First 1
        if (-not $first) { return }
        $lDir = $first.FullName
    }

    $destDir = Join-Path (Join-Path (Join-Path $destRoot $computer) "Users\$UserFolderName") 'WindowsTimeline_ActivitiesCache'
    Ensure-Dir $destDir

    foreach ($suffix in @('', '-wal', '-shm')) {
        $src = Join-Path $lDir "ActivitiesCache.db$suffix"
        Copy-Artifact -SourcePath $src -DestPath (Join-Path $destDir "ActivitiesCache.db$suffix") -LogLabel "ActivitiesCache.db$suffix"
    }
}

function Copy-WebCacheFolder {
    param([string]$UserFolderName)
    # Legacy IE / old Edge WebCache (ESE, not SQLite—still useful for historic URL activity)
    $wc = "C:\Users\$UserFolderName\AppData\Local\Microsoft\Windows\WebCache"
    if (-not (Test-DirExists $wc)) { return }

    $dest = Join-Path (Join-Path (Join-Path $destRoot $computer) "Users\$UserFolderName") 'WebCache_ESE'
    Ensure-Dir $dest
    try {
        robocopy $wc $dest /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
        Write-Host "OK  WebCache (robocopy) Users\$UserFolderName"
    }
    catch {
        Write-Warning "FAIL WebCache Users\$UserFolderName :: $($_.Exception.Message)"
    }
}

function Resolve-Sqlite3Exe {
    param([string]$Sqlite3Path)
    if (-not [string]::IsNullOrWhiteSpace($Sqlite3Path) -and (Test-FileExists $Sqlite3Path)) {
        return [System.IO.Path]::GetFullPath($Sqlite3Path)
    }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $bundled = Join-Path (Split-Path -Parent $PSCommandPath) 'sqlite3.exe'
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

function Export-StagedHistorySqliteToCsv {
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$Sqlite3Exe,
        [switch]$DeleteOriginalSqlite
    )
    if (-not (Test-DirExists $StageRoot)) { return }

    $histories = @(Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'History' })

    foreach ($hf in $histories) {
        $dir = $hf.DirectoryName
        $dbPath = $hf.FullName
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
            continue
        }

        if ($urlsOk -and $DeleteOriginalSqlite) {
            foreach ($suffix in @('', '-wal', '-shm', '-journal')) {
                $p = "${dbPath}${suffix}"
                if (Test-FileExists $p) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Host "CSV: removed staged Chromium History DB files under $dir"
        }
    }

    $placesFiles = @(Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'places.sqlite' })

    foreach ($pf in $placesFiles) {
        $dir = $pf.DirectoryName
        $dbPath = $pf.FullName
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
            continue
        }

        if ($placesOk -and $DeleteOriginalSqlite) {
            foreach ($name in @('places.sqlite', 'places.sqlite-wal', 'places.sqlite-shm')) {
                $p = Join-Path $dir $name
                if (Test-FileExists $p) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Host "CSV: removed staged Firefox places.sqlite DB files under $dir"
        }
    }
}

# --- main ---
Ensure-Dir $OutputRoot
Ensure-Dir $destRoot
Ensure-Dir (Join-Path $destRoot $computer)
$metaPath = Join-Path (Join-Path $destRoot $computer) '_collection_meta.txt'
@"
Collected (UTC): $(([datetime]::UtcNow).ToString('o'))
Local time:      $(Get-Date -Format 'o')
Computer:        $computer
User context:    $env:USERNAME ($env:USERDOMAIN\$env:USERNAME)
IncludeExtras:           $IncludeExtras
IncludeRecoveryArtifacts: $IncludeRecoveryArtifacts
MaxFilesPerZip:           $MaxFilesPerZip
ExportCsv:       $ExportCsv
Sqlite3Path:     $(if ([string]::IsNullOrWhiteSpace($Sqlite3Path)) { '(PATH)' } else { $Sqlite3Path })
"@ | Set-Content -LiteralPath $metaPath -Encoding UTF8

Write-Host "Destination: $destRoot"

$userDirs = Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(Public|Default|Default User|All Users)$' }

foreach ($ud in $userDirs) {
    $uname = $ud.Name
    $local = $ud.FullName

    Write-Host "`n=== User: $uname ==="

    # Chromium-family: Local AppData ...\User Data
    $map = @(
        @{ Label = 'Chrome';   Path = Join-Path $local 'AppData\Local\Google\Chrome\User Data' },
        @{ Label = 'Edge';     Path = Join-Path $local 'AppData\Local\Microsoft\Edge\User Data' },
        @{ Label = 'Brave';    Path = Join-Path $local 'AppData\Local\BraveSoftware\Brave-Browser\User Data' },
        @{ Label = 'Vivaldi';  Path = Join-Path $local 'AppData\Local\Vivaldi\User Data' },
        @{ Label = 'Yandex';   Path = Join-Path $local 'AppData\Local\Yandex\YandexBrowser\User Data' },
        @{ Label = 'Opera';    Path = Join-Path $local 'AppData\Roaming\Opera Software\Opera Stable' },
        @{ Label = 'OperaGX';  Path = Join-Path $local 'AppData\Roaming\Opera Software\Opera GX Stable' },
        @{ Label = 'Chromium'; Path = Join-Path $local 'AppData\Local\Chromium\User Data' }
    )

    foreach ($m in $map) {
        Copy-ChromiumProfileArtifacts -BrowserLabel $m.Label -UserFolderName $uname -UserDataPath $m.Path
    }

    Copy-FirefoxArtifacts -UserFolderName $uname
    Copy-WebCacheFolder -UserFolderName $uname
    Copy-BrowserPrefetchHints -UserFolderName $uname
    Copy-ActivitiesCacheArtifact -UserFolderName $uname -UserProfileFullPath $local
}

$stageRoot = Join-Path $destRoot $computer

if ($ExportCsv) {
    $sqliteExe = Resolve-Sqlite3Exe -Sqlite3Path $Sqlite3Path
    if (-not $sqliteExe) {
        Write-Warning 'ExportCsv: sqlite3.exe not found. Drop sqlite3.exe next to this script, add SQLite tools to PATH, or pass -Sqlite3Path. Staging keeps SQLite databases.'
    }
    else {
        Export-StagedHistorySqliteToCsv -StageRoot $stageRoot -Sqlite3Exe $sqliteExe -DeleteOriginalSqlite
    }
}

try {
    Compress-ToMultipartZips `
        -SourceRoot $stageRoot `
        -ZipOutputFolder $destRoot `
        -ArchiveBaseName "${computer}_BrowserArtifacts" `
        -MaxFilesPerPart $MaxFilesPerZip `
        -KeepSourceFolder:$KeepUncompressed
}
catch {
    Write-Warning "Multipart ZIP step aborted: $($_.Exception.Message)"
}

Write-Host "`nDone. Review: $destRoot"
