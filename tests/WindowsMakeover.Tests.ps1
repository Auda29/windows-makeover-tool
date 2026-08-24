BeforeAll {
    $projectRoot = Split-Path -Path $PSScriptRoot -Parent
    $modulePath = Join-Path $projectRoot 'src\WindowsMakeover.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-WMStartupSummary' {
    It 'separates current-user, shared, and other-user entries and exposes duplicates' {
        $items = @(
            [pscustomobject]@{ Name = 'Docker Desktop'; Location = 'Run'; User = 'DOMAIN\Niklas' },
            [pscustomobject]@{ Name = 'Docker Desktop'; Location = 'Run'; User = 'NT AUTHORITY\SYSTEM' },
            [pscustomobject]@{ Name = 'OneDrive'; Location = 'Run'; User = 'DOMAIN\Niklas' },
            [pscustomobject]@{ Name = 'Other App'; Location = 'Run'; User = 'DOMAIN\Other' },
            [pscustomobject]@{ Name = 'Shared App'; Location = 'Run'; User = 'Public' }
        )

        $summary = Get-WMStartupSummary -StartupItems $items -CurrentUserName 'DOMAIN\Niklas'

        $summary.TotalEntryCount | Should -Be 5
        $summary.UniqueNameCount | Should -Be 4
        $summary.DuplicateEntryCount | Should -Be 1
        $summary.CurrentUserEntryCount | Should -Be 2
        $summary.SystemOrSharedEntryCount | Should -Be 2
        $summary.OtherUserEntryCount | Should -Be 1
        $summary.DuplicateNames | Should -HaveCount 1
        $summary.DuplicateNames[0].Name | Should -Be 'Docker Desktop'
        $summary.DuplicateNames[0].Count | Should -Be 2
    }
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

        $report.SchemaVersion | Should -Be '1.5'
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

    It 'bases startup guidance on current-user entries when a startup summary is available' {
        $facts = [pscustomobject]@{
            SystemDriveFreePercent  = 55
            TempSizeBytes           = 10MB
            StartupApplicationCount = 22
            StartupSummary          = [pscustomobject]@{
                TotalEntryCount = 22
                CurrentUserEntryCount = 3
                UniqueNameCount = 20
                DuplicateEntryCount = 2
            }
        }

        $report = New-WMDiagnosis -Facts $facts

        $report.Recommendations.Id | Should -Not -Contain 'ReviewStartupApps'
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

    It 'recommends review for large user folders, browser caches, and pending updates' {
        $facts = [pscustomobject]@{
            SystemDriveFreePercent  = 40
            TempSizeBytes           = 0
            RecycleBinSizeBytes     = 0
            StartupApplicationCount = 0
            UserFolderUsage         = [pscustomobject]@{
                ProbeStatus = 'Available'
                Folders = @([pscustomobject]@{ Name = 'Downloads'; TotalBytes = 15GB })
            }
            BrowserCacheUsage       = [pscustomobject]@{
                ProbeStatus = 'Available'
                TotalBytes = 2GB
                Browsers = @([pscustomobject]@{ Name = 'Google Chrome'; TotalBytes = 2GB })
            }
            PendingUpdates          = [pscustomobject]@{
                ProbeStatus = 'Available'
                PendingCount = 3
                SecurityUpdateCount = 2
                RebootRequired = $true
            }
        }

        $report = New-WMDiagnosis -Facts $facts

        $report.SchemaVersion | Should -Be '1.5'
        $report.Recommendations.Id | Should -Contain 'ReviewLargeUserFolders'
        $report.Recommendations.Id | Should -Contain 'ReviewBrowserCaches'
        $report.Recommendations.Id | Should -Contain 'InstallPendingWindowsUpdates'
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
            SchemaVersion = '1.5'
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
            SchemaVersion = '1.5'
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
            SchemaVersion = '1.5'
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
            SchemaVersion = '1.5'
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
            SchemaVersion = '1.5'
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
            SchemaVersion = '1.5'
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
            SchemaVersion = '1.5'
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

    It 'targets each enumerated local fixed drive and does not use an unknown-count sentinel' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $moduleContent = Get-Content -LiteralPath (Join-Path $projectRoot 'src\WindowsMakeover.psm1') -Raw
        $entryContent = Get-Content -LiteralPath (Join-Path $projectRoot 'windows-makeover.ps1') -Raw

        $moduleContent | Should -Match 'Clear-RecycleBin -DriveLetter \$driveLetter'
        $moduleContent | Should -Not -Match 'Removed\s*=\s*-1'
        $moduleContent | Should -Match 'RemovedKnown\s*=\s*\$false'
        $entryContent | Should -Match '\$driveLetters = @\(Get-WMLocalFixedDriveLetters\)'
        $entryContent | Should -Not -Match 'Get-PSDrive -PSProvider FileSystem'
    }

    It 'removes empty nested temp directories but preserves the temp root' {
        $tempRoot = Join-Path $TestDrive 'isolated-temp'
        $firstFolder = Join-Path $tempRoot 'first'
        $secondFolder = Join-Path $firstFolder 'second'
        New-Item -ItemType Directory -Path $secondFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $secondFolder 'remove-me.tmp') -Value 'test'

        $originalTempPath = $env:TEMP
        try {
            $env:TEMP = $tempRoot
            $result = Invoke-WMSafeRemediation -Id 'CleanTempFiles' -Confirm:$false
        }
        finally {
            $env:TEMP = $originalTempPath
        }

        Test-Path -LiteralPath $tempRoot -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $firstFolder | Should -BeFalse
        $result.Status | Should -Be 'Completed'
        $result.Removed | Should -Be 1
        $result.RemovedDirectories | Should -Be 2
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

Describe 'Get-WMDirectoryUsage' {
    It 'measures files recursively without changing the directory' {
        $root = Join-Path $TestDrive 'usage'
        $nested = Join-Path $root 'nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'one.bin') -Value '123' -NoNewline
        Set-Content -LiteralPath (Join-Path $nested 'two.bin') -Value '12345' -NoNewline

        $usage = Get-WMDirectoryUsage -Path $root -Name 'Test'

        $usage.ProbeStatus | Should -Be 'Available'
        $usage.Coverage | Should -Be 'Complete'
        $usage.TotalBytes | Should -Be 8
        $usage.FileCount | Should -Be 2
        Test-Path -LiteralPath (Join-Path $nested 'two.bin') | Should -BeTrue
    }

    It 'returns unavailable for a missing directory instead of throwing' {
        $usage = Get-WMDirectoryUsage -Path (Join-Path $TestDrive 'missing') -Name 'Missing'

        $usage.ProbeStatus | Should -Be 'Unavailable'
        $usage.TotalBytes | Should -Be 0
        $usage.FileCount | Should -Be 0
    }

    It 'returns a partial result when the shared scan deadline has elapsed' {
        $root = Join-Path $TestDrive 'timed'
        New-Item -ItemType Directory -Path $root | Out-Null

        $usage = Get-WMDirectoryUsage -Path $root -Name 'Timed' -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(-1))

        $usage.ProbeStatus | Should -Be 'Partial'
        $usage.Coverage | Should -Be 'Partial'
        $usage.TimedOut | Should -BeTrue
    }

    It 'labels measurements that intentionally skip reparse targets' -Skip:(-not $IsLinux) {
        $root = Join-Path $TestDrive 'reparse-root'
        $target = Join-Path $TestDrive 'target'
        New-Item -ItemType Directory -Path $root,$target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'outside.bin') -Value '12345' -NoNewline
        New-Item -ItemType SymbolicLink -Path (Join-Path $root 'linked') -Target $target | Out-Null

        $usage = Get-WMDirectoryUsage -Path $root -Name 'Reparse'

        $usage.ProbeStatus | Should -Be 'Available'
        $usage.Coverage | Should -Be 'CompleteWithoutReparseTargets'
        $usage.SkippedReparsePoints | Should -Be 1
        $usage.TotalBytes | Should -Be 0
    }
}

Describe 'Get-WMKnownUserFolderUsage' {
    It 'sorts known folders by size and limits the returned list' {
        $downloads = Join-Path $TestDrive 'Downloads'
        $documents = Join-Path $TestDrive 'Documents'
        $pictures = Join-Path $TestDrive 'Pictures'
        New-Item -ItemType Directory -Path $downloads,$documents,$pictures -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $downloads 'large.bin') -Value ('x' * 30) -NoNewline
        Set-Content -LiteralPath (Join-Path $documents 'medium.bin') -Value ('x' * 20) -NoNewline
        Set-Content -LiteralPath (Join-Path $pictures 'small.bin') -Value ('x' * 10) -NoNewline

        $result = Get-WMKnownUserFolderUsage -Folders ([ordered]@{
            Downloads = $downloads
            Documents = $documents
            Pictures = $pictures
        }) -Top 2

        $result.ProbeStatus | Should -Be 'Available'
        $result.Coverage | Should -Be 'Complete'
        $result.Folders | Should -HaveCount 2
        $result.Folders[0].Name | Should -Be 'Downloads'
        $result.Folders[0].TotalBytes | Should -Be 30
        $result.Folders[1].Name | Should -Be 'Documents'
    }

    It 'marks aggregate coverage partial when a requested known folder is unavailable' {
        $documents = Join-Path $TestDrive 'Documents-present'
        New-Item -ItemType Directory -Path $documents -Force | Out-Null

        $result = Get-WMKnownUserFolderUsage -Folders ([ordered]@{
            Documents = $documents
            Downloads = (Join-Path $TestDrive 'Downloads-missing')
        })

        $result.ProbeStatus | Should -Be 'Partial'
        $result.Coverage | Should -Be 'Partial'
        $result.UnavailableCount | Should -Be 1
    }
}

