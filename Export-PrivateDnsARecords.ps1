# Export-PrivateDnsARecords.ps1
param(
    [string]$OutputPath = ".\private-dns-a-records.csv"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed or is not in PATH."
}

function Invoke-AzureCliJson {
    param(
        [string[]]$Arguments
    )

    # Handle native exit codes ourselves, including in Cloud Shell PowerShell.
    $PSNativeCommandUseErrorActionPreference = $false
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & az @Arguments --output json 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stderr = Get-Content -Path $stderrPath -Raw

        if ($exitCode -ne 0) {
            $detail = if ([string]::IsNullOrWhiteSpace($stderr)) {
                "Azure CLI exited with code $exitCode. Output: $($stdout -join [Environment]::NewLine)"
            }
            else {
                $stderr.Trim()
            }
            return [pscustomobject]@{ Success = $false; Data = $null; Detail = $detail }
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Warning $stderr.Trim()
        }

        $json = $stdout -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($json)) {
            return [pscustomobject]@{
                Success = $false
                Data    = $null
                Detail  = "Azure CLI returned no JSON output."
            }
        }

        try {
            $data = @(ConvertFrom-Json -InputObject $json -ErrorAction Stop)
        }
        catch {
            return [pscustomobject]@{
                Success = $false
                Data    = $null
                Detail  = "Azure CLI returned invalid JSON: $($_.Exception.Message)"
            }
        }

        return [pscustomobject]@{ Success = $true; Data = $data; Detail = $null }
    }
    finally {
        Remove-Item -Path $stderrPath -Force
    }
}

$accountResult = Invoke-AzureCliJson -Arguments @("account", "show")
if (-not $accountResult.Success) {
    throw "Could not read the Azure CLI account. Run 'az login' first. $($accountResult.Detail)"
}

$subscriptionsResult = Invoke-AzureCliJson -Arguments @("account", "list", "--all")
if (-not $subscriptionsResult.Success) {
    throw "Could not list Azure subscriptions. $($subscriptionsResult.Detail)"
}

$rows = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
$subscriptions = @($subscriptionsResult.Data | Where-Object { $_.state -eq "Enabled" })

if ($subscriptions.Count -eq 0) {
    throw "No enabled Azure subscriptions were found. Verify your account and tenant with 'az login'."
}

foreach ($subscription in $subscriptions) {
    Write-Host "Processing subscription: $($subscription.name) ($($subscription.id))"

    $zonesResult = Invoke-AzureCliJson -Arguments @(
        "network", "private-dns", "zone", "list",
        "--subscription", $subscription.id
    )

    if (-not $zonesResult.Success) {
        $failure = "Skipped subscription $($subscription.name) ($($subscription.id)): $($zonesResult.Detail)"
        $failures.Add($failure)
        Write-Warning $failure
        continue
    }

    $zones = @($zonesResult.Data)

    foreach ($zone in $zones) {
        $recordSetsResult = Invoke-AzureCliJson -Arguments @(
            "network", "private-dns", "record-set", "a", "list",
            "--subscription", $subscription.id,
            "--resource-group", $zone.resourceGroup,
            "--zone-name", $zone.name
        )

        if (-not $recordSetsResult.Success) {
            $failure = "Skipped zone $($zone.name) in resource group $($zone.resourceGroup), subscription $($subscription.id): $($recordSetsResult.Detail)"
            $failures.Add($failure)
            Write-Warning $failure
            continue
        }

        $recordSets = @($recordSetsResult.Data)

        foreach ($recordSet in $recordSets) {
            $fqdn = if ($recordSet.name -eq "@") {
                $zone.name
            }
            else {
                "$($recordSet.name).$($zone.name)"
            }

            foreach ($record in @($recordSet.aRecords)) {
                if ($null -eq $record -or -not $record.ipv4Address) {
                    continue
                }

                $rows.Add([pscustomobject]@{
                    SubscriptionId   = $subscription.id
                    SubscriptionName = $subscription.name
                    ResourceGroup    = $zone.resourceGroup
                    Zone             = $zone.name
                    FQDN             = $fqdn
                    IPv4Address      = $record.ipv4Address
                    TTL              = $recordSet.ttl
                    RecordSetId      = $recordSet.id
                })
            }
        }
    }
}

# Export-Csv creates no file for an empty collection, so write the header explicitly.
if ($rows.Count -gt 0) {
    $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
}
else {
    'SubscriptionId,SubscriptionName,ResourceGroup,Zone,FQDN,IPv4Address,TTL,RecordSetId' |
        Set-Content -Path $OutputPath -Encoding UTF8
}

if ($failures.Count -gt 0) {
    throw "INCOMPLETE export: saved $($rows.Count) accessible A-record entries to $OutputPath, but skipped $($failures.Count) subscription(s) or zone(s). See the warnings above for Azure error details. The CSV is not a complete inventory."
}

Write-Host "Complete export: exported $($rows.Count) A-record entries to $OutputPath"