BeforeAll {
    $projectRoot = Split-Path -Path $PSScriptRoot -Parent
    $modulePath = Join-Path $projectRoot 'src\WindowsMakeover.psm1'
    Import-Module $modulePath -Force
}

Describe 'New-WMDiagnosis' {
    It 'empfiehlt Speicherbereinigung bei kritisch wenig freiem Systemlaufwerk' {
        $facts = [pscustomobject]@{
            SystemDriveFreePercent = 8
            TempSizeBytes          = 2GB
            StartupApplicationCount = 3
            UpdatesPending         = $false
        }

        $report = New-WMDiagnosis -Facts $facts

        $report.SchemaVersion | Should -Be '1.3'
        $report.OverallHealth | Should -Be 'Critical'
        $report.Recommendations.Id | Should -Contain 'CleanTempFiles'
        $report.Recommendations.Id | Should -Contain 'FreeDiskSpace'
    }

    It 'weist auf viele Autostart-Programme und einen ausstehenden Neustart hin' {
        $facts = [pscustomobject]@{
            SystemDriveFreePercent  = 55
            TempSizeBytes           = 10MB
            StartupApplicationCount = 12
            UpdatesPending          = $true
        }

        $report = New-WMDiagnosis -Facts $facts

        $report.Recommendations.Id | Should -Contain 'ReviewStartupApps'
        $report.Recommendations.Id | Should -Contain 'RestartForPendingUpdates'
    }

    It 'erkennt typische CPU-, Datenträger-, Speicher- und Sicherheitsbremsen' {
        $facts = [pscustomobject]@{
            OperatingSystemVersion  = '10.0.26100'
            SystemDriveFreePercent  = 55
            TempSizeBytes           = 10MB
            StartupApplicationCount = 2
            Lifecycle               = [pscustomobject]@{ Status = 'VersionSpecific' }
            PerformanceSample       = [pscustomobject]@{
                Status                       = 'Available'
                AverageCpuPercent            = 85
                AverageSystemDiskBusyPercent = 95
                AverageCommittedPercent      = 92
            }
            SystemDriveDevice       = [pscustomobject]@{
                MediaType    = 'HDD'
                BasicStatus  = 'OK'
                HealthStatus = 'Healthy'
            }
            PageFile                 = [pscustomobject]@{ ProbeStatus = 'Available'; AutomaticManaged = $false }
            Antivirus                = [pscustomobject]@{ ProbeStatus = 'Available'; ProductCount = 0 }
            Updates                  = [pscustomobject]@{ LastHotFixAgeDays = 120 }
            ActivePowerPlan          = [pscustomobject]@{ ProbeStatus = 'Available'; Guid = 'a1841308-3541-4fab-bc81-f71556f20b4a' }
        }

        $report = New-WMDiagnosis -Facts $facts

        $report.Recommendations.Id | Should -Contain 'InvestigateHighCpu'
        $report.Recommendations.Id | Should -Contain 'InvestigateHighDiskUsage'
        $report.Recommendations.Id | Should -Contain 'InvestigateMemoryPressure'
        $report.Recommendations.Id | Should -Contain 'ConsiderSsdUpgrade'
        $report.Recommendations.Id | Should -Contain 'ReviewPageFileConfiguration'
        $report.Recommendations.Id | Should -Contain 'EnableAntivirusProtection'
        $report.Recommendations.Id | Should -Contain 'CheckWindowsUpdates'
        $report.Recommendations.Id | Should -Contain 'ReviewPowerPlan'
    }

    It 'hält riskantere Reparaturschritte im manuellen Leitfaden' {
        $facts = [pscustomobject]@{
            OperatingSystemVersion = '6.1.7601'
            Lifecycle = [pscustomobject]@{ Status = 'Unsupported' }
        }

        $report = New-WMDiagnosis -Facts $facts

        @($report.ManualPlaybook | Where-Object { $_.Automatic }) | Should -BeNullOrEmpty
        $report.ManualPlaybook.Id | Should -Contain 'RepairSystemFiles'
        $report.ManualPlaybook.Id | Should -Contain 'CheckFileSystem'
        $report.ManualPlaybook.Id | Should -Contain 'CleanBootTest'
        $report.ManualPlaybook.Id | Should -Contain 'ReviewVisualEffects'
        $report.ManualPlaybook.Id | Should -Contain 'Recovery'
        ($report.ManualPlaybook | Where-Object Id -eq 'RepairSystemFiles').Steps -join ' ' | Should -Match 'sfc /scannow'
    }
}

