# DNS Automation

Exports Private DNS A records from enabled subscriptions visible to Azure CLI.

## Run

Requires PowerShell and an authenticated Azure CLI session (available in Azure
Cloud Shell's PowerShell environment).

```powershell
az login --tenant "<tenant-id>" --use-device-code
.\Export-PrivateDnsARecords.ps1 -OutputPath .\private-dns-a-records.csv
```

## Failure handling

- Failed subscription queries, including `SubscriptionNotFound`, emit a warning
  containing the subscription and original Azure error. Processing continues
  with the next subscription.
- Failed A-record queries emit a warning identifying the zone, resource group,
  subscription, and original error. Processing continues with the next zone.
- Accessible records are still exported. If anything was skipped, the script
  throws an `INCOMPLETE export` error **after writing the CSV**. Treat that CSV as
  a partial inventory; an uncaught error also gives a nonzero exit status when
  run through `pwsh -File`.
- A successful export with no A records writes a header-only CSV. An incomplete
  export with no accessible records also writes a header, but reports failure.
- Authentication, subscription enumeration, no enabled subscriptions, and
  output-file errors stop the script rather than reporting a successful export.
- CLI diagnostic output is kept separate from JSON, and temporary diagnostic
  files are removed after each command.

The script cannot repair expired credentials, tenant mismatches, or missing
subscription access. Subscription enumeration can contain stale entries. To
refresh it, run `az account clear`, sign in again to the correct tenant, and
verify access. Clearing the CLI cache does not modify Azure resources.

## Tests

Run the regression tests with a mocked Azure CLI; no Azure access is needed:

```powershell
pwsh -NoProfile -File ./tests/Export-PrivateDnsARecords.Tests.ps1
```