Describe 'Get-WMBrowserCacheUsage' {
    It 'measures Chrome, Edge, and Firefox cache profiles separately' {
        $local = Join-Path $TestDrive 'Local'
        $chromeCache = Join-Path $local 'Google\Chrome\User Data\Default\Cache'
        $edgeCache = Join-Path $local 'Microsoft\Edge\User Data\Profile 1\Code Cache'
        $firefoxCache = Join-Path $local 'Mozilla\Firefox\Profiles\abc.default\cache2'
        New-Item -ItemType Directory -Path $chromeCache,$edgeCache,$firefoxCache -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $chromeCache 'chrome.bin') -Value ('x' * 11) -NoNewline
        Set-Content -LiteralPath (Join-Path $edgeCache 'edge.bin') -Value ('x' * 13) -NoNewline
        Set-Content -LiteralPath (Join-Path $firefoxCache 'firefox.bin') -Value ('x' * 17) -NoNewline

        $result = Get-WMBrowserCacheUsage -LocalAppDataPath $local

        $result.ProbeStatus | Should -Be 'Available'
        ($result.Browsers | Where-Object Name -eq 'Google Chrome').TotalBytes | Should -Be 11
        ($result.Browsers | Where-Object Name -eq 'Microsoft Edge').TotalBytes | Should -Be 13
        ($result.Browsers | Where-Object Name -eq 'Mozilla Firefox').TotalBytes | Should -Be 17
        $result.TotalBytes | Should -Be 41
    }
}

