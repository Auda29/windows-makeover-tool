Set-StrictMode -Version Latest

$script:WMReportSchemaVersion = '1.4'

function Get-WMFactValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Facts,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    $property = $Facts.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function ConvertTo-WMNormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        if (-not [string]::Equals($fullPath, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $fullPath = $fullPath.TrimEnd('\', '/')
        }
        return $fullPath
    }
    catch {
        return $null
    }
}

function New-WMRecommendation {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('High', 'Medium', 'Low')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('Guidance', 'Remediation')][string]$ActionType
    )

    [pscustomobject]@{
        Id          = $Id
        Severity    = $Severity
        Title       = $Title
        Description = $Description
        ActionType  = $ActionType
    }
}

function Get-WMWindowsLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)][string]$Caption,
        [string]$EditionId = ''
    )

    $productText = "$Caption $EditionId"
    if ($productText -match '(?i)Server|Embedded|POSReady|LTSC|LTSB|IoT') {
        return [pscustomobject]@{
            ProductFamily  = 'SpecialEdition'
            Status         = 'SpecialLifecycle'
            SupportEndDate = $null
            Message        = 'This Windows edition has its own lifecycle. Check its edition and end-of-support date with Microsoft.'
        }
    }

    if ($Version.Major -eq 6 -and $Version.Minor -eq 1) {
        return [pscustomobject]@{
            ProductFamily  = 'Windows7'
            Status         = 'Unsupported'
            SupportEndDate = '2020-01-14'
            Message        = 'Regular support for Windows 7 has ended. Upgrading or replacing the device is safer than further tuning.'
        }
    }

    if ($Version.Major -eq 6 -and $Version.Minor -eq 2) {
        return [pscustomobject]@{
            ProductFamily  = 'Windows8'
            Status         = 'Unsupported'
            SupportEndDate = '2016-01-12'
            Message        = 'Regular support for Windows 8 has ended. Upgrading or replacing the device is safer than further tuning.'
        }
    }

    if ($Version.Major -eq 6 -and $Version.Minor -eq 3) {
        return [pscustomobject]@{
            ProductFamily  = 'Windows81'
            Status         = 'Unsupported'
            SupportEndDate = '2023-01-10'
            Message        = 'Regular support for Windows 8.1 has ended. Upgrading or replacing the device is safer than further tuning.'
        }
    }

    if ($Version.Major -eq 10 -and $Caption -match '(?i)Windows 10') {
        return [pscustomobject]@{
            ProductFamily  = 'Windows10'
            Status         = 'Unsupported'
            SupportEndDate = '2025-10-14'
            Message        = 'Regular support for Windows 10 has ended. Consider Windows 11, ESU, or replacing the device.'
        }
    }

    if ($Version.Major -eq 10 -and $Caption -match '(?i)Windows 11') {
        return [pscustomobject]@{
            ProductFamily  = 'Windows11'
            Status         = 'VersionSpecific'
            SupportEndDate = $null
            Message        = 'Support depends on the edition and Windows 11 version. Install a currently supported version.'
        }
    }

    [pscustomobject]@{
        ProductFamily  = 'Unknown'
        Status         = 'Unknown'
        SupportEndDate = $null
        Message        = 'The Windows support status could not be determined reliably.'
    }
}

function Get-WMManualPlaybook {
    param([Parameter(Mandatory)][psobject]$Facts)

    $versionText = [string](Get-WMFactValue -Facts $Facts -Name 'OperatingSystemVersion' -Default '')
    $version = $null
    if (-not [version]::TryParse($versionText, [ref]$version)) {
        $version = [version]'0.0'
    }
    $lifecycle = Get-WMFactValue -Facts $Facts -Name 'Lifecycle' -Default ([pscustomobject]@{})
    $lifecycleStatus = [string](Get-WMFactValue -Facts $lifecycle -Name 'Status' -Default 'Unknown')

    $startupStep = if ($version.Major -eq 6 -and $version.Minor -eq 1) {
        'Open msconfig and the startup folders. Review and document entries one at a time.'
    }
    else {
        'Open Task Manager > Startup apps. Review high-impact entries and entries with an unknown purpose one at a time.'
    }

    $updateStep = if ($lifecycleStatus -eq 'Unsupported') {
        'Consider an upgrade, an ESU exception, or replacing the device. Individual tuning steps do not replace security updates.'
    }
    else {
        'Open Windows Update, check for available updates, and complete any requested restart.'
    }

    $repairSteps = if ($version.Major -eq 6 -and $version.Minor -eq 1) {
        @(
            'Open an elevated command prompt only for Windows errors or damaged features.',
            'Run sfc /scannow.',
            'For Windows Update component errors, use the appropriate Microsoft System Update Readiness Tool.'
        )
    }

    else {
        @(
            'Open an elevated command prompt only for Windows errors or damaged features.',
            'Run DISM.exe /Online /Cleanup-Image /RestoreHealth.',
            'Danach Run sfc /scannow.'
        )
    }

    $powerStep = if ($version.Major -eq 6 -and $version.Minor -le 3) {
        'Open Control Panel > Hardware and Sound > Power Options. If performance is unexpectedly low while plugged in, check the Balanced plan.'
    }
    else {
        'Open Settings > System > Power & battery. If performance is unexpectedly low while plugged in, check the Balanced power mode.'
    }

    @(
        [pscustomobject]@{
            Id            = 'ReviewStartupApps'
            When          = 'Slow startup or many background programs'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @($startupStep)
        },
        [pscustomobject]@{
            Id            = 'UpdateOrUpgradeWindows'
            When          = 'An outdated Windows version, missing updates, or a pending restart'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @($updateStep)
        },
        [pscustomobject]@{
            Id            = 'RunMalwareScan'
            When          = 'Unknown processes, sustained high load, or no recent scan'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @('Open the registered antivirus product and start a quick scan. Follow the vendor instructions if it finds anything.')
        },
        [pscustomobject]@{
            Id            = 'OptimizeSystemDrive'
            When          = 'A mechanical hard drive or skipped Windows drive optimization'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('Open Windows drive optimization. Let Windows choose between HDD defragmentation and SSD TRIM.')
        },
        [pscustomobject]@{
            Id            = 'ReviewPowerPlan'
            When          = 'The PC is especially slow while plugged in or uses the Power Saver plan'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @($powerStep, 'On a laptop, a higher-performance mode increases power use, heat, and fan noise. Note the previous setting.')
        },
        [pscustomobject]@{
            Id            = 'ReviewVisualEffects'
            When          = 'Window animations and the interface stutter on older hardware'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @('Open SystemPropertiesPerformance.exe and test reducing individual visual effects. Document the previous selection.')
        },
        [pscustomobject]@{
            Id            = 'CleanBootTest'
            When          = 'The load cannot be linked to a single process or appears after sign-in'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('Open msconfig and first hide all Microsoft services.', 'Disable third-party services and startup apps only for a test, restart, then re-enable them gradually.', 'Restore normal startup after the test.')
        },
        [pscustomobject]@{
            Id            = 'RepairSystemFiles'
            When          = 'Windows features, updates, or system files are damaged'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = $repairSteps
        },
        [pscustomobject]@{
            Id            = 'CheckFileSystem'
            When          = 'File system errors, I/O errors, or a set dirty bit were found'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('Back up important data first.', 'Run CHKDSK only after a specific error finding and with the appropriate option.')
        },
        [pscustomobject]@{
            Id            = 'Recovery'
            When          = 'The installation remains unreliable after targeted diagnosis and repair'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('Check backups and the BitLocker recovery key.', 'Then choose System Restore, Reset, or reinstallation with supervision.')
        }
    )
}

