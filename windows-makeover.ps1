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

    [ValidateRange(0, 60)]
    [int]$SampleSeconds = 5,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WMToolVersion = '0.2.0-beta'

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

function Limit-WMPercent {
    param([double]$Value)

    return [math]::Round([math]::Min(100, [math]::Max(0, $Value)), 1)
}

function Get-WMPerformanceSample {
    param(
        [Parameter(Mandatory)][string]$SystemDrive,
        [ValidateRange(0, 60)][int]$DurationSeconds = 5
    )

    if ($DurationSeconds -eq 0) {
        return [pscustomobject]@{
            Status                       = 'Skipped'
            DurationSeconds              = 0
            SampleCount                  = 0
            AverageCpuPercent            = $null
            PeakCpuPercent               = $null
            AverageSystemDiskBusyPercent = $null
            PeakSystemDiskBusyPercent    = $null
            AverageCommittedPercent      = $null
            AvailableMemoryMiB           = $null
            PagesOutputPerSecond          = $null
            TopCpuProcesses               = @()
            TopIoProcesses                = @()
        }
    }

    $cpuSamples = [System.Collections.Generic.List[double]]::new()
    $diskSamples = [System.Collections.Generic.List[double]]::new()
    $commitSamples = [System.Collections.Generic.List[double]]::new()
    $lastMemory = $null
    $lastProcesses = @()

    for ($sampleIndex = 0; $sampleIndex -lt $DurationSeconds; $sampleIndex++) {
        Start-Sleep -Seconds 1

        try {
            $cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            $cpuSamples.Add((Limit-WMPercent -Value ([double]$cpu.PercentProcessorTime)))
        }
        catch {
            # Performance classes can be unavailable or rebuilding on older systems.
        }

        try {
            $memory = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
            $lastMemory = $memory
            $commitSamples.Add((Limit-WMPercent -Value ([double]$memory.PercentCommittedBytesInUse)))
        }
        catch {
            # The remaining probes and the report are still useful.
        }

        try {
            $disk = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_LogicalDisk -Filter "Name='$SystemDrive'" -ErrorAction Stop
            $diskSamples.Add((Limit-WMPercent -Value ([double]$disk.PercentDiskTime)))
        }
        catch {
            # The drive type and basic status are collected independently.
        }

        if ($sampleIndex -eq ($DurationSeconds - 1)) {
            try {
                $lastProcesses = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop | Where-Object { $_.Name -notin @('_Total', 'Idle') })
            }
            catch {
                $lastProcesses = @()
            }
        }

    }

    $logicalProcessors = 1
    try {
        $processorCount = [int](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors
        if ($processorCount -gt 0) { $logicalProcessors = $processorCount }
    }
    catch {
        $logicalProcessors = 1
    }

    $topCpuProcesses = @(
        $lastProcesses |
            Sort-Object -Property PercentProcessorTime -Descending |
            Select-Object -First 5 @{ Name = 'Name'; Expression = { [string]$_.Name } },
                @{ Name = 'Id'; Expression = { [int]$_.IDProcess } },
                @{ Name = 'CpuPercent'; Expression = { Limit-WMPercent -Value ([double]$_.PercentProcessorTime / $logicalProcessors) } }
    )
    $topIoProcesses = @(
        $lastProcesses |
            Sort-Object -Property IODataBytesPersec -Descending |
            Select-Object -First 5 @{ Name = 'Name'; Expression = { [string]$_.Name } },
                @{ Name = 'Id'; Expression = { [int]$_.IDProcess } },
                @{ Name = 'IoBytesPerSecond'; Expression = { [int64]$_.IODataBytesPersec } }
    )

    $availableProbeCount = @($cpuSamples.Count, $diskSamples.Count, $commitSamples.Count | Where-Object { $_ -gt 0 }).Count
    $status = if ($availableProbeCount -eq 3) { 'Available' } elseif ($availableProbeCount -gt 0) { 'Partial' } else { 'Unavailable' }

    [pscustomobject]@{
        Status                       = $status
        DurationSeconds              = $DurationSeconds
        SampleCount                  = [math]::Max($cpuSamples.Count, [math]::Max($diskSamples.Count, $commitSamples.Count))
        AverageCpuPercent            = if ($cpuSamples.Count) { Limit-WMPercent -Value (($cpuSamples | Measure-Object -Average).Average) } else { $null }
        PeakCpuPercent               = if ($cpuSamples.Count) { Limit-WMPercent -Value (($cpuSamples | Measure-Object -Maximum).Maximum) } else { $null }
        AverageSystemDiskBusyPercent = if ($diskSamples.Count) { Limit-WMPercent -Value (($diskSamples | Measure-Object -Average).Average) } else { $null }
        PeakSystemDiskBusyPercent    = if ($diskSamples.Count) { Limit-WMPercent -Value (($diskSamples | Measure-Object -Maximum).Maximum) } else { $null }
        AverageCommittedPercent      = if ($commitSamples.Count) { Limit-WMPercent -Value (($commitSamples | Measure-Object -Average).Average) } else { $null }
        AvailableMemoryMiB           = if ($null -ne $lastMemory) { [int64]$lastMemory.AvailableMBytes } else { $null }
        PagesOutputPerSecond          = if ($null -ne $lastMemory) { [int64]$lastMemory.PagesOutputPersec } else { $null }
        TopCpuProcesses               = $topCpuProcesses
        TopIoProcesses                = $topIoProcesses
    }
}

