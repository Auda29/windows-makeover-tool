#requires -Version 5.1
<#!
.SYNOPSIS
  Erstellt eine Windows-Diagnose oder führt ausdrücklich bestätigte, risikoarme Bereinigungen aus.

.DESCRIPTION
  Diagnose ist rein lesend. Remediate akzeptiert einen lokalen Diagnosebericht,
  zeigt den Umfang jeder Aktion und führt keine Maßnahme ohne Bestätigung aus.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Diagnose', 'Remediate')]
    [string]$Mode = 'Diagnose',

    [string]$ReportPath,

    [ValidateSet('CleanTempFiles', 'CleanRecycleBin')]
    [string[]]$Action,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WMToolVersion = '0.1.0-alpha'

$modulePath = Join-Path $PSScriptRoot 'src\WindowsMakeover.psm1'
Import-Module $modulePath -Force

function Assert-WindowsHost {
    if ($env:OS -ne 'Windows_NT') {
        throw 'windows-makeover muss auf einem Windows-PC ausgeführt werden.'
    }
}

function Format-WMByteSize {
    param([Parameter(Mandatory)][Int64]$Bytes)

    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Test-WMAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WMRecycleBinSize {
    $size = [Int64]0
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' })

    foreach ($drive in $drives) {
        $recyclePath = Join-Path -Path $drive.Root -ChildPath (Join-Path -Path '$Recycle.Bin' -ChildPath $sid)
        if (-not (Test-Path -LiteralPath $recyclePath -PathType Container)) {
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $recyclePath -File -Force -Recurse -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            $size += [Int64]$file.Length
        }
    }
    return $size
}

function Get-WMPendingReboot {
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    if (@($registryPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) {
        return $true
    }

    $sessionManagerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pendingRename = Get-ItemProperty -LiteralPath $sessionManagerPath -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return $null -ne $pendingRename
}

function Get-WMHostFacts {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    $systemDriveName = [System.IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd(':', '\')
    $systemDrive = Get-PSDrive -Name $systemDriveName
    $totalBytes = [Int64]($systemDrive.Used + $systemDrive.Free)
    $tempPreview = Get-WMCleanupPreview -Path $env:TEMP
    $startupItems = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue)
    $topMemoryProcesses = @(
        Get-Process -ErrorAction SilentlyContinue |
            Sort-Object -Property WorkingSet64 -Descending |
            Select-Object -First 5 @{ Name = 'Name'; Expression = { $_.ProcessName } }, Id,
                @{ Name = 'MemoryBytes'; Expression = { [Int64]$_.WorkingSet64 } }
    )
    $availableMemoryPercent = [math]::Round(($operatingSystem.FreePhysicalMemory / $operatingSystem.TotalVisibleMemorySize) * 100, 1)

    [pscustomobject]@{
        ToolVersion              = $script:WMToolVersion
        ComputerName             = $env:COMPUTERNAME
        CollectedAt              = (Get-Date).ToUniversalTime().ToString('o')
        IsAdministrator          = Test-WMAdministrator
        OperatingSystem          = $operatingSystem.Caption
        OperatingSystemVersion   = $operatingSystem.Version
        SystemDrive              = "${systemDriveName}:"
        SystemDriveTotalBytes    = $totalBytes
        SystemDriveFreeBytes     = [Int64]$systemDrive.Free
        SystemDriveFreePercent   = [math]::Round(($systemDrive.Free / $totalBytes) * 100, 1)
        TempSizeBytes            = [Int64]$tempPreview.TotalBytes
        TempFileCount            = [Int]$tempPreview.FileCount
        RecycleBinSizeBytes      = Get-WMRecycleBinSize
        StartupApplicationCount  = $startupItems.Count
        RebootPending            = Get-WMPendingReboot
        MemoryTotalGiB           = [math]::Round(($operatingSystem.TotalVisibleMemorySize / 1MB), 1)
        MemoryAvailableGiB       = [math]::Round(($operatingSystem.FreePhysicalMemory / 1MB), 1)
        MemoryAvailablePercent   = $availableMemoryPercent
        UptimeDays               = [math]::Round(((Get-Date) - $operatingSystem.LastBootUpTime).TotalDays, 1)
        TopMemoryProcesses       = $topMemoryProcesses
    }
}

function Show-WMReportSummary {
    param([Parameter(Mandatory)][psobject]$Report)

    $facts = $Report.Facts
    $statusColor = switch ($Report.OverallHealth) {
        'Healthy' { 'Green' }
        'Critical' { 'Red' }
        default { 'Yellow' }
    }

    Write-Host ''
    Write-Host "Windows Makeover $script:WMToolVersion — Diagnose" -ForegroundColor Cyan
    Write-Host "PC: $($facts.ComputerName) | $($facts.OperatingSystem)"
    Write-Host "Gesamtstatus: $($Report.OverallHealth)" -ForegroundColor $statusColor
    Write-Host ''
    Write-Host 'Übersicht' -ForegroundColor Cyan
    Write-Host ("  Systemlaufwerk: {0} frei von {1} ({2}%)" -f (Format-WMByteSize $facts.SystemDriveFreeBytes), (Format-WMByteSize $facts.SystemDriveTotalBytes), $facts.SystemDriveFreePercent)
    Write-Host ("  Temporäre Dateien: {0} in {1} Dateien" -f (Format-WMByteSize $facts.TempSizeBytes), $facts.TempFileCount)
    Write-Host ("  Papierkorb: {0}" -f (Format-WMByteSize $facts.RecycleBinSizeBytes))
    Write-Host "  Autostart-Einträge: $($facts.StartupApplicationCount)"
    Write-Host "  Verfügbarer Arbeitsspeicher: $($facts.MemoryAvailableGiB) GiB ($($facts.MemoryAvailablePercent)%)"
    Write-Host "  Letzter Neustart: vor $($facts.UptimeDays) Tagen"

    if (@($Report.Recommendations).Count -eq 0) {
        Write-Host ''
        Write-Host 'Keine auffälligen, automatisch geprüften Punkte gefunden.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'Empfehlungen' -ForegroundColor Cyan
    foreach ($recommendation in $Report.Recommendations) {
        Write-Host ("  [{0}] {1}" -f $recommendation.Severity, $recommendation.Title)
        Write-Host ("        {0}" -f $recommendation.Description)
    }

    if (@($facts.TopMemoryProcesses).Count -gt 0) {
        Write-Host ''
        Write-Host 'Größte aktuell sichtbare Arbeitsspeicher-Nutzung' -ForegroundColor Cyan
        $facts.TopMemoryProcesses |
            Select-Object Name, Id, @{ Name = 'Arbeitsspeicher'; Expression = { Format-WMByteSize $_.MemoryBytes } } |
            Format-Table -AutoSize
    }
}

Assert-WindowsHost

if ($Mode -eq 'Diagnose') {
    $facts = Get-WMHostFacts
    $report = New-WMDiagnosis -Facts $facts
    $defaultPath = Join-Path $PSScriptRoot (Join-Path 'reports' ("diagnosis-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
    $destination = if ($ReportPath) { $ReportPath } else { $defaultPath }
    $savedPath = Save-WMDiagnosticReport -Report $report -Path $destination

    Show-WMReportSummary -Report $report
    Write-Host ''
    Write-Host "Diagnosebericht gespeichert: $savedPath" -ForegroundColor Green
    Write-Host 'Nächster Schritt: Remediate mit genau diesem Bericht starten.'
    return
}

if (-not $ReportPath) {
    throw 'Für Remediate ist -ReportPath zu einem zuvor erzeugten Diagnosebericht erforderlich.'
}
if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw "Diagnosebericht nicht gefunden: $ReportPath"
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$reportValidation = Test-WMDiagnosticReport -Report $report -ComputerName $env:COMPUTERNAME
if (-not $reportValidation.IsValid) {
    throw ("Der Diagnosebericht kann nicht für Bereinigungen verwendet werden: " + ($reportValidation.Reasons -join ' '))
}
$plan = @(Get-WMSafeRemediationPlan -Report $report)
if ($Action) {
    $plan = @($plan | Where-Object { $_.Id -in $Action })
}

if ($plan.Count -eq 0) {
    Write-Host 'Für diesen Bericht gibt es keine automatisch erlaubte Maßnahme.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host 'Folgende risikoarme Maßnahmen stehen zur Auswahl:' -ForegroundColor Cyan
$plan |
    Select-Object Id, Risk, @{ Name = 'Geschätzter Speichergewinn'; Expression = { Format-WMByteSize $_.EstimatedBytes } }, Scope |
    Format-Table -AutoSize

foreach ($step in $plan) {
    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host "'$($step.Title)' ausführen? (J/N)"
        if ($answer -notmatch '^[JjYy]$') {
            Write-Host "Übersprungen: $($step.Id)"
            continue
        }
    }

    switch ($step.Id) {
        'CleanTempFiles' {
            $result = Invoke-WMSafeRemediation -Id $step.Id -TempPath $env:TEMP -Confirm:$false -WhatIf:$WhatIfPreference
        }
        'CleanRecycleBin' {
            $result = Invoke-WMSafeRemediation -Id $step.Id -Confirm:$false -WhatIf:$WhatIfPreference
        }
        default { throw "Nicht unterstützte Aktion im Plan: $($step.Id)" }
    }

    if ($result.Removed -eq -1) {
        Write-Host "$($result.ActionId): $($result.Status)"
    }
    else {
        Write-Host "$($result.ActionId): $($result.Status); entfernte Dateien: $($result.Removed); Fehler: $($result.Failed)"
    }
}