function Get-WMDirectoryUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [DateTimeOffset]$DeadlineUtc = [DateTimeOffset]::MaxValue
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{
            Name                 = $Name
            Path                 = $Path
            ProbeStatus          = 'Unavailable'
            TotalBytes           = [int64]0
            FileCount            = 0
            SkippedReparsePoints = 0
            ErrorCount           = 0
            TimedOut             = $false
        }
    }

    try {
        $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Name = $Name; Path = $Path; ProbeStatus = 'Unavailable'; TotalBytes = [int64]0
            FileCount = 0; SkippedReparsePoints = 0; ErrorCount = 1; TimedOut = $false; Error = $_.Exception.Message
        }
    }
    $rootIsReparsePoint = ([int]$rootItem.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($rootIsReparsePoint) {
        return [pscustomobject]@{
            Name = $Name; Path = $rootItem.FullName; ProbeStatus = 'Partial'; TotalBytes = [int64]0
            FileCount = 0; SkippedReparsePoints = 1; ErrorCount = 0; TimedOut = $false
        }
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $directories = [System.Collections.Generic.Stack[string]]::new()
    $directories.Push($resolvedPath)
    $totalBytes = [int64]0
    $fileCount = 0
    $skippedReparsePoints = 0
    $errorCount = 0
    $timedOut = $false

    while ($directories.Count -gt 0 -and -not $timedOut) {
        if ([DateTimeOffset]::UtcNow -ge $DeadlineUtc) {
            $timedOut = $true
            break
        }
        $directoryPath = $directories.Pop()
        try {
            $items = @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)
        }
        catch {
            $errorCount++
            continue
        }

        foreach ($item in $items) {
            if ([DateTimeOffset]::UtcNow -ge $DeadlineUtc) {
                $timedOut = $true
                break
            }
            $isReparsePoint = ([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($item.PSIsContainer) {
                if ($isReparsePoint) {
                    $skippedReparsePoints++
                }
                else {
                    $directories.Push($item.FullName)
                }
                continue
            }

            try {
                $totalBytes += [int64]$item.Length
                $fileCount++
            }
            catch {
                $errorCount++
            }
        }
    }

    [pscustomobject]@{
        Name                 = $Name
        Path                 = $resolvedPath
        ProbeStatus          = if ($errorCount -eq 0 -and -not $timedOut) { 'Available' } else { 'Partial' }
        TotalBytes           = $totalBytes
        FileCount            = $fileCount
        SkippedReparsePoints = $skippedReparsePoints
        ErrorCount           = $errorCount
        TimedOut             = $timedOut
    }
}

function Get-WMKnownUserFolderUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Folders,
        [ValidateRange(1, 20)][int]$Top = 5,
        [DateTimeOffset]$DeadlineUtc = [DateTimeOffset]::MaxValue
    )

    $measurements = [System.Collections.Generic.List[object]]::new()
    $unavailableCount = 0
    foreach ($entry in $Folders.GetEnumerator()) {
        $usage = Get-WMDirectoryUsage -Path ([string]$entry.Value) -Name ([string]$entry.Key) -DeadlineUtc $DeadlineUtc
        if ($usage.ProbeStatus -eq 'Unavailable') {
            $unavailableCount++
        }
        else {
            $measurements.Add($usage)
        }
    }

    $orderedFolders = @($measurements | Sort-Object -Property TotalBytes -Descending | Select-Object -First $Top)
    $errorCount = [int](($measurements | Measure-Object -Property ErrorCount -Sum).Sum)
    $partialCount = @($measurements | Where-Object { $_.ProbeStatus -eq 'Partial' }).Count
    [pscustomobject]@{
        ProbeStatus     = if ($measurements.Count -eq 0) { 'Unavailable' } elseif ($errorCount -gt 0 -or $unavailableCount -gt 0 -or $partialCount -gt 0) { 'Partial' } else { 'Available' }
        Folders         = $orderedFolders
        MeasuredCount   = $measurements.Count
        UnavailableCount = $unavailableCount
        TotalBytes      = [int64](($measurements | Measure-Object -Property TotalBytes -Sum).Sum)
        ErrorCount      = $errorCount
    }
}

