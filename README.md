# Windows Makeover 0.2.0-beta

A cautious PowerShell tool for first-line troubleshooting on slow Windows PCs. It is designed for helping family and friends: diagnose transparently first, then offer only clearly scoped actions.

> **Beta status:** Diagnosis, JSON reports, and the guided cleanup workflow are implemented and automatically tested. Before broad use, test the beta on several real Windows 7 through Windows 11 PCs. It does not replace backups or professional diagnosis of hardware faults, malware, or drive failures.

## What the tool does

### Phase 1: Diagnosis only

`Diagnosis` makes **no changes**. It collects and saves a JSON report containing:

- Windows version, computer name, and administrator status
- free space on the system drive
- size and file count of the current user's temp folder
- size of the current user's Recycle Bin
- startup-app count and details
- pending Windows restart and time since the last restart
- available memory and the five currently largest memory consumers
- a five-second CPU, system-drive, and commit-utilization sample by default, including notable CPU and I/O processes
- the system drive's type, model, and Windows-reported basic state
- automatic or manual paging-file management
- registered antivirus protection and, when available, Defender real-time protection
- the age of the most recent hotfix detected through `Win32_QuickFixEngineering`
- Windows product family and general support status
- the active power plan when Windows can read it

The console displays a concise, readable assessment. The complete report also contains a version-specific manual playbook for startup apps, updates, malware scans, drive optimization, power mode, visual effects, clean-boot testing, system-file repair, file-system checks, and recovery. These steps are never run automatically.

### Phase 2: Guided actions

`Remediate` accepts only a recent report from the same PC and the same Windows user. The report must be no more than 30 days old and no more than five minutes in the future. Generate a new diagnosis instead of using an older report format.

Before presenting actions, the tool measures the temp folder and Recycle Bin again. Edited recommendations or size values in the JSON file cannot trigger an action. Every currently available action shows its scope and estimated space recovery and requires individual confirmation.

| Action | Offered when | Actual scope |
|---|---|---|
| `CleanTempFiles` | More than 500 MB in the user's temp folder | Deletes only files in the current user's temp folder. Locked files are skipped and counted as failures. |
| `CleanRecycleBin` | More than 500 MB in the Recycle Bin | Empties the current user's Recycle Bin on local drives. Files cannot be restored through the Recycle Bin afterward. |

Startup apps, updates, antivirus, paging file, power plan, visual effects, clean boot, drive optimization, system repair, and recovery are reported only as **guidance** or manual review steps. The tool does not change them automatically.

Every cleanup action that actually starts is also recorded next to the diagnostic report as `remediation-audit-YYYYMMDD.jsonl`. Each line includes a timestamp, the report used, the action, its result, and removed and failed items. A `-WhatIf` run deliberately creates no audit entry because no cleanup is performed.

## Requirements

- Windows 7 SP1, Windows 8/8.1, Windows 10, or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- no administrator access is required for the supported cleanup actions

On older Windows versions, some modern storage or Defender interfaces may not exist. The diagnosis marks those probes as unavailable and continues with the remaining data. Windows PowerShell 5.1 must already be installed on Windows 7.

## Quick start

1. Copy or clone the repository to the affected PC.
2. Open PowerShell in the project directory.
3. Start a diagnosis:

```powershell
.\windows-makeover.ps1 -Mode Diagnosis
```

By default, the report is written to `reports\diagnosis-YYYYMMDD-HHMMSS.json`.

You can lengthen the short sample for a smoother average or skip it completely:

```powershell
.\windows-makeover.ps1 -Mode Diagnosis -SampleSeconds 15
.\windows-makeover.ps1 -Mode Diagnosis -SampleSeconds 0
```

Values from 0 to 60 seconds are supported. A short sample is only a snapshot and does not replace a longer performance trace for intermittent hangs.

4. Start the guided cleanup with the report you just created:

```powershell
.\windows-makeover.ps1 -Mode Remediate -ReportPath .\reports\diagnosis-YYYYMMDD-HHMMSS.json
```

### Preview first, then act

`-WhatIf` performs **no deletion** and is the recommended first Remediate run:

```powershell
.\windows-makeover.ps1 -Mode Remediate -ReportPath .\reports\diagnosis-YYYYMMDD-HHMMSS.json -WhatIf
```

You can select a single action explicitly:

```powershell
.\windows-makeover.ps1 -Mode Remediate -ReportPath .\reports\diagnosis-YYYYMMDD-HHMMSS.json -Action CleanTempFiles
```

`-Force` only skips the tool's own Y/N prompt. It is intended for supervised automation and is not the default path.

## Execution Policy

Review scripts downloaded from the internet before running them. If Windows blocks the file, inspect it first, then open the file properties and choose **Unblock**. Alternatively, unblock only this file:

```powershell
Unblock-File .\windows-makeover.ps1
```

No global Execution Policy relaxation and no `ExecutionPolicy Bypass` are necessary.

## Safety boundaries

Windows Makeover does **not** perform aggressive debloating and specifically does not:

- automatically remove preinstalled apps,
- run registry cleaners or broad registry changes,
- disable Windows services, Defender, updates, or telemetry,
- delete files from Downloads, Documents, or the Desktop,
- run DISM/component-store cleanup,
- modify drivers or BIOS settings.

Drive checks read only the status values that Windows provides. `OK` or `Healthy` is not a complete SMART diagnosis and does not guarantee a healthy drive. Likewise, the last hotfix reported by WMI is not complete proof that Windows Update is fully current.

Diagnostic reports remain local, but contain the computer name, user SID, process names, startup-app names, and system and security status. Review and anonymize them before sharing if necessary. Full startup command lines are deliberately not saved.

These interventions can damage recovery options, updates, or applications. Any future optional expert profile should use only individually selected, understandable, reversible actions and create a restore point beforehand.

## Troubleshooting beyond the tool

The tool cannot reliably rule out a hardware fault, overheating, malware, or unstable drivers. If the PC remains slow after cleanup, sensible next steps are:

1. Finish Windows Update and restart.
2. Use Task Manager to check for sustained high CPU, RAM, disk, or network activity.
3. Check the drive's SMART values with a suitable vendor or diagnostic tool; back up data first if anything looks suspicious.
4. Run a current scan with the registered antivirus product.
5. Consider a hardware upgrade rather than further tweaks for mechanical hard drives or systems with only 4 GB RAM.
6. Use DISM/SFC — or SFC and CheckSUR on Windows 7 — only when there is a specific Windows error.
7. Run CHKDSK with repair options only after a file-system finding and with a verified backup.

Regular Windows 7, Windows 8/8.1, and Windows 10 editions are marked as no longer regularly supported. LTSC, LTSB, IoT, Embedded, POSReady, and Server editions intentionally receive only guidance to check their distinct Microsoft lifecycle individually.

## Development and tests

The tests require Pester 5.7.1. Install it for the current user:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
```

The Pester suite covers diagnosis and recommendation logic, Windows lifecycle, the manual playbook, live thresholds, report binding to PC and user, `-WhatIf`, remediation audit logging, JSON storage, UTF-8 BOM, and entry-point syntax:

```powershell
Invoke-Pester .\tests\WindowsMakeover.Tests.ps1 -Output Detailed
```

## Releases

A tag such as `v0.2.0-beta` starts the release workflow. It tests the tag on Windows PowerShell 5.1 and PowerShell 7, then publishes three files:

- `windows-makeover-0.2.0-beta.ps1` is the standalone script without an external module.
- `windows-makeover-0.2.0-beta.zip` contains the regular entry script, module, and README.
- `SHA256SUMS.txt` contains SHA-256 checksums for both downloads.

Compare a download's checksum on Windows with:

```powershell
Get-FileHash .\windows-makeover-0.2.0-beta.ps1 -Algorithm SHA256
```

The workflow can also be triggered manually in GitHub Actions for an existing tag. The release version, tag, and the tool version declared in `windows-makeover.ps1` must match.

## Project structure

```text
src/WindowsMakeover.psm1       # Testable diagnosis, report, and cleanup logic
windows-makeover.ps1           # Windows entry point for Diagnosis and Remediate
build/New-WMReleaseAssets.ps1  # Creates the standalone script, ZIP, and SHA-256 file
tests/WindowsMakeover.Tests.ps1
.github/workflows/test.yml      # Pester on Windows PowerShell 5.1 and PowerShell 7
.github/workflows/release.yml   # Tests tags, builds assets, and creates GitHub releases
.editorconfig                   # UTF-8 BOM for PowerShell source files
reports/                        # Locally generated, unversioned reports
```