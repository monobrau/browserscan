# browserscan

PowerShell collection script for **offline browser artifact analysis** (history SQLite databases, Firefox `places.sqlite`, legacy Windows WebCache, optional extras). Designed for **remote Windows endpoints** (for example ScreenConnect Backstage running as **SYSTEM**): it walks `C:\Users\*`, stages copies under `C:\Temp\<timestamp>\<COMPUTERNAME>\`, then builds **multipart ZIP archives** (`<COMPUTERNAME>_BrowserArtifacts_PartNNN.zip`) with **at most 10 files per ZIP** by default and removes the staging folder afterward.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- Sufficient rights to read other users’ profiles when running elevated / as SYSTEM
- **Browsers closed** on the target when possible—SQLite files may be locked while open
- **`sqlite3.exe`** ([SQLite command-line tools](https://www.sqlite.org/download.html)) on `%PATH%`, or pass **`-Sqlite3Path`**, when using **`-ExportCsv`**

## Legal / policy

Only use on machines and accounts where you have **clear authorization** (employment policy, customer contract, or informed consent). Browser history and related artifacts are sensitive.

## Usage (local)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Collect-BrowserArtifacts.ps1
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `-OutputRoot` | Parent folder for the dated run folder (default: `C:\Temp`; folder is created if missing). |
| `-IncludeExtras` | Also copy Chromium bookmarks/preferences/top sites/favicons/login & web data metadata; Firefox cookies/form history/permissions. |
| `-MaxFilesPerZip` | Maximum files per ZIP part (default: `10`). |
| `-KeepUncompressed` | Keep the staging folder after ZIP creation. |
| `-ExportCsv` | Export Chromium **`urls`** / **`visits`** and Firefox **`moz_places`** / **`moz_historyvisits`** from staged SQLite copies to CSV, then remove those SQLite files before ZIP. **WebCache** and non-history extras are unchanged (still copied as-is). Requires **`sqlite3.exe`**. |
| `-Sqlite3Path` | Full path to `sqlite3.exe` when it is not on `PATH`. |

### Output layout

After a successful run, under `C:\Temp\<yyyy-MM-dd_HHmmss>\`:

- `<COMPUTERNAME>_BrowserArtifacts_Part001.zip`, `Part002.zip`, …  
  Paths inside each ZIP mirror the staging tree (for example `Users\<profile>\Edge\Default\History_urls.csv` when `-ExportCsv` was used, otherwise SQLite `History` files).
- If ZIP fails, the uncompressed staging tree may remain for troubleshooting.

### Artifacts collected

- **Chromium family** (per profile with `History`): Chrome, Edge, Brave, Vivaldi, Yandex, Chromium, Opera / Opera GX — `History` plus `-wal`, `-shm`, `-journal` when present.
- **Firefox**: `places.sqlite` (+ wal/shm) per profile from `profiles.ini`.
- **Legacy IE / old Edge**: `%LocalAppData%\Microsoft\Windows\WebCache` copied via robocopy into `WebCache_ESE` before ZIP.

### Analyzing Chromium `History`

SQLite database; inspect **`urls`** and **`visits`** (for example with [DB Browser for SQLite](https://sqlitebrowser.org/)).

## One-liner: download from GitHub and run

Replace the repo URL if you fork or rename it.

**Download to `%TEMP%` then execute:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1'; $p=Join-Path $env:TEMP 'Collect-BrowserArtifacts.ps1'; Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing; & $p"
```

**With CSV export (requires `sqlite3.exe` on PATH or `-Sqlite3Path`):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1'; $p=Join-Path $env:TEMP 'Collect-BrowserArtifacts.ps1'; Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing; & $p -ExportCsv"
```

**Same with extras (larger collection):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1'; $p=Join-Path $env:TEMP 'Collect-BrowserArtifacts.ps1'; Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing; & $p -IncludeExtras"
```

**Optional:** pin to a commit SHA instead of `main` in the raw URL for supply-chain stability.

## Repository

[https://github.com/monobrau/browserscan](https://github.com/monobrau/browserscan)
