$ErrorActionPreference = "Stop"
$exportScript = Join-Path $PSScriptRoot "../Export-PrivateDnsARecords.ps1"
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$null = New-Item -Path $testDirectory -ItemType Directory

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    $command = $Arguments -join " "
    $global:ExportTestCalls.Add($command)
    $global:LASTEXITCODE = 0

    if (($global:ExportTestScenario -eq "authentication-failure" -and $command -like "account show *") -or
        ($global:ExportTestScenario -eq "enumeration-failure" -and $command -like "account list *") -or
        ($global:ExportTestScenario -in @("subscription-failure", "all-failed") -and $command -like "*zone list*--subscription inaccessible *") -or
        ($global:ExportTestScenario -eq "zone-failure" -and $command -like "*--zone-name broken.test *")) {
        Write-Error "ERROR: (SubscriptionNotFound) Requested subscription could not be found." -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    if ($command -like "account show *") {
        '{"id":"healthy"}'
    }
    elseif ($command -like "account list *") {
        switch ($global:ExportTestScenario) {
            "no-enabled" { '[{"id":"disabled","state":"Disabled"}]' }
            "all-failed" { '[{"id":"inaccessible","name":"Unavailable","state":"Enabled"}]' }
            "subscription-failure" {
                '[{"id":"inaccessible","name":"Unavailable","state":"Enabled"},{"id":"healthy","name":"Healthy","state":"Enabled"}]'
            }
            default { '[{"id":"healthy","name":"Healthy","state":"Enabled"}]' }
        }
    }
    elseif ($command -like "*zone list*") {
        switch ($global:ExportTestScenario) {
            "empty-zones" { '[]' }
            "invalid-json" { 'not JSON' }
            "empty-json" { return }
            "zone-failure" {
                '[{"name":"broken.test","resourceGroup":"rg"},{"name":"example.test","resourceGroup":"rg"}]'
            }
            default { '[{"name":"example.test","resourceGroup":"rg"}]' }
        }
    }
    elseif ($command -like "*record-set a list*") {
        if ($global:ExportTestScenario -eq "empty-records") {
            '[]'
        }
        else {
            if ($global:ExportTestScenario -eq "cli-warning") {
                Write-Error "WARNING: CLI diagnostic on stderr." -ErrorAction Continue
            }
            '[{"name":"@","ttl":300,"id":"apex","aRecords":[{"ipv4Address":"10.0.0.1"}]},{"name":"www","ttl":60,"id":"www","aRecords":[{"ipv4Address":"10.0.0.2"},{"ipv4Address":"10.0.0.3"}]}]'
        }
    }
    else {
        throw "Unexpected mock command: $command"
    }
}

try {
    foreach ($scenario in @(
        "complete", "subscription-failure", "zone-failure", "all-failed",
        "empty-zones", "empty-records", "authentication-failure",
        "enumeration-failure", "no-enabled", "invalid-json", "empty-json", "cli-warning"
    )) {
        $global:ExportTestScenario = $scenario
        $global:ExportTestCalls = [System.Collections.Generic.List[string]]::new()
        $outputPath = Join-Path $testDirectory "$scenario.csv"
        $failure = $null
        $messages = [System.Collections.Generic.List[object]]::new()
        $PSNativeCommandUseErrorActionPreference = $true

        try {
            & $exportScript -OutputPath $outputPath 3>&1 |
                ForEach-Object { $messages.Add($_) }
        }
        catch {
            $failure = $_.Exception.Message
        }

        $fatal = $scenario -in @("authentication-failure", "enumeration-failure", "no-enabled")
        $partial = $scenario -in @("subscription-failure", "zone-failure", "all-failed", "invalid-json", "empty-json")

        if ($fatal) {
            Assert-True ($null -ne $failure) "$scenario should stop with an error."
            Assert-True (-not (Test-Path $outputPath)) "$scenario should not write a CSV."
            if ($scenario -ne "no-enabled") {
                Assert-True ($failure -match "SubscriptionNotFound") "$scenario lost the original Azure error."
            }
        }
        else {
            Assert-True (Test-Path $outputPath) "$scenario did not persist a CSV. Error: $failure"
            $records = @(Import-Csv -Path $outputPath)
            $empty = $scenario -in @("all-failed", "empty-zones", "empty-records", "invalid-json", "empty-json")
            $expectedCount = if ($empty) { 0 } else { 3 }
            Assert-True ($records.Count -eq $expectedCount) "$scenario has an incorrect record count."
            if ($empty) {
                $header = Get-Content -Path $outputPath -TotalCount 1
                Assert-True ($header -eq "SubscriptionId,SubscriptionName,ResourceGroup,Zone,FQDN,IPv4Address,TTL,RecordSetId") "$scenario has an incorrect empty CSV header."
            }
            else {
                Assert-True ($records[0].FQDN -eq "example.test") "$scenario changed apex FQDN behavior."
                Assert-True ($records[1].FQDN -eq "www.example.test") "$scenario changed FQDN behavior."
                Assert-True ($records[2].IPv4Address -eq "10.0.0.3") "$scenario lost a multi-address record."
                Assert-True ($records[0].TTL -eq "300") "$scenario changed TTL."
                Assert-True ($records[0].SubscriptionId -eq "healthy") "$scenario exported an incorrect subscription."
                Assert-True (($records[0].PSObject.Properties.Name -join ",") -eq "SubscriptionId,SubscriptionName,ResourceGroup,Zone,FQDN,IPv4Address,TTL,RecordSetId") "$scenario changed CSV columns."
            }

            if ($partial) {
                Assert-True ($failure -match "INCOMPLETE export") "$scenario should report incomplete results after exporting."
                Assert-True ($messages.Count -gt 0) "$scenario should emit diagnostic warnings."
            }
            else {
                Assert-True ($null -eq $failure) "$scenario unexpectedly failed: $failure"
            }
        }

        if ($scenario -eq "subscription-failure") {
            Assert-True (($messages -join "`n") -match "(?s)Skipped subscription Unavailable \(inaccessible\).*SubscriptionNotFound") "Missing subscription failure details."
        }
        if ($scenario -eq "zone-failure") {
            Assert-True (($messages -join "`n") -match "(?s)Skipped zone broken.test.*SubscriptionNotFound") "Missing zone failure details."
        }
        if ($scenario -eq "empty-zones") {
            Assert-True (-not ($global:ExportTestCalls | Where-Object { $_ -like "*record-set*" })) "Empty zones triggered a record query."
        }
        if ($scenario -eq "cli-warning") {
            Assert-True (($messages -join "`n") -match "CLI diagnostic") "Successful CLI diagnostics were swallowed."
        }
        Write-Host "PASS: $scenario"
    }
}
finally {
    Remove-Item -Path $testDirectory -Recurse -Force
    Remove-Variable -Name ExportTestScenario, ExportTestCalls -Scope Global
}