Describe 'Get-WMWindowsLifecycle' {
    It 'markiert Windows 7 und normales Windows 10 als nicht mehr regulär unterstützt' {
        (Get-WMWindowsLifecycle -Version '6.1.7601' -Caption 'Microsoft Windows 7 Professional').Status | Should -Be 'Unsupported'
        (Get-WMWindowsLifecycle -Version '10.0.19045' -Caption 'Microsoft Windows 10 Pro' -EditionId 'Professional').Status | Should -Be 'Unsupported'
    }

    It 'behandelt LTSC getrennt und Windows 11 versionsabhängig' {
        (Get-WMWindowsLifecycle -Version '10.0.19044' -Caption 'Microsoft Windows 10 Enterprise LTSC' -EditionId 'EnterpriseS').Status | Should -Be 'SpecialLifecycle'
        (Get-WMWindowsLifecycle -Version '10.0.26100' -Caption 'Microsoft Windows 11 Pro' -EditionId 'Professional').Status | Should -Be 'VersionSpecific'
    }
}

Describe 'Get-WMSafeRemediationPlan' {
    It 'markiert die Temp-Bereinigung als einzeln zu bestätigende Aktion mit Größenangabe' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            Facts = [pscustomobject]@{ TempSizeBytes = 2GB; RecycleBinSizeBytes = 0 }
            Recommendations = @(
                [pscustomobject]@{ Id = 'CleanTempFiles' }
            )
        }

        $plan = Get-WMSafeRemediationPlan -Report $report

        $plan | Should -HaveCount 1
        $plan[0].Id | Should -Be 'CleanTempFiles'
        $plan[0].Risk | Should -Be 'Low'
        $plan[0].RequiresConfirmation | Should -BeTrue
        $plan[0].Automation | Should -Be 'Allowed'
        $plan[0].EstimatedBytes | Should -Be 2GB
    }

    It 'bietet den Papierkorb nur als bestätigte, risikoarme Maßnahme an' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            Facts = [pscustomobject]@{ TempSizeBytes = 0; RecycleBinSizeBytes = 3GB }
            Recommendations = @(
                [pscustomobject]@{ Id = 'CleanRecycleBin' }
            )
        }

        $plan = Get-WMSafeRemediationPlan -Report $report

        $plan | Should -HaveCount 1
        $plan[0].Id | Should -Be 'CleanRecycleBin'
        $plan[0].RequiresConfirmation | Should -BeTrue
        $plan[0].EstimatedBytes | Should -Be 3GB
    }

    It 'lehnt unbekannte Berichtsformate ab' {
        $report = [pscustomobject]@{ SchemaVersion = '9.9'; Facts = [pscustomobject]@{}; Recommendations = @() }

        { Get-WMSafeRemediationPlan -Report $report } | Should -Throw '*Unsupported diagnostic report schema*'
    }

    It 'ignoriert eingeschleuste Aktions-IDs unterhalb der Größenschwelle' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            Facts = [pscustomobject]@{ TempSizeBytes = 0; RecycleBinSizeBytes = 0 }
            Recommendations = @(
                [pscustomobject]@{ Id = 'CleanRecycleBin' }
            )
        }

        Get-WMSafeRemediationPlan -Report $report | Should -BeNullOrEmpty
    }
}

