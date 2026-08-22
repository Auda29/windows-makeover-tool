Set-StrictMode -Version Latest

$script:WMReportSchemaVersion = '1.3'

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
            Message        = 'Diese Windows-Ausgabe hat einen eigenen Lebenszyklus. Prüfen Sie Edition und Supportende bei Microsoft.'
        }
    }

    if ($Version.Major -eq 6 -and $Version.Minor -eq 1) {
        return [pscustomobject]@{
            ProductFamily  = 'Windows7'
            Status         = 'Unsupported'
            SupportEndDate = '2020-01-14'
            Message        = 'Der reguläre Support für Windows 7 ist beendet. Ein Upgrade oder Geräteaustausch ist sicherer als weitere Optimierung.'
        }
    }

    if ($Version.Major -eq 6 -and $Version.Minor -eq 2) {
        return [pscustomobject]@{
            ProductFamily  = 'Windows8'
            Status         = 'Unsupported'
            SupportEndDate = '2016-01-12'
            Message        = 'Der reguläre Support für Windows 8 ist beendet. Ein Upgrade oder Geräteaustausch ist sicherer als weitere Optimierung.'
        }
    }

    if ($Version.Major -eq 6 -and $Version.Minor -eq 3) {
        return [pscustomobject]@{
            ProductFamily  = 'Windows81'
            Status         = 'Unsupported'
            SupportEndDate = '2023-01-10'
            Message        = 'Der reguläre Support für Windows 8.1 ist beendet. Ein Upgrade oder Geräteaustausch ist sicherer als weitere Optimierung.'
        }
    }

    if ($Version.Major -eq 10 -and $Caption -match '(?i)Windows 10') {
        return [pscustomobject]@{
            ProductFamily  = 'Windows10'
            Status         = 'Unsupported'
            SupportEndDate = '2025-10-14'
            Message        = 'Der reguläre Support für Windows 10 ist beendet. Prüfen Sie Windows 11, ESU oder einen Geräteaustausch.'
        }
    }

    if ($Version.Major -eq 10 -and $Caption -match '(?i)Windows 11') {
        return [pscustomobject]@{
            ProductFamily  = 'Windows11'
            Status         = 'VersionSpecific'
            SupportEndDate = $null
            Message        = 'Der Support hängt von Edition und Windows-11-Version ab. Installieren Sie eine aktuell unterstützte Version.'
        }
    }

    [pscustomobject]@{
        ProductFamily  = 'Unknown'
        Status         = 'Unknown'
        SupportEndDate = $null
        Message        = 'Der Windows-Supportstatus konnte nicht eindeutig bestimmt werden.'
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
        'msconfig und die Autostart-Ordner öffnen. Einträge einzeln prüfen und dokumentieren.'
    }
    else {
        'Task-Manager > Autostart öffnen. Einträge mit hoher Auswirkung und unbekanntem Zweck einzeln prüfen.'
    }

    $updateStep = if ($lifecycleStatus -eq 'Unsupported') {
        'Upgrade, ESU-Sonderfall oder Geräteaustausch prüfen. Einzelne Tuning-Schritte ersetzen keine Sicherheitsupdates.'
    }
    else {
        'Windows Update öffnen, verfügbare Updates prüfen und einen verlangten Neustart abschließen.'
    }

    $repairSteps = if ($version.Major -eq 6 -and $version.Minor -eq 1) {
        @(
            'Nur bei Windows-Fehlern oder beschädigten Funktionen eine administrative Eingabeaufforderung öffnen.',
            'sfc /scannow ausführen.',
            'Bei Windows-Update-Komponentenfehlern das passende System Update Readiness Tool von Microsoft verwenden.'
        )
    }

    else {
        @(
            'Nur bei Windows-Fehlern oder beschädigten Funktionen eine administrative Eingabeaufforderung öffnen.',
            'DISM.exe /Online /Cleanup-Image /RestoreHealth ausführen.',
            'Danach sfc /scannow ausführen.'
        )
    }

    $powerStep = if ($version.Major -eq 6 -and $version.Minor -le 3) {
        'Systemsteuerung > Hardware und Sound > Energieoptionen öffnen. Bei unerwartet niedriger Leistung im Netzbetrieb den Plan Ausbalanciert prüfen.'
    }
    else {
        'Einstellungen > System > Netzbetrieb und Akku öffnen. Bei unerwartet niedriger Leistung im Netzbetrieb den Energiemodus Ausbalanciert prüfen.'
    }

    @(
        [pscustomobject]@{
            Id            = 'ReviewStartupApps'
            When          = 'Langer Systemstart oder viele Hintergrundprogramme'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @($startupStep)
        },
        [pscustomobject]@{
            Id            = 'UpdateOrUpgradeWindows'
            When          = 'Veraltete Windows-Version, fehlende Updates oder ausstehender Neustart'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @($updateStep)
        },
        [pscustomobject]@{
            Id            = 'RunMalwareScan'
            When          = 'Unbekannte Prozesse, hohe Dauerlast oder fehlender aktueller Scan'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @('Den registrierten Virenschutz öffnen und einen Schnellscan starten. Bei einem Fund den Herstelleranweisungen folgen.')
        },
        [pscustomobject]@{
            Id            = 'OptimizeSystemDrive'
            When          = 'Mechanische Festplatte oder ausgelassene Windows-Laufwerksoptimierung'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('Die Windows-Laufwerksoptimierung öffnen. Windows soll selbst zwischen HDD-Defragmentierung und SSD-TRIM wählen.')
        },
        [pscustomobject]@{
            Id            = 'ReviewPowerPlan'
            When          = 'Der PC ist besonders im Netzbetrieb langsam oder verwendet den Energiesparplan'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @($powerStep, 'Auf einem Notebook erhöht ein leistungsstärkerer Modus Stromverbrauch, Wärme und Lüfterlautstärke. Die vorherige Einstellung notieren.')
        },
        [pscustomobject]@{
            Id            = 'ReviewVisualEffects'
            When          = 'Fensteranimationen und die Oberfläche ruckeln auf älterer Hardware'
            Automatic     = $false
            RequiresAdmin = $false
            Steps         = @('SystemPropertiesPerformance.exe öffnen und einzelne visuelle Effekte testweise reduzieren. Die vorherige Auswahl dokumentieren.')
        },
        [pscustomobject]@{
            Id            = 'CleanBootTest'
            When          = 'Die Last lässt sich keinem einzelnen Prozess zuordnen oder tritt nach der Anmeldung auf'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('msconfig öffnen und zuerst alle Microsoft-Dienste ausblenden.', 'Drittanbieter-Dienste und Autostarts nur für einen Test deaktivieren, neu starten und anschließend schrittweise wieder aktivieren.', 'Nach dem Test den normalen Systemstart wiederherstellen.')
        },
        [pscustomobject]@{
            Id            = 'RepairSystemFiles'
            When          = 'Windows-Funktionen, Updates oder Systemdateien sind beschädigt'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = $repairSteps
        },
        [pscustomobject]@{
            Id            = 'CheckFileSystem'
            When          = 'Dateisystemfehler, I/O-Fehler oder ein gesetztes Dirty-Bit wurden festgestellt'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('Wichtige Daten zuerst sichern.', 'CHKDSK nur nach einem konkreten Fehlerbefund und mit passender Option ausführen.')
        },
        [pscustomobject]@{
            Id            = 'Recovery'
            When          = 'Die Installation bleibt nach gezielter Diagnose und Reparatur unzuverlässig'
            Automatic     = $false
            RequiresAdmin = $true
            Steps         = @('Backup und BitLocker-Wiederherstellungsschlüssel prüfen.', 'Danach Systemwiederherstellung, Zurücksetzen oder Neuinstallation beaufsichtigt auswählen.')
        }
    )
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

    if ($freePercent -lt 10) {
        $recommendations.Add((New-WMRecommendation -Id 'FreeDiskSpace' -Severity 'High' -Title 'Kritisch wenig freier Speicher auf dem Systemlaufwerk' -Description "Nur $freePercent% Speicherplatz sind frei. Löschen Sie große, nicht benötigte Dateien oder verschieben Sie sie auf ein externes Laufwerk." -ActionType 'Guidance'))
    }
    elseif ($freePercent -lt 15) {
        $recommendations.Add((New-WMRecommendation -Id 'FreeDiskSpace' -Severity 'Medium' -Title 'Wenig freier Speicher auf dem Systemlaufwerk' -Description "Nur $freePercent% Speicherplatz sind frei. Eine Speicherbereinigung kann Windows spürbar entlasten." -ActionType 'Guidance'))
    }

    if ($tempSize -gt 500MB) {
        $recommendations.Add((New-WMRecommendation -Id 'CleanTempFiles' -Severity 'Low' -Title 'Temporäre Dateien bereinigen' -Description 'Temporäre Dateien des angemeldeten Benutzers können nach ausdrücklicher Bestätigung entfernt werden.' -ActionType 'Remediation'))
    }

    if ($recycleBinSize -gt 500MB) {
        $recommendations.Add((New-WMRecommendation -Id 'CleanRecycleBin' -Severity 'Low' -Title 'Papierkorb leeren' -Description 'Der Papierkorb enthält viel Speicher. Das Leeren wird erst nach einer separaten Bestätigung ausgeführt.' -ActionType 'Remediation'))
    }

    if ($startupCount -ge 8) {
        $startupLocation = if ([string](Get-WMFactValue -Facts $Facts -Name 'OperatingSystemVersion' -Default '') -like '6.1*') { 'msconfig und Autostart-Ordner' } else { 'Task-Manager > Autostart' }
        $recommendations.Add((New-WMRecommendation -Id 'ReviewStartupApps' -Severity 'Medium' -Title 'Autostart-Programme prüfen' -Description "$startupCount Autostart-Einträge wurden gefunden. Öffnen Sie $startupLocation und prüfen Sie Einträge einzeln." -ActionType 'Guidance'))
    }

    if ($restartPending) {
        $recommendations.Add((New-WMRecommendation -Id 'RestartForPendingUpdates' -Severity 'Medium' -Title 'Windows-Neustart ausstehend' -Description 'Windows signalisiert einen ausstehenden Neustart. Speichern Sie Ihre Arbeit und starten Sie den PC bei Gelegenheit neu.' -ActionType 'Guidance'))
    }

    if ($uptimeDays -ge 14) {
        $recommendations.Add((New-WMRecommendation -Id 'RestartLongRunningSystem' -Severity 'Low' -Title 'PC läuft seit langer Zeit ohne Neustart' -Description "Der PC läuft seit $uptimeDays Tagen. Ein normaler Neustart kann hängende Hintergrundprozesse und Updates abschließen." -ActionType 'Guidance'))
    }

    $lifecycleStatus = [string](Get-WMFactValue -Facts $lifecycle -Name 'Status' -Default 'Unknown')
    if ($lifecycleStatus -eq 'Unsupported') {
        $recommendations.Add((New-WMRecommendation -Id 'UpgradeUnsupportedWindows' -Severity 'High' -Title 'Windows-Version wird regulär nicht mehr unterstützt' -Description ([string](Get-WMFactValue -Facts $lifecycle -Name 'Message' -Default 'Prüfen Sie ein Upgrade auf eine unterstützte Windows-Version.')) -ActionType 'Guidance'))
    }
    elseif ($lifecycleStatus -eq 'SpecialLifecycle') {
        $recommendations.Add((New-WMRecommendation -Id 'VerifyWindowsLifecycle' -Severity 'Low' -Title 'Supportende dieser Windows-Ausgabe prüfen' -Description ([string](Get-WMFactValue -Facts $lifecycle -Name 'Message' -Default 'Prüfen Sie Edition und Supportende bei Microsoft.')) -ActionType 'Guidance'))
    }

    $performanceStatus = [string](Get-WMFactValue -Facts $performance -Name 'Status' -Default 'Unavailable')
    if ($performanceStatus -in @('Available', 'Partial')) {
        $averageCpu = [double](Get-WMFactValue -Facts $performance -Name 'AverageCpuPercent' -Default -1)
        $averageDisk = [double](Get-WMFactValue -Facts $performance -Name 'AverageSystemDiskBusyPercent' -Default -1)
        $averageCommit = [double](Get-WMFactValue -Facts $performance -Name 'AverageCommittedPercent' -Default -1)
        if ($averageCpu -ge 80) {
            $recommendations.Add((New-WMRecommendation -Id 'InvestigateHighCpu' -Severity 'Medium' -Title 'CPU während der Messung stark ausgelastet' -Description "Die mittlere CPU-Auslastung lag bei $averageCpu%. Prüfen Sie die im Bericht aufgeführten CPU-Prozesse, bevor Sie Programme beenden oder entfernen." -ActionType 'Guidance'))
        }
        if ($averageDisk -ge 90) {
            $recommendations.Add((New-WMRecommendation -Id 'InvestigateHighDiskUsage' -Severity 'Medium' -Title 'Systemlaufwerk während der Messung stark ausgelastet' -Description "Die mittlere Datenträgerauslastung lag bei $averageDisk%. Prüfen Sie I/O-Prozesse, Laufwerkszustand und freien Speicher." -ActionType 'Guidance'))
        }
        if ($averageCommit -ge 90) {
            $recommendations.Add((New-WMRecommendation -Id 'InvestigateMemoryPressure' -Severity 'High' -Title 'Arbeitsspeicher und Commit-Limit nahezu ausgeschöpft' -Description "Die mittlere Commit-Auslastung lag bei $averageCommit%. Prüfen Sie speicherintensive Prozesse, Auslagerungsdatei und eine mögliche RAM-Aufrüstung." -ActionType 'Guidance'))
        }
    }

    $mediaType = [string](Get-WMFactValue -Facts $systemDriveDevice -Name 'MediaType' -Default 'Unknown')
    if ($mediaType -eq 'HDD') {
        $recommendations.Add((New-WMRecommendation -Id 'ConsiderSsdUpgrade' -Severity 'Medium' -Title 'Windows läuft auf einer mechanischen Festplatte' -Description 'Ein Wechsel des Systemlaufwerks auf eine SSD bringt bei älteren PCs häufig mehr als weitere Software-Tweaks.' -ActionType 'Guidance'))
    }

    $basicDiskStatus = [string](Get-WMFactValue -Facts $systemDriveDevice -Name 'BasicStatus' -Default 'Unknown')
    $physicalDiskHealth = [string](Get-WMFactValue -Facts $systemDriveDevice -Name 'HealthStatus' -Default 'Unknown')
    if (($basicDiskStatus -notin @('', 'OK', 'Unknown')) -or ($physicalDiskHealth -notin @('', 'Healthy', 'Unknown'))) {
        $recommendations.Add((New-WMRecommendation -Id 'BackUpAndCheckDrive' -Severity 'High' -Title 'Systemlaufwerk meldet einen auffälligen Zustand' -Description "Windows meldet Laufwerksstatus '$basicDiskStatus' und Gesundheitsstatus '$physicalDiskHealth'. Sichern Sie wichtige Daten vor weiteren Reparaturversuchen." -ActionType 'Guidance'))
    }

    $pageFileStatus = [string](Get-WMFactValue -Facts $pageFile -Name 'ProbeStatus' -Default 'Unavailable')
    $automaticPageFile = Get-WMFactValue -Facts $pageFile -Name 'AutomaticManaged' -Default $null
    if ($pageFileStatus -eq 'Available' -and $automaticPageFile -eq $false) {
        $recommendations.Add((New-WMRecommendation -Id 'ReviewPageFileConfiguration' -Severity 'Medium' -Title 'Auslagerungsdatei wird manuell verwaltet' -Description 'Eine pauschal deaktivierte oder zu kleine Auslagerungsdatei kann Einfrieren und Programmfehler verursachen. Prüfen Sie die Einstellung anhand der Commit-Auslastung.' -ActionType 'Guidance'))
    }

    $antivirusStatus = [string](Get-WMFactValue -Facts $antivirus -Name 'ProbeStatus' -Default 'Unavailable')
    $antivirusProductCount = [int](Get-WMFactValue -Facts $antivirus -Name 'ProductCount' -Default -1)
    if ($antivirusStatus -eq 'Available' -and $antivirusProductCount -eq 0) {
        $recommendations.Add((New-WMRecommendation -Id 'EnableAntivirusProtection' -Severity 'High' -Title 'Kein registrierter Virenschutz gefunden' -Description 'Prüfen Sie den Virenschutz und führen Sie auf einem unterstützten Windows einen aktuellen Scan aus.' -ActionType 'Guidance'))
    }

    $defenderEnabled = Get-WMFactValue -Facts $antivirus -Name 'DefenderEnabled' -Default $null
    $defenderRealtime = Get-WMFactValue -Facts $antivirus -Name 'DefenderRealTimeProtection' -Default $null
    if ($defenderEnabled -eq $true -and $defenderRealtime -eq $false) {
        $recommendations.Add((New-WMRecommendation -Id 'RestoreRealtimeProtection' -Severity 'High' -Title 'Microsoft Defender ist aktiv, Echtzeitschutz aber ausgeschaltet' -Description 'Öffnen Sie Windows-Sicherheit und prüfen Sie, warum der Echtzeitschutz deaktiviert ist.' -ActionType 'Guidance'))
    }

    $lastHotFixAgeDays = [int](Get-WMFactValue -Facts $updates -Name 'LastHotFixAgeDays' -Default -1)
    if ($lifecycleStatus -ne 'Unsupported' -and $lastHotFixAgeDays -ge 90) {
        $recommendations.Add((New-WMRecommendation -Id 'CheckWindowsUpdates' -Severity 'Medium' -Title 'Seit längerer Zeit kein installierter Windows-Hotfix erkannt' -Description "Der letzte erkannte Hotfix ist $lastHotFixAgeDays Tage alt. Öffnen Sie Windows Update und prüfen Sie den aktuellen Stand." -ActionType 'Guidance'))
    }

    $powerPlanStatus = [string](Get-WMFactValue -Facts $powerPlan -Name 'ProbeStatus' -Default 'Unavailable')
    $powerPlanGuid = [string](Get-WMFactValue -Facts $powerPlan -Name 'Guid' -Default '')
    if ($powerPlanStatus -in @('Available', 'Partial') -and $powerPlanGuid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') {
        $recommendations.Add((New-WMRecommendation -Id 'ReviewPowerPlan' -Severity 'Low' -Title 'Energiesparplan ist aktiv' -Description 'Wenn der PC auch im Netzbetrieb unerwartet langsam ist, prüfen Sie den Energiemodus. Ein leistungsstärkerer Modus erhöht Stromverbrauch und Wärme.' -ActionType 'Guidance'))
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
            Title                = 'Temporäre Dateien des angemeldeten Benutzers bereinigen'
            Scope                = 'Nur der Temp-Ordner des aktuell angemeldeten Benutzers'
        })
    }

    if ($recycleBinSize -gt 500MB) {
        $plan.Add([pscustomobject]@{
            Id                   = 'CleanRecycleBin'
            Risk                 = 'Low'
            RequiresConfirmation = $true
            Automation           = 'Allowed'
            EstimatedBytes       = $recycleBinSize
            Title                = 'Papierkorb des aktuellen Benutzers leeren'
            Scope                = 'Papierkorb auf lokalen Laufwerken; Dateien können danach nicht über den Papierkorb wiederhergestellt werden'
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

function Invoke-WMSafeRemediation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CleanTempFiles', 'CleanRecycleBin')]
        [string]$Id
    )

    if ($Id -eq 'CleanRecycleBin') {
        $operation = 'Leert den Papierkorb auf lokalen Laufwerken'
        if (-not $PSCmdlet.ShouldProcess('Papierkorb des aktuellen Benutzers', $operation)) {
            return [pscustomobject]@{ ActionId = $Id; Status = 'WhatIf'; Removed = 0; Failed = 0 }
        }
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            return [pscustomobject]@{ ActionId = $Id; Status = 'Completed'; Removed = -1; Failed = 0 }
        }
        catch {
            return [pscustomobject]@{ ActionId = $Id; Status = 'Failed'; Removed = 0; Failed = 1; Error = $_.Exception.Message }
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
    $operation = "Entfernt $($preview.FileCount) Dateien ($($preview.TotalBytes) Bytes) aus dem temporären Ordner"
    if (-not $PSCmdlet.ShouldProcess($preview.Path, $operation)) {
        return [pscustomobject]@{
            ActionId = $Id
            Status   = 'WhatIf'
            Removed  = 0
            Failed   = 0
            Preview   = $preview
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

    [pscustomobject]@{
        ActionId = $Id
        Status   = if ($failed -eq 0) { 'Completed' } else { 'CompletedWithWarnings' }
        Removed  = $removed
        Failed   = $failed
        Preview  = $preview
    }
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

Export-ModuleMember -Function Get-WMWindowsLifecycle, New-WMDiagnosis, Get-WMCleanupPreview, Get-WMSafeRemediationPlan, Test-WMDiagnosticReport, Invoke-WMSafeRemediation, Save-WMDiagnosticReport
