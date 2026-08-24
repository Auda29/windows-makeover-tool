BeforeAll {
    $projectRoot = Split-Path -Path $PSScriptRoot -Parent
    $modulePath = Join-Path $projectRoot 'src\WindowsMakeover.psm1'
    Import-Module $modulePath -Force
}

Describe 'New-WMDiagnosis' {
    It 'recommends cleanup for critically low system-drive free space' {
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

    It 'reports many startup apps and a pending restart' {
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

    It 'detects typical CPU, disk, memory, and security bottlenecks' {
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

    It 'keeps riskier repair steps in the manual playbook' {
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
    It 'marks Windows 7 and regular Windows 10 as no longer regularly supported' {
        (Get-WMWindowsLifecycle -Version '6.1.7601' -Caption 'Microsoft Windows 7 Professional').Status | Should -Be 'Unsupported'
        (Get-WMWindowsLifecycle -Version '10.0.19045' -Caption 'Microsoft Windows 10 Pro' -EditionId 'Professional').Status | Should -Be 'Unsupported'
    }

    It 'handles LTSC separately and Windows 11 by version' {
        (Get-WMWindowsLifecycle -Version '10.0.19044' -Caption 'Microsoft Windows 10 Enterprise LTSC' -EditionId 'EnterpriseS').Status | Should -Be 'SpecialLifecycle'
        (Get-WMWindowsLifecycle -Version '10.0.26100' -Caption 'Microsoft Windows 11 Pro' -EditionId 'Professional').Status | Should -Be 'VersionSpecific'
    }
}

Describe 'Get-WMSafeRemediationPlan' {
    It 'marks temp cleanup as an individually confirmed action with a size estimate' {
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

    It 'offers the Recycle Bin only as a confirmed low-risk action' {
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

    It 'rejects unknown report schemas' {
        $report = [pscustomobject]@{ SchemaVersion = '9.9'; Facts = [pscustomobject]@{}; Recommendations = @() }

        { Get-WMSafeRemediationPlan -Report $report } | Should -Throw '*Unsupported diagnostic report schema*'
    }

    It 'ignores injected action IDs below the size threshold' {
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
    It 'accepts a recent report from the same PC' {
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

    It 'rejects an old or foreign report' {
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

    It 'rejects missing user binding and a future timestamp' {
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

    It 'rejects reports from another Windows user or temp scope' {
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
    It 'counts only files and sums their size without changing anything' {
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
    It 'does not delete temporary files under WhatIf' {
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

    It 'does not offer an arbitrary deletion path' {
        (Get-Command Invoke-WMSafeRemediation).Parameters.Keys | Should -Not -Contain 'TempPath'
    }
}

Describe 'Get-WMSafePercentage' {
    It 'returns the rounded percentage for a positive denominator' {
        Get-WMSafePercentage -Numerator 25 -Denominator 200 | Should -Be 12.5
    }

    It 'returns no misleading value for a zero or negative denominator' {
        Get-WMSafePercentage -Numerator 25 -Denominator 0 | Should -BeNullOrEmpty
        Get-WMSafePercentage -Numerator 25 -Denominator (-1) | Should -BeNullOrEmpty
    }
}

Describe 'Save-WMRemediationAuditEntry' {
    It 'writes a standalone JSONL line with the cleanup result' {
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
    It 'saves a machine-readable diagnostic report as JSON' {
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
    It 'creates a standalone script, a complete ZIP, and checksums' {
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
    It 'exists as a syntactically valid PowerShell script' {
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
    It 'stores all PowerShell files as UTF-8 with BOM' {
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