function Join-WMPathParts {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Parts
    )

    $result = $Root
    foreach ($part in $Parts) {
        $result = Join-Path $result $part
    }
    return $result
}

function Get-WMChromiumCacheUsage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$UserDataPath,
        [DateTimeOffset]$DeadlineUtc = [DateTimeOffset]::MaxValue
    )

    if (-not (Test-Path -LiteralPath $UserDataPath -PathType Container)) {
        return [pscustomobject]@{ Name = $Name; ProbeStatus = 'Unavailable'; TotalBytes = [int64]0; FileCount = 0; ProfileCount = 0; ErrorCount = 0 }
    }

    $profiles = @(
        Get-ChildItem -LiteralPath $UserDataPath -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                (([int]$_.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -eq 0) -and
                ($_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -like 'Profile *')
            }
    )
    $totalBytes = [int64]0
    $fileCount = 0
    $errorCount = 0
    $timedOut = $false
    foreach ($browserProfile in $profiles) {
        foreach ($cacheParts in @(@('Cache'), @('Code Cache'), @('GPUCache'))) {
            $cachePath = Join-WMPathParts -Root $browserProfile.FullName -Parts $cacheParts
            if (-not (Test-Path -LiteralPath $cachePath -PathType Container)) { continue }
            $usage = Get-WMDirectoryUsage -Path $cachePath -Name $Name -DeadlineUtc $DeadlineUtc
            $totalBytes += [int64]$usage.TotalBytes
            $fileCount += [int]$usage.FileCount
            $errorCount += [int]$usage.ErrorCount
            if ([bool]$usage.TimedOut) { $timedOut = $true }
        }
    }

    [pscustomobject]@{
        Name        = $Name
        ProbeStatus = if ($errorCount -eq 0 -and -not $timedOut) { 'Available' } else { 'Partial' }
        TotalBytes  = $totalBytes
        FileCount   = $fileCount
        ProfileCount = $profiles.Count
        ErrorCount  = $errorCount
    }
}

function Get-WMBrowserCacheUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalAppDataPath,
        [DateTimeOffset]$DeadlineUtc = [DateTimeOffset]::MaxValue
    )

    $chromeUserData = Join-WMPathParts -Root $LocalAppDataPath -Parts @('Google', 'Chrome', 'User Data')
    $edgeUserData = Join-WMPathParts -Root $LocalAppDataPath -Parts @('Microsoft', 'Edge', 'User Data')
    $firefoxProfiles = Join-WMPathParts -Root $LocalAppDataPath -Parts @('Mozilla', 'Firefox', 'Profiles')

    $browsers = [System.Collections.Generic.List[object]]::new()
    $browsers.Add((Get-WMChromiumCacheUsage -Name 'Google Chrome' -UserDataPath $chromeUserData -DeadlineUtc $DeadlineUtc))
    $browsers.Add((Get-WMChromiumCacheUsage -Name 'Microsoft Edge' -UserDataPath $edgeUserData -DeadlineUtc $DeadlineUtc))

    if (Test-Path -LiteralPath $firefoxProfiles -PathType Container) {
        $profiles = @(Get-ChildItem -LiteralPath $firefoxProfiles -Directory -Force -ErrorAction SilentlyContinue | Where-Object { (([int]$_.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -eq 0) })
        $firefoxBytes = [int64]0
        $firefoxFiles = 0
        $firefoxErrors = 0
        $firefoxTimedOut = $false
        foreach ($browserProfile in $profiles) {
            $cachePath = Join-Path $browserProfile.FullName 'cache2'
            if (-not (Test-Path -LiteralPath $cachePath -PathType Container)) { continue }
            $usage = Get-WMDirectoryUsage -Path $cachePath -Name 'Mozilla Firefox' -DeadlineUtc $DeadlineUtc
            $firefoxBytes += [int64]$usage.TotalBytes
            $firefoxFiles += [int]$usage.FileCount
            $firefoxErrors += [int]$usage.ErrorCount
            if ([bool]$usage.TimedOut) { $firefoxTimedOut = $true }
        }
        $browsers.Add([pscustomobject]@{
            Name = 'Mozilla Firefox'; ProbeStatus = if ($firefoxErrors -eq 0 -and -not $firefoxTimedOut) { 'Available' } else { 'Partial' }
            TotalBytes = $firefoxBytes; FileCount = $firefoxFiles; ProfileCount = $profiles.Count; ErrorCount = $firefoxErrors
        })
    }
    else {
        $browsers.Add([pscustomobject]@{ Name = 'Mozilla Firefox'; ProbeStatus = 'Unavailable'; TotalBytes = [int64]0; FileCount = 0; ProfileCount = 0; ErrorCount = 0 })
    }

    $availableBrowsers = @($browsers | Where-Object { $_.ProbeStatus -ne 'Unavailable' })
    $totalErrors = [int](($availableBrowsers | Measure-Object -Property ErrorCount -Sum).Sum)
    $partialBrowserCount = @($availableBrowsers | Where-Object { $_.ProbeStatus -eq 'Partial' }).Count
    [pscustomobject]@{
        ProbeStatus = if ($availableBrowsers.Count -eq 0) { 'Unavailable' } elseif ($totalErrors -gt 0 -or $partialBrowserCount -gt 0) { 'Partial' } else { 'Available' }
        Browsers     = $browsers.ToArray()
        TotalBytes   = [int64](($availableBrowsers | Measure-Object -Property TotalBytes -Sum).Sum)
        FileCount    = [int](($availableBrowsers | Measure-Object -Property FileCount -Sum).Sum)
        ErrorCount   = $totalErrors
    }
}

