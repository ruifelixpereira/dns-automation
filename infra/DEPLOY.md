# Deploy, test and demonstrate centralized private DNS

Run commands from the **repository root**, using Bash on Linux/WSL. These instructions create an isolated demo, not an import of your existing landing zone. **Nothing has been deployed or live-verified while writing this runbook.**

The guarded entrypoint is [scripts/demo.sh](./scripts/demo.sh). It separates planning from applying, requires typed confirmation for mutations, and explicitly targets your configured subscription without changing the Azure CLI default.

## 1. Prerequisites and costs

- Terraform 1.12+ below 2.0, current Azure CLI, `jq`, Bash 4+, GNU `timeout`, `sha256sum`, `awk`, and `ssh-keygen`.
- An authenticated Azure public-cloud account: `az login`.
- A **dedicated demo subscription** and a unique 3-16 character lowercase alphanumeric prefix beginning with a letter.
- Subscription Owner, or equivalent resource provisioning, Policy definition/assignment, custom-role definition and role-assignment permissions. Contributor alone is insufficient. Run Command also requires `Microsoft.Compute/virtualMachines/runCommand/action`.
- An available region with DNS Private Resolver, the required VM SKU/Trusted Launch support, sufficient quotas and an unused IPv4 `/14`.
- No existing resource groups/resources with the generated names. Review inherited management-group policies; this demo does not bypass them.

**Billable resources:** resolver inbound and outbound endpoints, private endpoints, Storage/Key Vault, two VMs and OS disks, **two NAT gateways and two outbound public IPs**, plus applicable networking/DNS usage. The optional clients can be omitted for metadata-only inspection, but both are required for the automated two-spoke DNS demonstration. Check current Azure pricing and your budget before applying; do not leave the demo running unnecessarily.

The VMs have **no NIC public IPs and no inbound SSH access**. Each gets a dedicated client subnet and a NAT gateway in its own VNet. Azure Run Command needs outbound HTTPS to Azure public endpoints; a NAT gateway cannot serve two different VNets. No private SSH key, Azure credentials or Terraform state are copied into the VMs. The guest check uses built-in `getent`, not a package installation.

Use the **default workspace and local state** for all three roots. Do not mix this runner with existing deployments, remote backends, custom workspaces, other variable files or simultaneous Terraform processes. Protect state and plans: they can contain sensitive data even though Git ignores them. Keep them through cleanup.

## 2. Select your subscription and configure

Inspect your accessible subscriptions, then replace the placeholder:

```bash
az login
az account list --query '[].{Name:name,Id:id,State:state}' --output table

SUBSCRIPTION_ID="REPLACE-WITH-YOUR-SUBSCRIPTION-UUID"
bash infra/scripts/demo.sh configure "$SUBSCRIPTION_ID" dnsdemo swedencentral
```

This writes ignored local files:

- [demo.tfvars.json](./demo.tfvars.json): foundation subscription, prefix, region, CIDR, ownership tag and enforcement flag.
- [examples/private-endpoints/demo.tfvars.json](./examples/private-endpoints/demo.tfvars.json): Blob in spoke 1 and Key Vault in spoke 2.

Review these files. Change `base_cidr` if `10.40.0.0/14` conflicts with your environment. Keep the `demo-prefix` tag equal to `name_prefix`; cleanup relies on it. `configure` refuses to overwrite an existing configuration.

**Leave `enforce_zone_location` false initially.** Only the zone-location restriction is Audit in this mode; the other DNS policies still deploy/audit their related resources. Later, enabling Deny affects **all private DNS zone creation outside the shared DNS resource group across the subscription**, not just the samples.

```bash
bash infra/scripts/demo.sh preflight
```

Preflight checks the selected account/cloud, provider registrations and required Policy aliases, then displays applicable assignments. It does **not** prove effective RBAC, regional capacity, quotas, non-overlapping addressing or an acceptable price.

If a provider is unregistered, inspect the reported prerequisite, then deliberately run:

```bash
bash infra/scripts/demo.sh register-providers
bash infra/scripts/demo.sh preflight
```

Registration is subscription-wide and is not undone by cleanup. If provider metadata times out or an alias is missing, stop and investigate; do not skip that gate.

Check client VM availability and quota separately before deploying clients:

```bash
SUBSCRIPTION_ID=$(jq -r .subscription_id infra/demo.tfvars.json)
LOCATION=$(jq -r .location infra/demo.tfvars.json)
az vm list-skus --subscription "$SUBSCRIPTION_ID" --location "$LOCATION" \
  --resource-type virtualMachines --size Standard_B2ats_v2 --all \
  --query '[].{Name:name,Family:family,Restrictions:restrictions}' --output json
az vm list-usage --subscription "$SUBSCRIPTION_ID" --location "$LOCATION" --output table
```

Confirm both regional and VM-family vCPU quota for two VMs. A listed SKU is not a reservation or guarantee of capacity. If necessary, choose another small Gen2/Trusted Launch-capable size through the client `vm_size` input below.

## 3. Deploy the foundation

```bash
bash infra/scripts/demo.sh plan foundation
# Review every proposed resource, role and subscription Policy assignment.
bash infra/scripts/demo.sh apply foundation
```

At the prompt, type the exact action/subscription/prefix shown, for example `DEPLOY-foundation <subscription-uuid> dnsdemo`. Nothing applies without matching confirmation. Saved plans live in ignored [`.demo/`](./.demo/) and are bound to their subscription, prefix, root, operation, variable-file hash and plan-file hash. Editing the configuration requires a fresh plan. Deploy plans containing deletions or replacements are rejected.

Expected foundation: three resource groups, hub plus two spoke VNets, dedicated private endpoint subnets, hub/spoke peerings, resolver endpoints/ruleset, remediation identity/RBAC and the eight-definition initiative. **The shared DNS group starts empty.** Allow Policy/RBAC propagation before the endpoint demo.

## 4. Demonstrate existing-zone reuse and missing-zone creation

Seed only the Blob zone **before** creating endpoints:

```bash
bash infra/scripts/demo.sh seed-zone
bash infra/scripts/demo.sh status
```

Confirm `privatelink.blob.core.windows.net` exists centrally and `privatelink.vaultcore.azure.net` is absent. If the demo already contains zones, do not delete a live zone to fake this scenario; inspect the state or use a fresh isolated demo.

Create the samples without Terraform DNS zones/groups:

```bash
bash infra/scripts/demo.sh plan samples
bash infra/scripts/demo.sh apply samples
bash infra/scripts/demo.sh remediate
bash infra/scripts/demo.sh status
```

The remediation command creates unique tasks and **waits for each task's successful deployments**, in order:

1. Missing shared service zones.
2. Zone-to-hub links with auto-registration disabled.
3. Missing endpoint zone groups.

Policy itself does not guarantee this execution order. Normal asynchronous evaluation can still overlap; initial failures from propagation or missing prerequisites must be inspected. A completed task with zero deployments alone does not prove DNS convergence. Rerun remediation only after diagnosing failures; `verify` below is the acceptance gate.

Explain the result during the demo:

- The Blob endpoint reuses the pre-existing shared Blob zone.
- The Key Vault endpoint causes its previously absent zone to be created centrally.
- Each zone has a hub VNet link, not spoke links.
- Endpoint zone groups associate the shared zone and Azure manages the A records. The script does not add manual A records.
- Existing wrong/empty groups are audited rather than destructively overwritten; repair requires an administrator.

## 5. Deploy private test clients and verify both spokes

Generate a demo key **outside the repository**, or use an existing public key. Do not overwrite an existing key:

```bash
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$HOME/.ssh/dnsdemo" -C dnsdemo

umask 077
test ! -e infra/examples/dns-clients/demo.tfvars.json &&
  jq -n --rawfile key "$HOME/.ssh/dnsdemo.pub" \
    '{ssh_public_key:($key | rtrimstr("\n")),vm_size:"Standard_B2ats_v2"}' \
    > infra/examples/dns-clients/demo.tfvars.json
```

