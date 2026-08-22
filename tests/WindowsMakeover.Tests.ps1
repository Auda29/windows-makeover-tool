BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'WindowsMakeover.psm1'
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

        $report.SchemaVersion | Should -Be '1.1'
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
}

Describe 'Get-WMSafeRemediationPlan' {
    It 'markiert die Temp-Bereinigung als einzeln zu bestätigende Aktion mit Größenangabe' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.1'
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
            SchemaVersion = '1.1'
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
}

Describe 'Test-WMDiagnosticReport' {
    It 'akzeptiert einen aktuellen Bericht des gleichen PCs' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.1'
            GeneratedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Facts = [pscustomobject]@{ ComputerName = 'FAMILY-PC' }
        }

        $validation = Test-WMDiagnosticReport -Report $report -ComputerName 'FAMILY-PC'

        $validation.IsValid | Should -BeTrue
    }

    It 'lehnt einen alten oder fremden Bericht ab' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.1'
            GeneratedAt = [DateTimeOffset]::UtcNow.AddDays(-31).ToString('o')
            Facts = [pscustomobject]@{ ComputerName = 'OTHER-PC' }
        }

        $validation = Test-WMDiagnosticReport -Report $report -ComputerName 'FAMILY-PC'

        $validation.IsValid | Should -BeFalse
        $validation.Reasons | Should -Contain 'Report belongs to a different computer.'
        $validation.Reasons | Should -Contain 'Report is older than the allowed age.'
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

        $result = Invoke-WMSafeRemediation -Id 'CleanTempFiles' -TempPath $TestDrive -WhatIf

        Test-Path -LiteralPath $temporaryFile | Should -BeTrue
        $result.Status | Should -Be 'WhatIf'
        $result.ActionId | Should -Be 'CleanTempFiles'
    }
}

Describe 'Save-WMDiagnosticReport' {
    It 'speichert einen maschinenlesbaren Diagnosebericht als JSON' {
        $report = [pscustomobject]@{
            SchemaVersion = '1.0'
            OverallHealth = 'Healthy'
            Recommendations = @()
        }
        $path = Join-Path $TestDrive 'diagnosis.json'

        Save-WMDiagnosticReport -Report $report -Path $path

        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $saved.SchemaVersion | Should -Be '1.0'
        $saved.OverallHealth | Should -Be 'Healthy'
    }
}

Describe 'windows-makeover entry point' {
    It 'ist als fehlerfreies PowerShell-Skript vorhanden' {
        $scriptPath = Join-Path $PSScriptRoot '..' 'windows-makeover.ps1'
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