function ConvertTo-WMPendingUpdateSummary {
    [CmdletBinding()]
    param([object[]]$Updates = @())

    $securityCount = 0
    $rebootCount = 0
    $titles = [System.Collections.Generic.List[string]]::new()
    foreach ($update in @($Updates)) {
        $title = [string](Get-WMFactValue -Facts $update -Name 'Title' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($title)) { $titles.Add($title) }
        if ([bool](Get-WMFactValue -Facts $update -Name 'RebootRequired' -Default $false)) { $rebootCount++ }
        $categories = @(Get-WMFactValue -Facts $update -Name 'CategoryNames' -Default @())
        if (@($categories | Where-Object { [string]$_ -match '(?i)Security|Critical' }).Count -gt 0) { $securityCount++ }
    }

    [pscustomobject]@{
        ProbeStatus        = 'Available'
        PendingCount       = @($Updates).Count
        SecurityUpdateCount = $securityCount
        RebootRequiredCount = $rebootCount
        RebootRequired     = $rebootCount -gt 0
        Titles             = $titles.ToArray()
    }
}

function New-WMDiagnosis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Facts
    )

    $recommendations = [System.Collections.Generic.List[object]]::new()
    $freePercent = [double](Get-WMFactValue -Facts $Facts -Name 'SystemDriveFreePercent' -Default 100)
    $tempSize = [int64](Get-WMFactValue -Facts $Facts -Name 'TempSizeBytes' -Default 0)
    $recycleBinSize = [int64](Get-WMFactValue -Facts $Facts -Name 'RecycleBinSizeBytes' -Default 0)
    $startupCount = [int](Get-WMFactValue -Facts $Facts -Name 'StartupApplicationCount' -Default 0)
    $uptimeDays = [double](Get-WMFactValue -Facts $Facts -Name 'UptimeDays' -Default 0)
    $restartPending = [bool](Get-WMFactValue -Facts $Facts -Name 'RebootPending' -Default (Get-WMFactValue -Facts $Facts -Name 'UpdatesPending' -Default $false))
    $lifecycle = Get-WMFactValue -Facts $Facts -Name 'Lifecycle' -Default ([pscustomobject]@{})
    $performance = Get-WMFactValue -Facts $Facts -Name 'PerformanceSample' -Default ([pscustomobject]@{})
    $systemDriveDevice = Get-WMFactValue -Facts $Facts -Name 'SystemDriveDevice' -Default ([pscustomobject]@{})
    $pageFile = Get-WMFactValue -Facts $Facts -Name 'PageFile' -Default ([pscustomobject]@{})
    $antivirus = Get-WMFactValue -Facts $Facts -Name 'Antivirus' -Default ([pscustomobject]@{})
    $updates = Get-WMFactValue -Facts $Facts -Name 'Updates' -Default ([pscustomobject]@{})
    $powerPlan = Get-WMFactValue -Facts $Facts -Name 'ActivePowerPlan' -Default ([pscustomobject]@{})
    $userFolderUsage = Get-WMFactValue -Facts $Facts -Name 'UserFolderUsage' -Default ([pscustomobject]@{})
    $browserCacheUsage = Get-WMFactValue -Facts $Facts -Name 'BrowserCacheUsage' -Default ([pscustomobject]@{})
    $pendingUpdates = Get-WMFactValue -Facts $Facts -Name 'PendingUpdates' -Default ([pscustomobject]@{})

    if ($freePercent -lt 10) {
        $recommendations.Add((New-WMRecommendation -Id 'FreeDiskSpace' -Severity 'High' -Title 'Critically low free space on the system drive' -Description "Only $freePercent% free space is available. Delete large unneeded files or move them to external storage." -ActionType 'Guidance'))
    }
    elseif ($freePercent -lt 15) {
        $recommendations.Add((New-WMRecommendation -Id 'FreeDiskSpace' -Severity 'Medium' -Title 'Low free space on the system drive' -Description "Only $freePercent% free space is available. Cleaning up storage may noticeably relieve Windows." -ActionType 'Guidance'))
    }

    if ($tempSize -gt 500MB) {
        $recommendations.Add((New-WMRecommendation -Id 'CleanTempFiles' -Severity 'Low' -Title 'Clean temporary files' -Description 'Temporary files for the signed-in user can be removed after explicit confirmation.' -ActionType 'Remediation'))
    }

    if ($recycleBinSize -gt 500MB) {
        $recommendations.Add((New-WMRecommendation -Id 'CleanRecycleBin' -Severity 'Low' -Title 'Empty Recycle Bin' -Description 'The Recycle Bin uses a large amount of space. It is emptied only after separate confirmation.' -ActionType 'Remediation'))
    }

    if ($startupCount -ge 8) {
        $startupLocation = if ([string](Get-WMFactValue -Facts $Facts -Name 'OperatingSystemVersion' -Default '') -like '6.1*') { 'msconfig and startup folders' } else { 'Task Manager > Startup apps' }
        $recommendations.Add((New-WMRecommendation -Id 'ReviewStartupApps' -Severity 'Medium' -Title 'Review startup apps' -Description "$startupCount startup entries were found. Open $startupLocation and review entries one at a time." -ActionType 'Guidance'))
    }

    if ($restartPending) {
        $recommendations.Add((New-WMRecommendation -Id 'RestartForPendingUpdates' -Severity 'Medium' -Title 'Windows restart pending' -Description 'Windows reports a pending restart. Save your work and restart the PC when convenient.' -ActionType 'Guidance'))
    }

    if ($uptimeDays -ge 14) {
        $recommendations.Add((New-WMRecommendation -Id 'RestartLongRunningSystem' -Severity 'Low' -Title 'PC has been running for a long time without restarting' -Description "The PC has been running for $uptimeDays days. A normal restart can finish stalled background processes and updates." -ActionType 'Guidance'))
    }

    $lifecycleStatus = [string](Get-WMFactValue -Facts $lifecycle -Name 'Status' -Default 'Unknown')
    if ($lifecycleStatus -eq 'Unsupported') {
        $recommendations.Add((New-WMRecommendation -Id 'UpgradeUnsupportedWindows' -Severity 'High' -Title 'Windows version is no longer regularly supported' -Description ([string](Get-WMFactValue -Facts $lifecycle -Name 'Message' -Default 'Consider upgrading to a supported Windows version.')) -ActionType 'Guidance'))
    }
    elseif ($lifecycleStatus -eq 'SpecialLifecycle') {
        $recommendations.Add((New-WMRecommendation -Id 'VerifyWindowsLifecycle' -Severity 'Low' -Title 'Check end of support for this Windows edition' -Description ([string](Get-WMFactValue -Facts $lifecycle -Name 'Message' -Default 'Check the edition and end-of-support date with Microsoft.')) -ActionType 'Guidance'))
    }

    $performanceStatus = [string](Get-WMFactValue -Facts $performance -Name 'Status' -Default 'Unavailable')
    if ($performanceStatus -in @('Available', 'Partial')) {
        $averageCpu = [double](Get-WMFactValue -Facts $performance -Name 'AverageCpuPercent' -Default -1)
        $averageDisk = [double](Get-WMFactValue -Facts $performance -Name 'AverageSystemDiskBusyPercent' -Default -1)
        $averageCommit = [double](Get-WMFactValue -Facts $performance -Name 'AverageCommittedPercent' -Default -1)
        if ($averageCpu -ge 80) {
            $recommendations.Add((New-WMRecommendation -Id 'InvestigateHighCpu' -Severity 'Medium' -Title 'CPU was heavily utilized during sampling' -Description "Average CPU utilization was $averageCpu%. Review the CPU processes listed in the report before ending or removing programs." -ActionType 'Guidance'))
        }
        if ($averageDisk -ge 90) {
            $recommendations.Add((New-WMRecommendation -Id 'InvestigateHighDiskUsage' -Severity 'Medium' -Title 'System drive was heavily utilized during sampling' -Description "Average disk utilization was $averageDisk%. Review I/O processes, drive health, and free space." -ActionType 'Guidance'))
        }
        if ($averageCommit -ge 90) {
            $recommendations.Add((New-WMRecommendation -Id 'InvestigateMemoryPressure' -Severity 'High' -Title 'Memory and commit limit are nearly exhausted' -Description "Average commit utilization was $averageCommit%. Review memory-intensive processes, the paging file, and a possible RAM upgrade." -ActionType 'Guidance'))
        }
    }

    $mediaType = [string](Get-WMFactValue -Facts $systemDriveDevice -Name 'MediaType' -Default 'Unknown')
    if ($mediaType -eq 'HDD') {
        $recommendations.Add((New-WMRecommendation -Id 'ConsiderSsdUpgrade' -Severity 'Medium' -Title 'Windows is running on a mechanical hard drive' -Description 'Moving the system drive to an SSD often helps older PCs more than further software tweaks.' -ActionType 'Guidance'))
    }

    $basicDiskStatus = [string](Get-WMFactValue -Facts $systemDriveDevice -Name 'BasicStatus' -Default 'Unknown')
    $physicalDiskHealth = [string](Get-WMFactValue -Facts $systemDriveDevice -Name 'HealthStatus' -Default 'Unknown')
    if (($basicDiskStatus -notin @('', 'OK', 'Unknown')) -or ($physicalDiskHealth -notin @('', 'Healthy', 'Unknown'))) {
        $recommendations.Add((New-WMRecommendation -Id 'BackUpAndCheckDrive' -Severity 'High' -Title 'System drive reports an unusual condition' -Description "Windows reports drive status '$basicDiskStatus' and health status '$physicalDiskHealth'. Back up important data before further repair attempts." -ActionType 'Guidance'))
    }

    $pageFileStatus = [string](Get-WMFactValue -Facts $pageFile -Name 'ProbeStatus' -Default 'Unavailable')
    $automaticPageFile = Get-WMFactValue -Facts $pageFile -Name 'AutomaticManaged' -Default $null
    if ($pageFileStatus -eq 'Available' -and $automaticPageFile -eq $false) {
        $recommendations.Add((New-WMRecommendation -Id 'ReviewPageFileConfiguration' -Severity 'Medium' -Title 'Paging file is manually managed' -Description 'A disabled or undersized paging file can cause freezes and application errors. Review the setting based on commit utilization.' -ActionType 'Guidance'))
    }

    $antivirusStatus = [string](Get-WMFactValue -Facts $antivirus -Name 'ProbeStatus' -Default 'Unavailable')
    $antivirusProductCount = [int](Get-WMFactValue -Facts $antivirus -Name 'ProductCount' -Default -1)
    if ($antivirusStatus -eq 'Available' -and $antivirusProductCount -eq 0) {
        $recommendations.Add((New-WMRecommendation -Id 'EnableAntivirusProtection' -Severity 'High' -Title 'No registered antivirus protection found' -Description 'Check antivirus protection and run a current scan on a supported Windows version.' -ActionType 'Guidance'))
    }

    $defenderEnabled = Get-WMFactValue -Facts $antivirus -Name 'DefenderEnabled' -Default $null
    $defenderRealtime = Get-WMFactValue -Facts $antivirus -Name 'DefenderRealTimeProtection' -Default $null
    if ($defenderEnabled -eq $true -and $defenderRealtime -eq $false) {
        $recommendations.Add((New-WMRecommendation -Id 'RestoreRealtimeProtection' -Severity 'High' -Title 'Microsoft Defender is enabled, but real-time protection is off' -Description 'Open Windows Security and review why real-time protection is disabled.' -ActionType 'Guidance'))
    }

    $lastHotFixAgeDays = [int](Get-WMFactValue -Facts $updates -Name 'LastHotFixAgeDays' -Default -1)
    if ($lifecycleStatus -ne 'Unsupported' -and $lastHotFixAgeDays -ge 90) {
        $recommendations.Add((New-WMRecommendation -Id 'CheckWindowsUpdates' -Severity 'Medium' -Title 'No installed Windows hotfix detected for a long time' -Description "The last detected hotfix is $lastHotFixAgeDays days old. Open Windows Update and check the current status." -ActionType 'Guidance'))
    }

    $powerPlanStatus = [string](Get-WMFactValue -Facts $powerPlan -Name 'ProbeStatus' -Default 'Unavailable')
    $powerPlanGuid = [string](Get-WMFactValue -Facts $powerPlan -Name 'Guid' -Default '')
    if ($powerPlanStatus -in @('Available', 'Partial') -and $powerPlanGuid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') {
        $recommendations.Add((New-WMRecommendation -Id 'ReviewPowerPlan' -Severity 'Low' -Title 'Power Saver plan is active' -Description 'If the PC is unexpectedly slow while plugged in, review the power mode. A higher-performance mode increases power use and heat.' -ActionType 'Guidance'))
    }

    $largestUserFolder = @(Get-WMFactValue -Facts $userFolderUsage -Name 'Folders' -Default @() | Sort-Object -Property TotalBytes -Descending | Select-Object -First 1)
    if ($largestUserFolder.Count -gt 0 -and [int64]$largestUserFolder[0].TotalBytes -ge 10GB) {
        $recommendations.Add((New-WMRecommendation -Id 'ReviewLargeUserFolders' -Severity 'Low' -Title 'A known user folder uses substantial disk space' -Description "The largest measured folder is $($largestUserFolder[0].Name) at $([math]::Round([double]$largestUserFolder[0].TotalBytes / 1GB, 1)) GB. Review large personal files manually; Windows Makeover will not delete them." -ActionType 'Guidance'))
    }

    $browserCacheBytes = [int64](Get-WMFactValue -Facts $browserCacheUsage -Name 'TotalBytes' -Default 0)
    if ($browserCacheBytes -ge 1GB) {
        $recommendations.Add((New-WMRecommendation -Id 'ReviewBrowserCaches' -Severity 'Low' -Title 'Browser caches use substantial disk space' -Description "Measured browser caches use $([math]::Round([double]$browserCacheBytes / 1GB, 1)) GB. Use each browser's own settings to clear caches if appropriate." -ActionType 'Guidance'))
    }

    $pendingUpdateStatus = [string](Get-WMFactValue -Facts $pendingUpdates -Name 'ProbeStatus' -Default 'Unavailable')
    $pendingUpdateCount = [int](Get-WMFactValue -Facts $pendingUpdates -Name 'PendingCount' -Default 0)
    if ($pendingUpdateStatus -eq 'Available' -and $pendingUpdateCount -gt 0) {
        $securityUpdateCount = [int](Get-WMFactValue -Facts $pendingUpdates -Name 'SecurityUpdateCount' -Default 0)
        $pendingReboot = [bool](Get-WMFactValue -Facts $pendingUpdates -Name 'RebootRequired' -Default $false)
        $recommendations.Add((New-WMRecommendation -Id 'InstallPendingWindowsUpdates' -Severity 'Medium' -Title 'Windows Update reports pending updates' -Description "$pendingUpdateCount pending updates were found, including $securityUpdateCount security or critical updates. Reboot required: $pendingReboot. Review and install them through Windows Update." -ActionType 'Guidance'))
    }

    $overallHealth = 'Healthy'
    if (@($recommendations | Where-Object { $_.Severity -eq 'High' }).Count -gt 0) {
        $overallHealth = 'Critical'
    }
    elseif ($recommendations.Count -gt 0) {
        $overallHealth = 'AttentionRequired'
    }

    [pscustomobject]@{
        SchemaVersion   = $script:WMReportSchemaVersion
        GeneratedAt     = (Get-Date).ToUniversalTime().ToString('o')
        OverallHealth   = $overallHealth
        Facts           = $Facts
        Recommendations = $recommendations.ToArray()
        ManualPlaybook  = @(Get-WMManualPlaybook -Facts $Facts)
    }
}

