# browserscan

PowerShell collection script for **offline browser artifact analysis** (history SQLite databases, Firefox `places.sqlite`, legacy Windows WebCache, optional extras). Designed for **remote Windows endpoints** (for example ScreenConnect Backstage running as **SYSTEM**): it walks `C:\Users\*`, stages copies under `C:\Temp\<timestamp>\<COMPUTERNAME>\`, then builds **multipart ZIP archives** (`<COMPUTERNAME>_BrowserArtifacts_PartNNN.zip`) with **at most 10 files per ZIP** by default and removes the staging folder afterward.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- Sufficient rights to read other users’ profiles when running elevated / as SYSTEM
- **Browsers closed** on the target when possible—SQLite files may be locked while open
- **`sqlite3.exe`** ([SQLite command-line tools](https://www.sqlite.org/download.html)) only when you use **`-ExportCsv`** on the endpoint: put **`sqlite3.exe` in the same folder as `Collect-BrowserArtifacts.ps1`**, add it to `PATH`, or pass **`-Sqlite3Path`**. If endpoints never have SQLite, **omit `-ExportCsv`** and convert later with **`Export-BrowserHistoryToCsv.ps1`** on your analysis PC (see below).

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
| `-ExportCsv` | Export Chromium **`urls`** / **`visits`** and Firefox **`moz_places`** / **`moz_historyvisits`** from staged SQLite copies to CSV, then remove those SQLite files before ZIP (unless conversion fails). **WebCache** and non-history extras stay as copied files. Requires **`sqlite3.exe`** (beside the script, on `PATH`, or **`-Sqlite3Path`**). |
| `-Sqlite3Path` | Full path to `sqlite3.exe` when it is not beside the script and not on `PATH`. |

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

## Converting databases to CSV later (no SQLite on the endpoint)

If remote PCs do not have SQLite, collect **without** `-ExportCsv` so ZIPs contain the raw **`History`** and **`places.sqlite`** files (and optional WAL/SHM). On a machine you control:

1. From [sqlite.org/download](https://www.sqlite.org/download.html), download **Precompiled binaries for Windows** (bundle that includes **`sqlite3.exe`**) and keep that executable beside **`Export-BrowserHistoryToCsv.ps1`** or on `PATH`.
2. Extract one or more **`…_BrowserArtifacts_PartNNN.zip`** files into a folder so you see paths such as **`Users\<profile>\Edge\Default\History`**.
3. Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Export-BrowserHistoryToCsv.ps1 -InputPath 'D:\path\to\extracted\folder'
```

- **`InputPath`** can be the extracted archive root (recursive scan), or a single file **`History`** or **`places.sqlite`**.
- CSVs are written **next to each database**. Original DB files are **kept** unless you pass **`-DeleteOriginalSqlite`**.

Portable toolkit idea for ScreenConnect: copy **`Collect-BrowserArtifacts.ps1`** + **`sqlite3.exe`** into one folder so `-ExportCsv` works without a machine-wide SQLite install.

## One-liner: download from GitHub and run

Replace the repo URL if you fork or rename it.

**Important:** If you paste the command into **PowerShell**, do **not** wrap `-Command` in **double** quotes with `$variables` inside—the **parent** session expands `$u`, `$p`, and `$env:TEMP` before the child starts, so `-Uri` / `-OutFile` become empty and you get `Missing expression after '&'`. Use one of the fixes below.

### Recommended (works when pasted into PowerShell)

Put `-Command` in **single quotes**. Inside that string, use **doubled** single quotes (`''`) for literal single quotes:

**Download to `%TEMP%` then execute:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$u=''https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1''; $p=Join-Path $env:TEMP ''Collect-BrowserArtifacts.ps1''; Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing; & $p'
```

**With CSV export (requires `sqlite3.exe` on PATH or `-Sqlite3Path`):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$u=''https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1''; $p=Join-Path $env:TEMP ''Collect-BrowserArtifacts.ps1''; Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing; & $p -ExportCsv'
```

**Same with extras (larger collection):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$u=''https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1''; $p=Join-Path $env:TEMP ''Collect-BrowserArtifacts.ps1''; Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing; & $p -IncludeExtras'
```

### From Command Prompt (`cmd.exe`)

Double quotes are usually fine because `cmd` does not expand PowerShell variables:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1'; $p=Join-Path $env:TEMP 'Collect-BrowserArtifacts.ps1'; Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing; & $p"
```

### Alternative in PowerShell only (escape `$` for the parent)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$u='https://raw.githubusercontent.com/monobrau/browserscan/main/Collect-BrowserArtifacts.ps1'; `$p=Join-Path `$env:TEMP 'Collect-BrowserArtifacts.ps1'; Invoke-WebRequest -Uri `$u -OutFile `$p -UseBasicParsing; & `$p"
```

**Optional:** pin to a commit SHA instead of `main` in the raw URL for supply-chain stability.

## Repository

[https://github.com/monobrau/browserscan](https://github.com/monobrau/browserscan)