Describe 'ConvertTo-WMPendingUpdateSummary' {
    It 'summarizes pending, security, and restart-requiring updates' {
        $updates = @(
            [pscustomobject]@{ Title = 'Security fix'; RebootRequired = $true; CategoryNames = @('Security Updates') },
            [pscustomobject]@{ Title = 'Driver update'; RebootRequired = $false; CategoryNames = @('Drivers') }
        )

        $summary = ConvertTo-WMPendingUpdateSummary -Updates $updates

        $summary.ProbeStatus | Should -Be 'Available'
        $summary.PendingCount | Should -Be 2
        $summary.SecurityUpdateCount | Should -Be 1
        $summary.RebootRequiredCount | Should -Be 1
        $summary.RebootRequired | Should -BeTrue
        $summary.Titles | Should -Contain 'Security fix'
    }
}

Describe 'Get-WMProcessExitCode' {
    It 'returns one for report validation failures' {
        Get-WMProcessExitCode -ValidationFailed -Results @() | Should -Be 1
    }

    It 'returns two when an action fails or completes with warnings' {
        Get-WMProcessExitCode -Results @([pscustomobject]@{ Status = 'Failed'; Failed = 1 }) | Should -Be 2
        Get-WMProcessExitCode -Results @([pscustomobject]@{ Status = 'CompletedWithWarnings'; Failed = 1 }) | Should -Be 2
    }

    It 'returns zero when completed actions have no failures' {
        Get-WMProcessExitCode -Results @(
            [pscustomobject]@{ Status = 'Completed'; Failed = 0 },
            [pscustomobject]@{ Status = 'WhatIf'; Failed = 0 }
        ) | Should -Be 0
    }
}