If the config already exists, edit it deliberately. Supply only the OpenSSH **public** key text, never the private key or a path. Run Command does not use this SSH key; Azure Linux provisioning still requires it.

```bash
bash infra/scripts/demo.sh plan clients
bash infra/scripts/demo.sh apply clients
bash infra/scripts/demo.sh verify
```

For default addressing, clients use `10.41.2.0/24` and `10.42.2.0/24`, separate from private endpoints and resolver subnets. No inbound management connectivity is opened.

`verify` first checks Azure metadata from your workstation: the exact shared-zone association, single non-registering hub link and expected A record. It then invokes [resolve.sh](./scripts/resolve.sh) using **Azure Run Command on each VM**, checking both sample FQDNs from both spokes. Each must resolve through system DNS to exactly the expected endpoint IP and produce a matching guest success marker. An Azure CLI exit code alone is not considered guest success.

Expect four spoke/FQDN `PASS` lines. No VPN, laptop private-DNS configuration, guest Azure login, SSH or `dig` installation is required. DNS visibility does not imply HTTPS reachability between spokes: this topology has no transitive spoke routing. This checks DNS, not authenticated Storage/Key Vault data operations.

Without clients you can inspect `status`, or use the existing verifier's `--metadata-only` mode, but **do not claim two-spoke DNS success**.

## 6. Enable and demonstrate the Deny policy

Only after approving the **subscription-wide** impact, edit [demo.tfvars.json](./demo.tfvars.json) and change `enforce_zone_location` to `true`.

```bash
bash infra/scripts/demo.sh plan foundation
bash infra/scripts/demo.sh apply foundation
# Allow assignment propagation, then:
bash infra/scripts/demo.sh test-deny
```

The test attempts to create `denied.<prefix>.demo.internal` in the networking group. It succeeds as a test only when the error is `RequestDisallowedByPolicy` referencing **this assignment**; an RBAC error or another policy's denial does not count. If unexpectedly allowed, it deletes that exact newly-created test zone and fails. It never overwrites an existing test zone.