function Get-WMSystemDriveDevice {
    param([Parameter(Mandatory)][string]$DriveId)

    try {
        $logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$DriveId'" -ErrorAction Stop
        $partition = Get-CimAssociatedInstance -InputObject $logicalDisk -Association Win32_LogicalDiskToPartition -ErrorAction Stop | Select-Object -First 1
        $diskDrive = Get-CimAssociatedInstance -InputObject $partition -Association Win32_DiskDriveToDiskPartition -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $diskDrive) { throw 'No physical system drive association was returned.' }

        $mediaType = 'Unknown'
        $healthStatus = 'Unknown'
        $busType = 'Unknown'
        $getPhysicalDisk = Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue
        if ($null -ne $getPhysicalDisk) {
            try {
                $physicalDisk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$diskDrive.Index } | Select-Object -First 1
                if ($null -ne $physicalDisk) {
                    if ([string]$physicalDisk.MediaType -in @('SSD', 'HDD')) { $mediaType = [string]$physicalDisk.MediaType }
                    if (-not [string]::IsNullOrWhiteSpace([string]$physicalDisk.HealthStatus)) { $healthStatus = [string]$physicalDisk.HealthStatus }
                    if (-not [string]::IsNullOrWhiteSpace([string]$physicalDisk.BusType)) { $busType = [string]$physicalDisk.BusType }
                }
            }
            catch {
                # Win32_DiskDrive still provides model and basic status.
            }
        }

        if ($mediaType -eq 'Unknown' -and [string]$diskDrive.Model -match '(?i)SSD|Solid State') {
            $mediaType = 'SSD'
        }

        return [pscustomobject]@{
            ProbeStatus  = 'Available'
            DiskIndex    = [int]$diskDrive.Index
            Model        = [string]$diskDrive.Model
            BasicStatus  = [string]$diskDrive.Status
            MediaType    = $mediaType
            HealthStatus = $healthStatus
            BusType      = $busType
            SizeBytes    = [int64]$diskDrive.Size
        }
    }
    catch {
        return [pscustomobject]@{
            ProbeStatus  = 'Unavailable'
            DiskIndex    = $null
            Model        = $null
            BasicStatus  = 'Unknown'
            MediaType    = 'Unknown'
            HealthStatus = 'Unknown'
            BusType      = 'Unknown'
            SizeBytes    = $null
            Error        = $_.Exception.Message
        }
    }
}

function Get-WMPageFileInfo {
    param([Parameter(Mandatory)][psobject]$ComputerSystem)

    try {
        $usage = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)
        return [pscustomobject]@{
            ProbeStatus       = 'Available'
            AutomaticManaged  = [bool]$ComputerSystem.AutomaticManagedPagefile
            FileCount         = $usage.Count
            AllocatedSizeMiB  = [int64](($usage | Measure-Object -Property AllocatedBaseSize -Sum).Sum)
            CurrentUsageMiB   = [int64](($usage | Measure-Object -Property CurrentUsage -Sum).Sum)
            PeakUsageMiB      = [int64](($usage | Measure-Object -Property PeakUsage -Sum).Sum)
        }
    }
    catch {
        return [pscustomobject]@{
            ProbeStatus       = 'Unavailable'
            AutomaticManaged  = $null
            FileCount         = $null
            AllocatedSizeMiB  = $null
            CurrentUsageMiB   = $null
            PeakUsageMiB      = $null
            Error             = $_.Exception.Message
        }
    }
}