Describe 'Test-WMDiagnosticReport' {
    It 'akzeptiert einen aktuellen Bericht des gleichen PCs' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            GeneratedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Facts = [pscustomobject]@{
                ComputerName = 'FAMILY-PC'
                UserSid = 'S-1-5-21-1000'
                TempPath = 'C:\Users\Family\AppData\Local\Temp'
            }
        }

        $validation = Test-WMDiagnosticReport -Report $report -ComputerName 'FAMILY-PC' -UserSid 'S-1-5-21-1000' -TempPath 'C:\Users\Family\AppData\Local\Temp'

        $validation.IsValid | Should -BeTrue
    }

    It 'lehnt einen alten oder fremden Bericht ab' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            GeneratedAt = [DateTimeOffset]::UtcNow.AddDays(-31).ToString('o')
            Facts = [pscustomobject]@{
                ComputerName = 'OTHER-PC'
                UserSid = 'S-1-5-21-1000'
                TempPath = 'C:\Users\Family\AppData\Local\Temp'
            }
        }

        $validation = Test-WMDiagnosticReport -Report $report -ComputerName 'FAMILY-PC' -UserSid 'S-1-5-21-1000' -TempPath 'C:\Users\Family\AppData\Local\Temp'

        $validation.IsValid | Should -BeFalse
        $validation.Reasons | Should -Contain 'Report belongs to a different computer.'
        $validation.Reasons | Should -Contain 'Report is older than the allowed age.'
    }

    It 'lehnt fehlende Benutzerbindung und einen zukünftigen Zeitstempel ab' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            GeneratedAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
            Facts = [pscustomobject]@{
                TempSizeBytes = 2GB
            }
        }

        $validation = Test-WMDiagnosticReport -Report $report -ComputerName 'FAMILY-PC' -UserSid 'S-1-5-21-1000' -TempPath 'C:\Users\Family\AppData\Local\Temp'

        $validation.IsValid | Should -BeFalse
        $validation.Reasons | Should -Contain 'Report does not contain a computer name.'
        $validation.Reasons | Should -Contain 'Report does not contain a user SID.'
        $validation.Reasons | Should -Contain 'Report does not contain a valid temp path.'
        $validation.Reasons | Should -Contain 'Report generation timestamp is in the future.'
    }

    It 'lehnt Berichte eines anderen Windows-Benutzers oder Temp-Bereichs ab' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            GeneratedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Facts = [pscustomobject]@{
                ComputerName = 'FAMILY-PC'
                UserSid = 'S-1-5-21-OTHER'
                TempPath = 'C:\Users\Other\AppData\Local\Temp'
            }
        }

        $validation = Test-WMDiagnosticReport -Report $report -ComputerName 'FAMILY-PC' -UserSid 'S-1-5-21-1000' -TempPath 'C:\Users\Family\AppData\Local\Temp'

        $validation.IsValid | Should -BeFalse
        $validation.Reasons | Should -Contain 'Report belongs to a different Windows user.'
        $validation.Reasons | Should -Contain 'Report belongs to a different temp scope.'
    }
}

Describe 'Get-WMCleanupPreview' {
    It 'zählt nur Dateien und summiert deren Größe ohne etwas zu verändern' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'one.tmp') -Value 'abc' -NoNewline
        $folder = Join-Path $TestDrive 'nested'
        New-Item -ItemType Directory -Path $folder | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'two.tmp') -Value '12345' -NoNewline

        $preview = Get-WMCleanupPreview -Path $TestDrive

        $preview.FileCount | Should -Be 2
        $preview.TotalBytes | Should -Be 8
        (Test-Path -LiteralPath (Join-Path $folder 'two.tmp')) | Should -BeTrue
    }
}

Describe 'Invoke-WMSafeRemediation' {
    It 'löscht bei WhatIf keine temporären Dateien' {
        $temporaryFile = Join-Path $TestDrive 'keep-me.tmp'
        Set-Content -LiteralPath $temporaryFile -Value 'test data'

        $originalTempPath = $env:TEMP
        try {
            $env:TEMP = $TestDrive
            $result = Invoke-WMSafeRemediation -Id 'CleanTempFiles' -WhatIf
        }
        finally {
            $env:TEMP = $originalTempPath
        }

        Test-Path -LiteralPath $temporaryFile | Should -BeTrue
        $result.Status | Should -Be 'WhatIf'
        $result.ActionId | Should -Be 'CleanTempFiles'
    }

    It 'bietet keinen frei wählbaren Löschpfad an' {
        (Get-Command Invoke-WMSafeRemediation).Parameters.Keys | Should -Not -Contain 'TempPath'
    }
}

Describe 'Get-WMSafePercentage' {
    It 'liefert bei einem positiven Nenner den gerundeten Prozentwert' {
        Get-WMSafePercentage -Numerator 25 -Denominator 200 | Should -Be 12.5
    }

    It 'liefert bei null oder negativem Nenner keinen irreführenden Wert' {
        Get-WMSafePercentage -Numerator 25 -Denominator 0 | Should -BeNullOrEmpty
        Get-WMSafePercentage -Numerator 25 -Denominator (-1) | Should -BeNullOrEmpty
    }
}