The supported shared zones and their hub links demonstrate the permitted central location. For an additional custom-zone/link test, follow the explicit live acceptance procedure in [README.md](./README.md#live-acceptance-tests-requires-deployment-approval); manually inspect/delete that named custom zone afterward. Automated cleanup deliberately rejects unexpected zone names.

To return to Audit while retaining the demo, set the flag back to `false` and review/apply a fresh foundation plan.

## 7. Repeatability and no-drift checks

```bash
bash infra/scripts/demo.sh remediate
bash infra/scripts/demo.sh verify
bash infra/scripts/demo.sh status

terraform -chdir=infra plan -var-file=demo.tfvars.json -detailed-exitcode
terraform -chdir=infra/examples/private-endpoints plan -var-file=demo.tfvars.json -detailed-exitcode
terraform -chdir=infra/examples/dns-clients plan -var-file=demo.tfvars.json -detailed-exitcode
```

Require exit `0` for each unchanged-root plan. Exit `2` means a real diff to investigate; exit `1` is an error. Repeated remediation should retain the same zone/link/group IDs without duplicate records.

For optional concurrency, incorrect-group, hub-endpoint and record-deletion scenarios, see [live acceptance tests](./README.md#live-acceptance-tests-requires-deployment-approval). The runner intentionally rejects partial resource deletions/replacements in deploy plans. Such advanced scenarios need a separately reviewed manual Terraform plan, not a bypass flag.

## 8. Tear down in dependency order

Keep all local state/configuration until completion. Inspect each destroy plan and type the requested confirmation:

```bash
# Omit this pair only if clients were never deployed.
bash infra/scripts/demo.sh plan-destroy clients
bash infra/scripts/demo.sh destroy clients

bash infra/scripts/demo.sh plan-destroy samples
bash infra/scripts/demo.sh destroy samples

bash infra/scripts/demo.sh cleanup-dns

bash infra/scripts/demo.sh plan-destroy foundation
bash infra/scripts/demo.sh destroy foundation
```

Destroying clients removes their two VMs/disks, private NICs, client subnets, NSG, NAT gateways and outbound public IPs. Destroying samples removes the service endpoints; zone groups should remove their records. Key Vault purge protection keeps deleted vault names reserved during retention; cleanup deliberately does not purge vaults.

`cleanup-dns` requires no endpoints or VMs in the networking group, validates the two known zone names/ownership tags, and refuses any non-SOA records. It cancels/waits this assignment's active remediation tasks, removes their task metadata, then deletes the inspected empty demo zones and their links. Unexpected zones/records require explicit investigation, not blind deletion. Foundation teardown also refuses non-empty child states, remaining DNS zones or active remediation tasks. AzureRM's non-empty-resource-group safety stays enabled.

After foundation destruction, inspect the configured resource groups and assignment in Azure to confirm they are absent. Retain/protect the empty state and audit evidence according to your organization's policy. Do not delete resource groups directly or discard state to force a cleanup.

## Troubleshooting and safety limits

- **Authentication/permissions:** use `az login` in the correct tenant. The script supplies `--subscription` to resource commands and never calls `az account set`. Check custom roles, Policy operations, inherited Deny and managed-identity role propagation.
- **Propagation/remediation:** inspect the failing task with `az policy remediation show` and `az policy remediation deployment list`, explicitly supplying your subscription and task name. Inspect underlying ARM deployment errors; do not treat task creation as completion.
- **Wrong existing groups/links:** exact-ID audits do not overwrite them. Repair the intended config/link deliberately while preserving unrelated settings, then reevaluate.
- **VM unavailable/quota:** check SKU restrictions, regional/family quota and Gen2/Trusted Launch compatibility before changing `vm_size` and replanning. Replacement plans are intentionally refused.
- **Run Command:** check VM agent health, NAT/subnet associations, outbound HTTPS and custom DNS to the hub inbound endpoint. Default NSG outbound rules are retained; external policies/UDRs can still block traffic.
- **Timeouts:** defaults are 600 seconds per Azure CLI command (and for the complete metadata-verification phase), 1800 seconds per remediation task, polling every 15 seconds. Override with positive integer environment variables, for example:

  ```bash
  COMMAND_TIMEOUT_SECONDS=900 REMEDIATION_TIMEOUT_SECONDS=3600 \
    bash infra/scripts/demo.sh remediate
  ```

  `POLL_INTERVAL_SECONDS` controls polling. A host timeout stops waiting, **not necessarily the remote task or guest command**. Inspect outstanding Azure activity before retrying. Do not run overlapping guest commands.
- **Plan rejected/stale:** create and review a fresh plan. Do not edit plan receipts. The runner guards common accidental targeting/destruction errors; it is not a security boundary against a user who can edit scripts/state.
- **Interrupted cleanup:** inspect the already-completed steps, resume from the relevant root, and preserve state. Never disable non-empty-group protection or delete unrelated resources.

## Offline validation

These commands do not deploy resources:

```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra/examples/dns-clients init -backend=false -input=false
terraform -chdir=infra/examples/dns-clients validate
terraform -chdir=infra/examples/dns-clients test
bash -n infra/scripts/demo.sh infra/tests/demo.tests.sh infra/tests/verify-live.sh
sh -n infra/scripts/resolve.sh
bash infra/tests/demo.tests.sh
bash infra/tests/verify-live.tests.sh
```

The tests mock Azure and guest DNS. They do not prove live Policy acceptance, actual deployment success or DNS resolution in your subscription.

References: [Run Command requirements](https://learn.microsoft.com/azure/virtual-machines/linux/run-command), [Run Command CLI parameters](https://learn.microsoft.com/cli/azure/vm/run-command), [Policy remediation](https://learn.microsoft.com/azure/governance/policy/concepts/remediation-structure), [VM SKU CLI](https://learn.microsoft.com/cli/azure/vm#az-vm-list-skus).