function Get-WMCleanupPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Path
    )

    $files = @(Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue)
    $totalBytes = [int64]0
    foreach ($file in $files) {
        $totalBytes += [int64]$file.Length
    }

    [pscustomobject]@{
        Path       = (Resolve-Path -LiteralPath $Path).Path
        FileCount  = $files.Count
        TotalBytes = $totalBytes
    }
}

function Get-WMSafeRemediationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Report
    )

    $schemaVersion = [string](Get-WMFactValue -Facts $Report -Name 'SchemaVersion' -Default '')
    if ($schemaVersion -ne $script:WMReportSchemaVersion) {
        throw 'Unsupported diagnostic report schema.'
    }

    $facts = Get-WMFactValue -Facts $Report -Name 'Facts' -Default ([pscustomobject]@{})
    $plan = [System.Collections.Generic.List[object]]::new()
    $tempSize = [int64](Get-WMFactValue -Facts $facts -Name 'TempSizeBytes' -Default 0)
    $recycleBinSize = [int64](Get-WMFactValue -Facts $facts -Name 'RecycleBinSizeBytes' -Default 0)

    if ($tempSize -gt 500MB) {
        $plan.Add([pscustomobject]@{
            Id                   = 'CleanTempFiles'
            Risk                 = 'Low'
            RequiresConfirmation = $true
            Automation           = 'Allowed'
            EstimatedBytes       = $tempSize
            Title                = 'Clean temporary files for the signed-in user'
            Scope                = 'Only the temp folder of the currently signed-in user'
        })
    }

    if ($recycleBinSize -gt 500MB) {
        $plan.Add([pscustomobject]@{
            Id                   = 'CleanRecycleBin'
            Risk                 = 'Low'
            RequiresConfirmation = $true
            Automation           = 'Allowed'
            EstimatedBytes       = $recycleBinSize
            Title                = "Empty the current user's Recycle Bin"
            Scope                = 'Recycle Bin on local drives; files cannot be restored through the Recycle Bin afterward'
        })
    }

    return $plan.ToArray()
}