function Get-WMAntivirusInfo {
    $probeStatus = 'Available'
    $products = @()
    $securityCenterError = $null
    try {
        $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    }
    catch {
        $probeStatus = 'Unavailable'
        $securityCenterError = $_.Exception.Message
    }

    $defenderEnabled = $null
    $defenderRealtime = $null
    $defenderSignatureUpdatedAt = $null
    $defenderQuickScanAgeDays = $null
    if ($null -ne (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        try {
            $defender = Get-MpComputerStatus -ErrorAction Stop
            $defenderEnabled = [bool]$defender.AntivirusEnabled
            $defenderRealtime = [bool]$defender.RealTimeProtectionEnabled
            if ($null -ne $defender.AntivirusSignatureLastUpdated) {
                $defenderSignatureUpdatedAt = ([datetime]$defender.AntivirusSignatureLastUpdated).ToUniversalTime().ToString('o')
            }
            if ($null -ne $defender.QuickScanAge -and [uint32]$defender.QuickScanAge -ne [uint32]::MaxValue) {
                $defenderQuickScanAgeDays = [int]$defender.QuickScanAge
            }
        }
        catch {
            # A third-party antivirus can legitimately disable Defender cmdlets.
        }
    }

    [pscustomobject]@{
        ProbeStatus                  = $probeStatus
        ProductCount                 = if ($probeStatus -eq 'Available') { $products.Count } else { $null }
        ProductNames                 = @($products | ForEach-Object { [string]$_.displayName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        ProductStates                = @($products | ForEach-Object { [uint32]$_.productState })
        DefenderEnabled              = $defenderEnabled
        DefenderRealTimeProtection   = $defenderRealtime
        DefenderSignatureUpdatedAt   = $defenderSignatureUpdatedAt
        DefenderQuickScanAgeDays     = $defenderQuickScanAgeDays
        Error                        = $securityCenterError
    }
}

function Get-WMUpdateInfo {
    try {
        $hotFixes = @(Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction Stop)
        $datedHotFixes = [System.Collections.Generic.List[object]]::new()
        foreach ($hotFix in $hotFixes) {
            $installedOn = [datetime]::MinValue
            $installedOnText = [string]$hotFix.InstalledOn
            if (-not [string]::IsNullOrWhiteSpace($installedOnText) -and
                ([datetime]::TryParse($installedOnText, [Globalization.CultureInfo]::CurrentCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$installedOn) -or
                 [datetime]::TryParse($installedOnText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$installedOn))) {
                $datedHotFixes.Add([pscustomobject]@{ HotFixId = [string]$hotFix.HotFixID; InstalledOn = $installedOn })
            }
        }

        $latest = $datedHotFixes | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
        return [pscustomobject]@{
            ProbeStatus              = 'Available'
            HotFixCount              = $hotFixes.Count
            LastHotFixId             = if ($null -ne $latest) { $latest.HotFixId } else { $null }
            LastHotFixInstalledOn    = if ($null -ne $latest) { $latest.InstalledOn.ToUniversalTime().ToString('o') } else { $null }
            LastHotFixAgeDays        = if ($null -ne $latest) { [int][math]::Floor(((Get-Date) - $latest.InstalledOn).TotalDays) } else { $null }
        }
    }
    catch {
        return [pscustomobject]@{
            ProbeStatus           = 'Unavailable'
            HotFixCount           = $null
            LastHotFixId          = $null
            LastHotFixInstalledOn = $null
            LastHotFixAgeDays     = $null
            Error                 = $_.Exception.Message
        }
    }
}

function Get-WMActivePowerPlan {
    try {
        $output = & powercfg.exe /GETACTIVESCHEME 2>$null
        $text = [string]($output -join ' ')
        $guidMatch = [regex]::Match($text, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
        $nameMatch = [regex]::Match($text, '\(([^)]+)\)')
        return [pscustomobject]@{
            ProbeStatus = if ($guidMatch.Success) { 'Available' } else { 'Partial' }
            Guid        = if ($guidMatch.Success) { $guidMatch.Value.ToLowerInvariant() } else { $null }
            Name        = if ($nameMatch.Success) { $nameMatch.Groups[1].Value } else { $null }
        }
    }
    catch {
        return [pscustomobject]@{ ProbeStatus = 'Unavailable'; Guid = $null; Name = $null; Error = $_.Exception.Message }
    }
}

function Get-WMHostFacts {
    param([ValidateRange(0, 60)][int]$PerformanceSampleSeconds = 5)

    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    $systemDriveId = [System.IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd('\')
    $systemDriveName = $systemDriveId.TrimEnd(':')
    $systemDrive = Get-PSDrive -Name $systemDriveName
    $totalBytes = [Int64]($systemDrive.Used + $systemDrive.Free)
    $tempPreview = Get-WMCleanupPreview -Path $env:TEMP
    $startupItems = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue)
    $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $editionId = if ($null -ne $currentVersion) { [string]$currentVersion.EditionID } else { '' }
    $displayVersion = if ($null -ne $currentVersion -and $currentVersion.PSObject.Properties['DisplayVersion']) { [string]$currentVersion.DisplayVersion } else { '' }
    $lifecycle = Get-WMWindowsLifecycle -Version ([version]$operatingSystem.Version) -Caption ([string]$operatingSystem.Caption) -EditionId $editionId
    $systemDriveDevice = Get-WMSystemDriveDevice -DriveId $systemDriveId
    $performanceSample = Get-WMPerformanceSample -SystemDrive $systemDriveId -DurationSeconds $PerformanceSampleSeconds
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
        UserSid                  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        CollectedAt              = (Get-Date).ToUniversalTime().ToString('o')
        IsAdministrator          = Test-WMAdministrator
        OperatingSystem          = $operatingSystem.Caption
        OperatingSystemVersion   = $operatingSystem.Version
        EditionId                = $editionId
        DisplayVersion           = $displayVersion
        Lifecycle                = $lifecycle
        SystemDrive              = $systemDriveId
        SystemDriveTotalBytes    = $totalBytes
        SystemDriveFreeBytes     = [Int64]$systemDrive.Free
        SystemDriveFreePercent   = [math]::Round(($systemDrive.Free / $totalBytes) * 100, 1)
        SystemDriveDevice        = $systemDriveDevice
        PerformanceSample        = $performanceSample
        TempSizeBytes            = [Int64]$tempPreview.TotalBytes
        TempFileCount            = [Int]$tempPreview.FileCount
        TempPath                 = $tempPreview.Path
        RecycleBinSizeBytes      = Get-WMRecycleBinSize
        StartupApplicationCount  = $startupItems.Count
        StartupApplications      = @($startupItems | Select-Object Name, Location, User)
        RebootPending            = Get-WMPendingReboot
        PageFile                 = Get-WMPageFileInfo -ComputerSystem $computerSystem
        Antivirus                = Get-WMAntivirusInfo
        Updates                  = Get-WMUpdateInfo
        ActivePowerPlan          = Get-WMActivePowerPlan
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
    Write-Host "Windows Makeover $script:WMToolVersion - Diagnose" -ForegroundColor Cyan
    Write-Host "PC: $($facts.ComputerName) | $($facts.OperatingSystem)"
    Write-Host "Version: $($facts.DisplayVersion) | Edition: $($facts.EditionId)"
    Write-Host "Gesamtstatus: $($Report.OverallHealth)" -ForegroundColor $statusColor
    Write-Host ''
    Write-Host 'Übersicht' -ForegroundColor Cyan
    Write-Host ("  Systemlaufwerk: {0} frei von {1} ({2}%)" -f (Format-WMByteSize $facts.SystemDriveFreeBytes), (Format-WMByteSize $facts.SystemDriveTotalBytes), $facts.SystemDriveFreePercent)
    Write-Host ("  Temporäre Dateien: {0} in {1} Dateien" -f (Format-WMByteSize $facts.TempSizeBytes), $facts.TempFileCount)
    Write-Host ("  Papierkorb: {0}" -f (Format-WMByteSize $facts.RecycleBinSizeBytes))
    Write-Host "  Autostart-Einträge: $($facts.StartupApplicationCount)"
    Write-Host "  Verfügbarer Arbeitsspeicher: $($facts.MemoryAvailableGiB) GiB ($($facts.MemoryAvailablePercent)%)"
    Write-Host "  Letzter Neustart: vor $($facts.UptimeDays) Tagen"

    if ($facts.Lifecycle.Status -ne 'Unknown') {
        Write-Host "  Windows-Support: $($facts.Lifecycle.Status)"
    }
    if ($facts.SystemDriveDevice.ProbeStatus -eq 'Available') {
        Write-Host "  Systemdatenträger: $($facts.SystemDriveDevice.MediaType), $($facts.SystemDriveDevice.Model), Zustand $($facts.SystemDriveDevice.BasicStatus)/$($facts.SystemDriveDevice.HealthStatus)"
    }
    if ($facts.PerformanceSample.Status -in @('Available', 'Partial')) {
        Write-Host "  Kurzprobe: CPU $($facts.PerformanceSample.AverageCpuPercent)%, Datenträger $($facts.PerformanceSample.AverageSystemDiskBusyPercent)%, Commit $($facts.PerformanceSample.AverageCommittedPercent)%"
    }
    elseif ($facts.PerformanceSample.Status -eq 'Skipped') {
        Write-Host '  Kurzprobe: übersprungen'
    }
    if ($facts.PageFile.ProbeStatus -eq 'Available') {
        Write-Host "  Auslagerungsdatei: automatisch verwaltet = $($facts.PageFile.AutomaticManaged), zugewiesen $($facts.PageFile.AllocatedSizeMiB) MiB"
    }
    if ($facts.ActivePowerPlan.ProbeStatus -in @('Available', 'Partial')) {
        $powerPlanLabel = if (-not [string]::IsNullOrWhiteSpace([string]$facts.ActivePowerPlan.Name)) { $facts.ActivePowerPlan.Name } else { $facts.ActivePowerPlan.Guid }
        Write-Host "  Energiesparplan: $powerPlanLabel"
    }
    if ($facts.Antivirus.ProbeStatus -eq 'Available') {
        $antivirusNames = if (@($facts.Antivirus.ProductNames).Count) { @($facts.Antivirus.ProductNames) -join ', ' } else { 'keiner registriert' }
        Write-Host "  Virenschutz: $antivirusNames"
    }
    if ($facts.Updates.ProbeStatus -eq 'Available' -and $null -ne $facts.Updates.LastHotFixAgeDays) {
        Write-Host "  Letzter erkannter Hotfix: $($facts.Updates.LastHotFixId), vor $($facts.Updates.LastHotFixAgeDays) Tagen"
    }

    if (@($Report.Recommendations).Count -eq 0) {
        Write-Host ''
        Write-Host 'Keine auffälligen, automatisch geprüften Punkte gefunden.' -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host 'Empfehlungen' -ForegroundColor Cyan
        foreach ($recommendation in $Report.Recommendations) {
            Write-Host ("  [{0}] {1}" -f $recommendation.Severity, $recommendation.Title)
            Write-Host ("        {0}" -f $recommendation.Description)
        }
    }

    if (@($facts.PerformanceSample.TopCpuProcesses).Count -gt 0) {
        Write-Host ''
        Write-Host 'CPU-Prozesse am Ende der Kurzprobe' -ForegroundColor Cyan
        $facts.PerformanceSample.TopCpuProcesses | Format-Table Name, Id, CpuPercent -AutoSize
    }

    if (@($facts.PerformanceSample.TopIoProcesses).Count -gt 0) {
        Write-Host ''
        Write-Host 'I/O-Prozesse am Ende der Kurzprobe' -ForegroundColor Cyan
        $facts.PerformanceSample.TopIoProcesses |
            Select-Object Name, Id, @{ Name = 'I/O pro Sekunde'; Expression = { Format-WMByteSize $_.IoBytesPerSecond } } |
            Format-Table -AutoSize
    }

    if (@($facts.TopMemoryProcesses).Count -gt 0) {
        Write-Host ''
        Write-Host 'Größte aktuell sichtbare Arbeitsspeicher-Nutzung' -ForegroundColor Cyan
        $facts.TopMemoryProcesses |
            Select-Object Name, Id, @{ Name = 'Arbeitsspeicher'; Expression = { Format-WMByteSize $_.MemoryBytes } } |
            Format-Table -AutoSize
    }

    Write-Host ''
    Write-Host 'Der JSON-Bericht enthält außerdem einen manuellen, versionsabhängigen Prüf- und Reparaturleitfaden.'
}

Assert-WindowsHost

if ($Mode -eq 'Diagnose') {
    $facts = Get-WMHostFacts -PerformanceSampleSeconds $SampleSeconds
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

$report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$reportValidation = Test-WMDiagnosticReport -Report $report -ComputerName $env:COMPUTERNAME -UserSid $currentUserSid -TempPath $env:TEMP
if (-not $reportValidation.IsValid) {
    throw ("Der Diagnosebericht kann nicht für Bereinigungen verwendet werden: " + ($reportValidation.Reasons -join ' '))
}

# Größen und Schwellenwerte werden direkt vor der Auswahl erneut geprüft.
# Empfehlungen und Messwerte aus der JSON-Datei steuern keine Löschaktion.
$currentTempPreview = Get-WMCleanupPreview -Path $env:TEMP
$currentCleanupReport = [pscustomobject]@{
    SchemaVersion = $report.SchemaVersion
    Facts = [pscustomobject]@{
        TempSizeBytes       = [Int64]$currentTempPreview.TotalBytes
        RecycleBinSizeBytes = [Int64](Get-WMRecycleBinSize)
    }
}
$plan = @(Get-WMSafeRemediationPlan -Report $currentCleanupReport)
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
            $result = Invoke-WMSafeRemediation -Id $step.Id -Confirm:$false -WhatIf:$WhatIfPreference
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