Describe 'Get-WMDefaultReportDirectory' {
    It 'places reports under the user Documents directory' {
        $directory = Get-WMDefaultReportDirectory -DocumentsPath $TestDrive

        $directory | Should -Be (Join-Path (Join-Path $TestDrive 'WindowsMakeover') 'reports')
    }
}

Describe 'Get-WMRunContextMessage' {
    It 'clearly identifies a partial standard-user diagnosis' {
        Get-WMRunContextMessage -IsAdministrator:$false | Should -Match 'Standard user.*partial'
    }

    It 'identifies an elevated diagnosis' {
        Get-WMRunContextMessage -IsAdministrator:$true | Should -Match 'Administrator'
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
            SchemaVersion = '1.5'
            OverallHealth = 'Healthy'
            Recommendations = @()
        }
        $path = Join-Path $TestDrive 'diagnosis.json'

        Save-WMDiagnosticReport -Report $report -Path $path

        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $saved.SchemaVersion | Should -Be '1.5'
        $saved.OverallHealth | Should -Be 'Healthy'
    }
}

Describe 'New-WMReleaseAssets' {
    It 'creates a standalone script, a complete ZIP, and checksums' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $builderPath = Join-Path $projectRoot 'build\New-WMReleaseAssets.ps1'
        $outputPath = Join-Path $TestDrive 'release'

        $assets = & $builderPath -Version '0.3.1-dev' -OutputDirectory $outputPath

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
        $checksums | Should -Match 'windows-makeover-0\.3\.1-dev\.ps1'
        $checksums | Should -Match 'windows-makeover-0\.3\.1-dev\.zip'
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

    It 'uses English for all user-facing console labels' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $scriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'windows-makeover.ps1') -Raw

        $scriptContent | Should -Match 'Overall status:'
        $scriptContent | Should -Match 'I/O per second'
        $scriptContent | Should -Match 'Diagnostic report saved:'
        $scriptContent | Should -Match '\$reportDirectory = Get-WMDefaultReportDirectory'
        $scriptContent | Should -Match 'Run context: \$\(Get-WMRunContextMessage'
        $scriptContent | Should -Not -Match 'Gesamtstatus|Diagnosebericht|pro Sekunde'
    }

    It 'prints precise startup counts and uses one controlled table writer' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $scriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'windows-makeover.ps1') -Raw

        $scriptContent | Should -Match 'Startup entries returned by Windows:'
        $scriptContent | Should -Match 'current user:'
        $scriptContent | Should -Match 'unique names:'
        $scriptContent | Should -Match 'function Write-WMTable'
        ([regex]::Matches($scriptContent, '\|\s*Format-Table')).Count | Should -Be 1
    }

    It 'uses explicit process exit codes for validation and action errors' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $scriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'windows-makeover.ps1') -Raw

        $scriptContent | Should -Match 'exit 1'
        $scriptContent | Should -Match 'exit \$remediationExitCode'
    }

    It 'collects storage diagnostics and bounds the Windows Update probe with a timeout' {
        $projectRoot = Split-Path -Path $PSScriptRoot -Parent
        $scriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'windows-makeover.ps1') -Raw

        $scriptContent | Should -Match 'UserFolderUsage\s*=\s*\$userFolderUsage'
        $scriptContent | Should -Match 'BrowserCacheUsage\s*=\s*\$browserCacheUsage'
        $scriptContent | Should -Match 'PendingUpdates\s*=\s*Get-WMPendingWindowsUpdates'
        $scriptContent | Should -Match 'Wait-Job -Job \$job -Timeout \$TimeoutSeconds'
        $scriptContent | Should -Match '\$storageDeadlineUtc = \[DateTimeOffset\]::UtcNow\.AddSeconds\(\$StorageTimeoutSeconds\)'
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