function Test-WMDiagnosticReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Report,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$UserSid,
        [Parameter(Mandatory)][string]$TempPath,
        [ValidateRange(1, 365)][int]$MaximumAgeDays = 30,
        [ValidateRange(0, 1440)][int]$MaximumFutureMinutes = 5
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $schemaVersion = [string](Get-WMFactValue -Facts $Report -Name 'SchemaVersion' -Default '')
    if ($schemaVersion -ne $script:WMReportSchemaVersion) {
        $reasons.Add('Report schema is unsupported.')
    }

    $facts = Get-WMFactValue -Facts $Report -Name 'Facts' -Default $null
    if ($null -eq $facts) {
        $reasons.Add('Report does not contain diagnostic facts.')
    }
    else {
        $reportedComputerName = [string](Get-WMFactValue -Facts $facts -Name 'ComputerName' -Default '')
        if ([string]::IsNullOrWhiteSpace($reportedComputerName)) {
            $reasons.Add('Report does not contain a computer name.')
        }
        elseif (-not [string]::Equals($reportedComputerName, $ComputerName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $reasons.Add('Report belongs to a different computer.')
        }

        $reportedUserSid = [string](Get-WMFactValue -Facts $facts -Name 'UserSid' -Default '')
        if ([string]::IsNullOrWhiteSpace($reportedUserSid)) {
            $reasons.Add('Report does not contain a user SID.')
        }
        elseif (-not [string]::Equals($reportedUserSid, $UserSid, [System.StringComparison]::OrdinalIgnoreCase)) {
            $reasons.Add('Report belongs to a different Windows user.')
        }

        $reportedTempPath = ConvertTo-WMNormalizedPath -Path ([string](Get-WMFactValue -Facts $facts -Name 'TempPath' -Default ''))
        $currentTempPath = ConvertTo-WMNormalizedPath -Path $TempPath
        if ($null -eq $reportedTempPath) {
            $reasons.Add('Report does not contain a valid temp path.')
        }
        elseif ($null -eq $currentTempPath -or -not [string]::Equals($reportedTempPath, $currentTempPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $reasons.Add('Report belongs to a different temp scope.')
        }
    }

    $generatedAtText = [string](Get-WMFactValue -Facts $Report -Name 'GeneratedAt' -Default '')
    if ([string]::IsNullOrWhiteSpace($generatedAtText)) {
        $reasons.Add('Report does not contain a generation timestamp.')
    }
    else {
        $generatedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($generatedAtText, [ref]$generatedAt)) {
            $reasons.Add('Report generation timestamp is invalid.')
        }
        elseif ($generatedAt.ToUniversalTime() -lt [DateTimeOffset]::UtcNow.AddDays(-$MaximumAgeDays)) {
            $reasons.Add('Report is older than the allowed age.')
        }
        elseif ($generatedAt.ToUniversalTime() -gt [DateTimeOffset]::UtcNow.AddMinutes($MaximumFutureMinutes)) {
            $reasons.Add('Report generation timestamp is in the future.')
        }
    }

    [pscustomobject]@{
        IsValid = ($reasons.Count -eq 0)
        Reasons = $reasons.ToArray()
    }
}

