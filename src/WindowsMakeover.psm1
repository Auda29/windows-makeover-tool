Set-StrictMode -Version Latest

$script:WMReportSchemaVersion = '1.1'

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
        $recommendations.Add((New-WMRecommendation -Id 'ReviewStartupApps' -Severity 'Medium' -Title 'Autostart-Programme prüfen' -Description "$startupCount Autostart-Einträge wurden gefunden. Nicht benötigte Einträge sollten in Windows Einstellungen > Apps > Autostart geprüft werden." -ActionType 'Guidance'))
    }

    if ($restartPending) {
        $recommendations.Add((New-WMRecommendation -Id 'RestartForPendingUpdates' -Severity 'Medium' -Title 'Windows-Neustart ausstehend' -Description 'Windows signalisiert einen ausstehenden Neustart. Speichern Sie Ihre Arbeit und starten Sie den PC bei Gelegenheit neu.' -ActionType 'Guidance'))
    }

    if ($uptimeDays -ge 14) {
        $recommendations.Add((New-WMRecommendation -Id 'RestartLongRunningSystem' -Severity 'Low' -Title 'PC läuft seit langer Zeit ohne Neustart' -Description "Der PC läuft seit $uptimeDays Tagen. Ein normaler Neustart kann hängende Hintergrundprozesse und Updates abschließen." -ActionType 'Guidance'))
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

    if ($Report.SchemaVersion -notin @('1.0', $script:WMReportSchemaVersion)) {
        throw 'Unsupported diagnostic report schema.'
    }

    $facts = Get-WMFactValue -Facts $Report -Name 'Facts' -Default ([pscustomobject]@{})
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($recommendation in @($Report.Recommendations)) {
        switch ($recommendation.Id) {
            'CleanTempFiles' {
                $plan.Add([pscustomobject]@{
                    Id                   = 'CleanTempFiles'
                    Risk                 = 'Low'
                    RequiresConfirmation = $true
                    Automation           = 'Allowed'
                    EstimatedBytes       = [int64](Get-WMFactValue -Facts $facts -Name 'TempSizeBytes' -Default 0)
                    Title                = 'Temporäre Dateien des angemeldeten Benutzers bereinigen'
                    Scope                = 'Nur der Temp-Ordner des aktuell angemeldeten Benutzers'
                })
            }
            'CleanRecycleBin' {
                $plan.Add([pscustomobject]@{
                    Id                   = 'CleanRecycleBin'
                    Risk                 = 'Low'
                    RequiresConfirmation = $true
                    Automation           = 'Allowed'
                    EstimatedBytes       = [int64](Get-WMFactValue -Facts $facts -Name 'RecycleBinSizeBytes' -Default 0)
                    Title                = 'Papierkorb des aktuellen Benutzers leeren'
                    Scope                = 'Papierkorb auf lokalen Laufwerken; Dateien können danach nicht über den Papierkorb wiederhergestellt werden'
                })
            }
        }
    }

    return $plan.ToArray()
}

function Test-WMDiagnosticReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Report,
        [Parameter(Mandatory)][string]$ComputerName,
        [ValidateRange(1, 365)][int]$MaximumAgeDays = 30
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Report.SchemaVersion -notin @('1.0', $script:WMReportSchemaVersion)) {
        $reasons.Add('Report schema is unsupported.')
    }
    if ($null -eq $Report.Facts) {
        $reasons.Add('Report does not contain diagnostic facts.')
    }
    elseif ($Report.Facts.PSObject.Properties.Name -contains 'ComputerName') {
        if ($Report.Facts.ComputerName -and $Report.Facts.ComputerName -ne $ComputerName) {
            $reasons.Add('Report belongs to a different computer.')
        }
    }

    if ($Report.PSObject.Properties.Name -notcontains 'GeneratedAt' -or [string]::IsNullOrWhiteSpace([string]$Report.GeneratedAt)) {
        $reasons.Add('Report does not contain a generation timestamp.')
    }
    else {
        $generatedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$Report.GeneratedAt, [ref]$generatedAt)) {
            $reasons.Add('Report generation timestamp is invalid.')
        }
        elseif ($generatedAt.ToUniversalTime() -lt [DateTimeOffset]::UtcNow.AddDays(-$MaximumAgeDays)) {
            $reasons.Add('Report is older than the allowed age.')
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
        [string]$Id,

        [string]$TempPath
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

    if ([string]::IsNullOrWhiteSpace($TempPath)) {
        throw 'TempPath is required for CleanTempFiles.'
    }
    if (-not (Test-Path -LiteralPath $TempPath -PathType Container)) {
        throw "TempPath not found: $TempPath"
    }

    $preview = Get-WMCleanupPreview -Path $TempPath
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
    $files = @(Get-ChildItem -LiteralPath $TempPath -File -Force -Recurse -ErrorAction SilentlyContinue)
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

Export-ModuleMember -Function New-WMDiagnosis, Get-WMCleanupPreview, Get-WMSafeRemediationPlan, Test-WMDiagnosticReport, Invoke-WMSafeRemediation, Save-WMDiagnosticReport
