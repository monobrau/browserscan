<#
.SYNOPSIS
  Copies browser history databases and related SQLite sidecars for offline analysis.

.DESCRIPTION
  Intended for ScreenConnect Backstage / SYSTEM context: walks C:\Users\*\AppData and
  gathers Chromium-family History (+wal/shm), Firefox places.sqlite (+wal/shm), plus
  lightweight extras (Bookmarks, Preferences). Output: C:\Temp\<yyyy-MM-dd_HHmmss>\
  One or more ZIP parts (<computer>_BrowserArtifacts_PartNNN.zip), each holding at most
  -MaxFilesPerZip files (paths inside archives mirror the staging layout).

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

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\Collect-BrowserArtifacts.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = 'C:\Temp',
    [switch]$IncludeExtras,
    [ValidateRange(1, 9999)][int]$MaxFilesPerZip = 10,
    [switch]$KeepUncompressed
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
IncludeExtras:   $IncludeExtras
MaxFilesPerZip:  $MaxFilesPerZip
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
}

$stageRoot = Join-Path $destRoot $computer
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