function Get-WMLocalFixedDriveLetters {
    [CmdletBinding()]
    param()

    @(
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
            ForEach-Object { ([string]$_.DeviceID).TrimEnd(':') } |
            Where-Object { $_ -match '^[A-Za-z]$' } |
            Sort-Object -Unique
    )
}

function Invoke-WMSafeRemediation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CleanTempFiles', 'CleanRecycleBin')]
        [string]$Id
    )

    if ($Id -eq 'CleanRecycleBin') {
        try {
            $driveLetters = @(Get-WMLocalFixedDriveLetters)
        }
        catch {
            return [pscustomobject]@{
                ActionId          = $Id
                Status            = 'Failed'
                Removed           = $null
                RemovedKnown      = $false
                RemovedDirectories = 0
                Failed            = 1
                AffectedDrives    = @()
                Error             = "Local fixed drives could not be enumerated: $($_.Exception.Message)"
            }
        }

        if ($driveLetters.Count -eq 0) {
            return [pscustomobject]@{
                ActionId          = $Id
                Status            = 'Failed'
                Removed           = $null
                RemovedKnown      = $false
                RemovedDirectories = 0
                Failed            = 1
                AffectedDrives    = @()
                Error             = 'No local fixed drives were found.'
            }
        }

        $target = "current user's Recycle Bin on local fixed drives: $($driveLetters -join ', ')"
        $operation = 'Empties the Recycle Bin on each selected local fixed drive'
        if (-not $PSCmdlet.ShouldProcess($target, $operation)) {
            return [pscustomobject]@{
                ActionId          = $Id
                Status            = 'WhatIf'
                Removed           = $null
                RemovedKnown      = $false
                RemovedDirectories = 0
                Failed            = 0
                AffectedDrives    = $driveLetters
            }
        }

        $failed = 0
        $errors = [System.Collections.Generic.List[string]]::new()
        foreach ($driveLetter in $driveLetters) {
            try {
                Clear-RecycleBin -DriveLetter $driveLetter -Force -ErrorAction Stop
            }
            catch {
                $failed++
                $errors.Add("$driveLetter`: $($_.Exception.Message)")
            }
        }

        return [pscustomobject]@{
            ActionId          = $Id
            Status            = if ($failed -eq 0) { 'Completed' } elseif ($failed -lt $driveLetters.Count) { 'CompletedWithWarnings' } else { 'Failed' }
            Removed           = $null
            RemovedKnown      = $false
            RemovedDirectories = 0
            Failed            = $failed
            AffectedDrives    = $driveLetters
            Error             = if ($errors.Count -gt 0) { $errors -join ' | ' } else { $null }
        }
    }

    $tempPath = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tempPath)) {
        throw 'The current user temp path is unavailable.'
    }
    if (-not (Test-Path -LiteralPath $tempPath -PathType Container)) {
        throw "Current user temp path not found: $tempPath"
    }

    $preview = Get-WMCleanupPreview -Path $tempPath
    $operation = "Removes $($preview.FileCount) files ($($preview.TotalBytes) bytes) from the temporary folder"
    if (-not $PSCmdlet.ShouldProcess($preview.Path, $operation)) {
        return [pscustomobject]@{
            ActionId = $Id
            Status   = 'WhatIf'
            Removed            = 0
            RemovedKnown       = $true
            RemovedDirectories = 0
            Failed             = 0
            Preview            = $preview
        }
    }

    $removed = 0
    $failed = 0
    $files = @(Get-ChildItem -LiteralPath $tempPath -File -Force -Recurse -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removed++
        }
        catch {
            $failed++
        }
    }

    $removedDirectories = 0
    $directories = @(
        Get-ChildItem -LiteralPath $tempPath -Directory -Force -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending
    )
    foreach ($directory in $directories) {
        try {
            $remainingItem = Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $remainingItem) {
                Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
                $removedDirectories++
            }
        }
        catch {
            $failed++
        }
    }

    [pscustomobject]@{
        ActionId          = $Id
        Status            = if ($failed -eq 0) { 'Completed' } else { 'CompletedWithWarnings' }
        Removed           = $removed
        RemovedKnown      = $true
        RemovedDirectories = $removedDirectories
        Failed            = $failed
        Preview           = $preview
    }
}