Describe 'Save-WMRemediationAuditEntry' {
    It 'schreibt eine eigenständige JSONL-Zeile mit dem Ergebnis der Bereinigung' {
        $path = Join-Path $TestDrive 'remediation-audit.jsonl'
        $result = [pscustomobject]@{
            ActionId = 'CleanTempFiles'
            Status   = 'Completed'
            Removed  = 12
            Failed   = 1
        }

        Save-WMRemediationAuditEntry -Result $result -ReportPath 'C:\Reports\diagnosis.json' -Path $path

        $entry = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        $entry.AuditSchemaVersion | Should -Be '1.0'
        $entry.ActionId | Should -Be 'CleanTempFiles'
        $entry.Status | Should -Be 'Completed'
        $entry.Removed | Should -Be 12
        $entry.Failed | Should -Be 1
        $entry.ReportPath | Should -Be 'C:\Reports\diagnosis.json'
        $entry.IsWhatIf | Should -BeFalse
    }
}

Describe 'Save-WMDiagnosticReport' {
    It 'speichert einen maschinenlesbaren Diagnosebericht als JSON' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.3'
            OverallHealth = 'Healthy'
            Recommendations = @()
        }
        $path = Join-Path $TestDrive 'diagnosis.json'

        Save-WMDiagnosticReport -Report $report -Path $path

        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $saved.SchemaVersion | Should -Be '1.3'
        $saved.OverallHealth | Should -Be 'Healthy'
    }
}

Describe 'New-WMReleaseAssets' {
    It 'erstellt ein eigenständiges Skript, ein vollständiges ZIP und Prüfsummen' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $builderPath = Join-Path $projectRoot 'build\New-WMReleaseAssets.ps1'
        $outputPath = Join-Path $TestDrive 'release'

        $assets = & $builderPath -Version '0.2.0-beta' -OutputDirectory $outputPath

        Test-Path -LiteralPath $assets.StandaloneScript -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $assets.ZipPackage -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $assets.Checksums -PathType Leaf | Should -BeTrue

        $standaloneContent = Get-Content -LiteralPath $assets.StandaloneScript -Raw
        $standaloneContent | Should -Match 'function New-WMDiagnosis'
        $standaloneContent | Should -Not -Match 'Import-Module \$modulePath'
        $standaloneContent | Should -Not -Match '(?m)^Export-ModuleMember'

        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $assets.StandaloneScript,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        $errors | Should -BeNullOrEmpty

        $expandedPath = Join-Path $TestDrive 'expanded'
        Expand-Archive -LiteralPath $assets.ZipPackage -DestinationPath $expandedPath
        Test-Path -LiteralPath (Join-Path $expandedPath 'windows-makeover.ps1') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $expandedPath 'src\WindowsMakeover.psm1') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $expandedPath 'README.md') -PathType Leaf | Should -BeTrue

        $checksums = Get-Content -LiteralPath $assets.Checksums -Raw
        $checksums | Should -Match 'windows-makeover-0\.2\.0-beta\.ps1'
        $checksums | Should -Match 'windows-makeover-0\.2\.0-beta\.zip'
    }
}

Describe 'windows-makeover entry point' {
    It 'ist als fehlerfreies PowerShell-Skript vorhanden' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $scriptPath = Join-Path $projectRoot 'windows-makeover.ps1'
        Test-Path -LiteralPath $scriptPath | Should -BeTrue

        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null

        $errors | Should -BeNullOrEmpty
    }
}

Describe 'PowerShell source encoding' {
    It 'speichert alle PowerShell-Dateien als UTF-8 mit BOM' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $sourceFiles = @(
            (Join-Path $projectRoot 'windows-makeover.ps1'),
            (Join-Path $projectRoot 'src\WindowsMakeover.psm1'),
            (Join-Path $PSScriptRoot 'WindowsMakeover.Tests.ps1'),
            (Join-Path $projectRoot 'build\New-WMReleaseAssets.ps1')
        )

        foreach ($sourceFile in $sourceFiles) {
            $bytes = [System.IO.File]::ReadAllBytes($sourceFile)
            $bytes.Length | Should -BeGreaterThan 3
            $bytes[0] | Should -Be 239
            $bytes[1] | Should -Be 187
            $bytes[2] | Should -Be 191
        }
    }
}