function Get-WMSafePercentage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$Numerator,
        [Parameter(Mandatory)][double]$Denominator,
        [ValidateRange(0, 10)][int]$Decimals = 1
    )

    if ($Denominator -le 0) {
        return $null
    }

    return [math]::Round(($Numerator / $Denominator) * 100, $Decimals)
}

function Get-WMProcessExitCode {
    [CmdletBinding()]
    param(
        [object[]]$Results = @(),
        [switch]$ValidationFailed
    )

    if ($ValidationFailed) {
        return 1
    }

    foreach ($result in @($Results)) {
        $status = [string](Get-WMFactValue -Facts $result -Name 'Status' -Default '')
        $failed = [int](Get-WMFactValue -Facts $result -Name 'Failed' -Default 0)
        if ($status -in @('Failed', 'CompletedWithWarnings') -or $failed -gt 0) {
            return 2
        }
    }

    return 0
}

function Get-WMDefaultReportDirectory {
    [CmdletBinding()]
    param(
        [string]$DocumentsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    )

    if ([string]::IsNullOrWhiteSpace($DocumentsPath)) {
        if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            throw 'The current user Documents directory could not be resolved.'
        }
        $DocumentsPath = Join-Path $env:USERPROFILE 'Documents'
    }

    return (Join-Path (Join-Path $DocumentsPath 'WindowsMakeover') 'reports')
}

function Get-WMRunContextMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$IsAdministrator
    )

    if ($IsAdministrator) {
        return 'Administrator (elevated diagnosis)'
    }

    return 'Standard user (partial results are possible for protected probes)'
}

function Save-WMRemediationAuditEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Result,
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $entry = [ordered]@{
        AuditSchemaVersion = '1.0'
        Timestamp          = (Get-Date).ToUniversalTime().ToString('o')
        ReportPath         = $ReportPath
        ActionId           = [string](Get-WMFactValue -Facts $Result -Name 'ActionId' -Default '')
        Status             = [string](Get-WMFactValue -Facts $Result -Name 'Status' -Default 'Unknown')
        Removed            = Get-WMFactValue -Facts $Result -Name 'Removed' -Default $null
        RemovedKnown       = [bool](Get-WMFactValue -Facts $Result -Name 'RemovedKnown' -Default $false)
        RemovedDirectories = [int](Get-WMFactValue -Facts $Result -Name 'RemovedDirectories' -Default 0)
        Failed             = Get-WMFactValue -Facts $Result -Name 'Failed' -Default $null
        AffectedDrives     = @(Get-WMFactValue -Facts $Result -Name 'AffectedDrives' -Default @())
        IsWhatIf           = ([string](Get-WMFactValue -Facts $Result -Name 'Status' -Default '')) -eq 'WhatIf'
        Error              = Get-WMFactValue -Facts $Result -Name 'Error' -Default $null
    }

    ($entry | ConvertTo-Json -Compress -Depth 5) | Add-Content -LiteralPath $Path -Encoding utf8
    return (Resolve-Path -LiteralPath $Path).Path
}

function Save-WMDiagnosticReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
    return (Resolve-Path -LiteralPath $Path).Path
}

Export-ModuleMember -Function Get-WMWindowsLifecycle, New-WMDiagnosis, Get-WMDirectoryUsage, Get-WMKnownUserFolderUsage, Get-WMBrowserCacheUsage, ConvertTo-WMPendingUpdateSummary, Get-WMCleanupPreview, Get-WMSafeRemediationPlan, Test-WMDiagnosticReport, Get-WMLocalFixedDriveLetters, Invoke-WMSafeRemediation, Get-WMSafePercentage, Get-WMProcessExitCode, Get-WMDefaultReportDirectory, Get-WMRunContextMessage, Save-WMRemediationAuditEntry, Save-WMDiagnosticReport
