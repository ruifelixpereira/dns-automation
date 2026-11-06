# Minimal centralized private DNS landing zone

An **isolated demonstration**, not a full enterprise landing zone or an import of existing infrastructure. Creates three resource groups, one hub, two spokes, dedicated endpoint subnets, a hub DNS Private Resolver, and a policy initiative. Nothing is deployed by cloning or validating this project.

For guided deployment, a two-spoke DNS demo and guarded teardown, use [the deployment runbook](./DEPLOY.md) and [the Bash runner](./scripts/demo.sh).

## Feasibility and scope

| Requirement | Implementation | Important limit |
| --- | --- | --- |
| Restrict zone creation | Deny `Microsoft.Network/privateDnsZones` outside the shared DNS resource group | **Audit by default**; explicitly opt into subscription-wide Deny. This restricts location, not caller identity. |
| Associate endpoints with existing zones | Two DeployIfNotExists (DINE) definitions create missing groups; two AuditIfNotExists definitions check the exact shared-zone ID | Existing incorrect/incomplete groups are audited, not overwritten. Administrator repair is required. |
| Create missing shared zones | Two DINE definitions inspect the shared resource group and deploy the service's zone there | No guaranteed ordering before group creation. Operators may need staged remediation after initial failures. |
| Link shared zones to hub | DINE checks the hub ID and disabled auto-registration, then creates a hub link | Existing conflicting links under another name can require administrator repair. Additional spoke links are not removed. |

Four logical requirements use **eight definitions**, grouped in one initiative. The service mappings are explicit:

| Service resource type | Endpoint group ID | Shared zone (Azure public cloud) |
| --- | --- | --- |
| `Microsoft.Storage/storageAccounts` | `blob` | `privatelink.blob.core.windows.net` |
| `Microsoft.KeyVault/vaults` | `vault` | `privatelink.vaultcore.azure.net` |

Both automatically and manually requested service connections are matched by target resource type **and** group ID within the same connection. Manual approval still belongs to the service owner; a DNS record does not prove that the connection is approved. Other service types, service aliases, other storage subresources and sovereign-cloud DNS suffixes are not supported by this demo.

Endpoint-related policies only match endpoints in the demo networking resource group, where the identity has permissions. The zone-location policy covers the **whole subscription**, and the hub-link policy covers all private DNS zones in the shared DNS resource group. Existing zones elsewhere are not moved or deleted. Existing governance inherited from management groups can still block this project.

## Architecture and DNS query flow

Default addressing, derived from a configurable IPv4 `/14`:

| VNet | Address space | Endpoint subnet | DNS |
| --- | --- | --- | --- |
| Hub | `10.40.0.0/16` | `10.40.1.0/24` | Azure-provided DNS |
| Spoke 1 | `10.41.0.0/16` | `10.41.1.0/24` | `10.40.0.4` |
| Spoke 2 | `10.42.0.0/16` | `10.42.1.0/24` | `10.40.0.4` |

The hub inbound endpoint has static IP `10.40.0.4` in delegated subnet `10.40.0.0/28`. The outbound endpoint uses a separate delegated `10.40.0.16/28`. These subnets are not used by endpoints or clients. Each hub/spoke connection has peering in both directions. There is no spoke-to-spoke peering, transitive routing, gateway or NVA.

A spoke client queries its configured custom DNS server over UDP/TCP 53. The hub resolver resolves the service's normal public FQDN through the Private Link CNAME chain and the hub-linked shared zone, returning the endpoint IP. **Peering does not share private DNS zone links.** The configured DNS server is what provides zone visibility to the spokes.

The empty outbound-associated ruleset is linked to the hub to support future real forwarding rules. This link and outbound endpoint are not required merely to resolve hub-linked zones, but are retained as requested. No dummy or self-forwarding rules are created. **Never add a forwarding rule targeting this hub's inbound IP to this hub-linked ruleset**: that can create a DNS loop.

An NSG on endpoint subnets allows inbound HTTPS from the three demo VNets and denies other inbound traffic. Private endpoint network policies are enabled to apply that NSG. Dedicated resolver subnets have no NSG in this minimal demo; do not add controls blocking UDP/TCP 53. The foundation creates no route tables, firewall or workload compute. The optional [DNS-client root](./examples/dns-clients/) adds two private Linux VMs, dedicated client subnets and one NAT gateway/outbound public IP per spoke for Azure Run Command. It opens no inbound SSH or VM public IPs. The NSG and peering do not make spoke-to-spoke endpoint access routable.

DNS checks from both spokes can validate all names without HTTPS connectivity between spokes. For application connectivity, access each spoke's endpoint from that spoke or the hub, or deliberately add routing in a separate design.

## Ownership and idempotence

- Foundation Terraform owns the resource groups, networking, resolver, identity, RBAC and policy resources.
- **Policy owns all service private DNS zones, hub links and endpoint DNS zone groups.** The shared DNS resource group initially contains no zones. Zones appear when a supported endpoint is created or remediated.
- Azure's zone-group integration owns endpoint A records and their lifecycle. VNet auto-registration is disabled; it is for VM records, not endpoint registration.
- The optional sample root has separate state and owns its service resources and endpoints. Its only `ignore_changes` is the endpoint's `private_dns_zone_group`, an explicit child-resource ownership boundary. Without this, AzureRM can plan to remove a group discovered after Policy attaches it. Other endpoint changes are still tracked.
- Expected zone-ID outputs are constructed IDs, **not existence checks**.
- Do not add the same dynamic zones/links/groups to another Terraform state. If you seed a zone manually to test existing-zone behavior, leave it outside the foundation state.
- Repeated DINE evaluation uses the same resource names and checks related-resource existence. Distinct accounts/vaults can share a service zone because their record names differ.
- Multiple endpoints for the **same** service resource can compete for the same DNS record name. This demo deliberately creates distinct resources for concurrency tests. Do not assume deletion of one endpoint preserves another endpoint's colliding record.
- A group appearing between evaluation and deployment may cause a conflict. Do not concurrently edit policy-owned groups; inspect failures and rerun remediation. No atomic transaction or concurrency lock is promised.

## Prerequisites and deployment safety

Use Terraform 1.12+, Azure CLI, a region supporting DNS Private Resolver (default West Europe), and a **dedicated demo subscription**. `jq` and `dig` are also needed for standalone client-side live verification. The [guided Run Command demo](./DEPLOY.md) uses `getent` instead of `dig`. The AzureRM 5.x selection is pinned by committed provider lock files in all three roots.

Authenticate using `az login` for local use or workload identity/OIDC for CI. Do not put credentials in variable files or source control.

The provisioning principal needs:

- Resource creation permissions on the target subscription/resource groups.
- Policy definition, initiative and assignment permissions at subscription scope.
- Custom role-definition and role-assignment permissions, plus permission to assign the user-assigned identity.
- The optional samples also need service and endpoint provisioning permissions.

The Policy identity receives:

- **Private DNS Zone Contributor** only on the shared DNS resource group.
- A custom role only on the networking resource group, allowing group read/write, VNet read/join, resource group read and ARM deployments. It cannot create/delete VNets or private endpoints.

Role IDs in `roleDefinitionIds` **do not grant permissions by themselves** in Terraform. Actual role assignments are created before the initiative assignment. RBAC propagation can still delay the first remediation.

Only trusted platform operators should have write access to the shared DNS resource group. The deny policy cannot distinguish a human user from Policy's managed identity. A portal endpoint workflow that attempts to create a zone outside that group can be denied; create the endpoint without new-zone integration and let Policy associate it instead.

The provider deliberately does not auto-register resource providers. Before deployment, confirm `Microsoft.Network`, `Microsoft.Authorization`, `Microsoft.ManagedIdentity`, and (for samples) `Microsoft.Storage` / `Microsoft.KeyVault` are registered. Check your region, quotas, address allocation and inherited policy before applying. Registration, provider quotas, live RBAC, aliases and ARM policy acceptance are **not validated by local Terraform tests**.

### Local validation (no Azure resources)

From the repository root:

```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra init -backend=false -input=false
terraform -chdir=infra validate
terraform -chdir=infra test
terraform -chdir=infra/examples/private-endpoints init -backend=false -input=false
terraform -chdir=infra/examples/private-endpoints validate
terraform -chdir=infra/examples/private-endpoints test
bash -n infra/tests/verify-live.sh
bash infra/tests/verify-live.tests.sh
terraform -chdir=infra/examples/dns-clients init -backend=false -input=false
terraform -chdir=infra/examples/dns-clients validate
terraform -chdir=infra/examples/dns-clients test
bash infra/tests/demo.tests.sh
checkov -d infra --framework terraform --skip-download
```

Terraform tests use mocked providers and **plan only**: they never create Azure resources. They check addressing, DNS path, subnet separation, policy parameter wiring, non-destructive group handling, hub-link registration, scoped RBAC, explicit Deny opt-in, private sample defaults and invalid inputs. The shell tests mock Azure/DNS responses and check explicit failures for incorrect zones, registration, records, public resolution and command errors. Neither suite executes Azure Policy's evaluation engine.

### Plan against an approved target subscription

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
# Edit subscription_id, location, name_prefix and allocated base_cidr.
# Keep enforce_zone_location=false until the subscription-wide impact is approved.
terraform -chdir=infra init
terraform -chdir=infra validate
terraform -chdir=infra plan -out=foundation.tfplan
```

Review the plan, names, cost and governance impact. Run `terraform -chdir=infra apply foundation.tfplan` **only after explicit deployment approval**. No apply command was run while implementing this project.

After foundation deployment, plan samples separately:

```bash
cp infra/examples/private-endpoints/terraform.tfvars.example infra/examples/private-endpoints/terraform.tfvars
terraform -chdir=infra/examples/private-endpoints init
terraform -chdir=infra/examples/private-endpoints validate
terraform -chdir=infra/examples/private-endpoints plan -out=samples.tfplan
```

Apply that saved plan only after approval. Samples create no Terraform DNS zones or zone groups, so they exercise Policy.

To activate the first requirement, set `enforce_zone_location=true`, review a new foundation plan and obtain approval before applying it. Leaving the default false only audits location violations; it **does not prevent zone creation**.

### State

All three roots default to local state for a self-contained demo. State and plans are ignored by Git but can contain sensitive provider data; protect them. The sample and optional client roots read foundation outputs from `../../terraform.tfstate`. The sample root permits overriding `foundation_state_path`; the guided runner requires the default local layout.

For team use, configure authenticated remote state in an existing protected backend and migrate each root separately. Update the sample `terraform_remote_state` backend/config to match. Do not create a backend storage account here merely to bootstrap this demo.

## Pre-deployment alias verification

The initial live provider-metadata query timed out. Before applying, verify that the target cloud publishes these aliases. No policy definition should be deployed using an unrecognized alias:

```bash
az provider show --namespace Microsoft.Network --expand resourceTypes/aliases \
  --query 'resourceTypes[].aliases[].name' --output tsv
```

Required aliases:

```text
Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*]
Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*].privateLinkServiceId
Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*].groupIds[*]
Microsoft.Network/privateEndpoints/manualPrivateLinkServiceConnections[*]
Microsoft.Network/privateEndpoints/manualPrivateLinkServiceConnections[*].privateLinkServiceId
Microsoft.Network/privateEndpoints/manualPrivateLinkServiceConnections[*].groupIds[*]
Microsoft.Network/privateEndpoints/privateDnsZoneGroups/privateDnsZoneConfigs[*]
Microsoft.Network/privateEndpoints/privateDnsZoneGroups/privateDnsZoneConfigs[*].privateDnsZoneId
Microsoft.Network/privateDnsZones/virtualNetworkLinks/virtualNetwork.id
Microsoft.Network/privateDnsZones/virtualNetworkLinks/registrationEnabled
```

Use the target subscription explicitly if the CLI's default differs. The templates use verified resource schemas: DNS zones/links `2024-06-01` and endpoint zone groups `2024-07-01`. DINE templates are inline, resource-group-scoped and incremental; there are no unsupported linked templates.

## Staged Policy-only remediation

Policy evaluation is asynchronous. `AfterProvisioningSuccess` is not a dependency between definitions. Assignment propagation can take minutes; ordinary compliance scans are periodic, commonly around 24 hours. A scan marks non-compliant resources but does not itself deploy DINE resources. Failed zone-group association does not imply rollback of the endpoint or zone.

For an approved deployed demo, retrieve the assignment:

```bash
SUBSCRIPTION_ID=$(terraform -chdir=infra output -raw subscription_id)
ASSIGNMENT_ID=$(terraform -chdir=infra output -raw policy_assignment_id)
az policy state trigger-scan --subscription "$SUBSCRIPTION_ID"
```

Create one remediation task per relevant reference, **wait for completion and inspect failure details**, then move to the next stage. Use a unique task name for each attempt:

```bash
# Stage 1: repeat for create-zone-vault if needed.
az policy remediation create --subscription "$SUBSCRIPTION_ID" \
  --name dns-zones-blob-01 --policy-assignment "$ASSIGNMENT_ID" \
  --definition-reference-id create-zone-blob \
  --resource-discovery-mode ReEvaluateCompliance
az policy remediation show --subscription "$SUBSCRIPTION_ID" --name dns-zones-blob-01
az policy remediation deployment list --subscription "$SUBSCRIPTION_ID" --name dns-zones-blob-01
```

After the zones exist, trigger another scan and create a task for `link-zone-hub`. Wait for successful completion. Then trigger another scan and create tasks for `create-group-blob` and `create-group-vault`. Finally scan again and inspect `audit-group-blob` / `audit-group-vault`. Audits have no remediation deployment.

For any failed deployment, inspect its ARM error before retrying. Common causes: missing zone, incomplete RBAC propagation, inherited policy denial, unapproved endpoint connection, conflicting group, conflicting VNet link or unsupported aliases. Do not treat a remediation task's creation as proof its deployments succeeded.

### Existing incorrect associations

Creation policies intentionally consider **any** existing group sufficient to avoid mutation. The paired audit still reports non-compliance unless a config references the exact shared-zone resource ID.

An administrator must inspect the existing group's name and configs. Where appropriate, update the intended config to the shared-zone ID while preserving other valid configs; do not blindly replace the whole group or create a second group. If the group is empty and safe to remove, delete it deliberately and rerun missing-group remediation. Correct an existing hub link's registration flag in place if another same-hub link name prevents new-link creation.

## Live acceptance tests (requires deployment approval)

Run these only in the approved demo. None were executed during local implementation.

1. **Location Deny:** activate `enforce_zone_location=true`. As a workload creator, attempt `az network private-dns zone create` for `denied.demo.internal` in the networking resource group. Expect an explicit `RequestDisallowedByPolicy` referencing this assignment, not just any command failure. Create `allowed.demo.internal` in the shared group and expect success; remediate its hub link. Delete this named test zone after inspection.
2. **Existing zone:** create `privatelink.blob.core.windows.net` in the shared group before creating the Blob sample endpoint. Leave the endpoint without DNS integration. Stage remediation and verify the existing zone ID is reused, exactly one group appears and the account's A record equals the endpoint IP.
3. **Missing zone:** leave `privatelink.vaultcore.azure.net` absent before creating the Key Vault sample. Stage zone, link and group remediation; verify the zone exists only centrally and its A record matches. Do not delete a live zone with endpoints just to perform this test.
4. **Wrong/empty group:** use a dedicated disposable sample, deliberately configure an incomplete or incorrect group in an approved test scenario, trigger a scan, and verify the exact-ID audit flags it. Confirm missing-group remediation does not replace it. Perform explicit administrator repair and rescan.
5. **DNS from both spokes:** use existing clients in each VNet, outside the endpoint/resolver subnets. Export a sanitized manifest:

   ```bash
   terraform -chdir=infra/examples/private-endpoints output -json endpoints > endpoints.json
   terraform -chdir=infra output -json resource_groups
   terraform -chdir=infra output -json vnet_ids
   ```

   Copy only that manifest and the verification script to each client; **do not copy Terraform state or credentials**. Authenticate the client with a read-only Azure identity, then run:

   ```bash
   bash infra/tests/verify-live.sh SUBSCRIPTION_ID SHARED_DNS_RG HUB_VNET_ID endpoints.json
   ```

   This read-only script checks the exact zone association, single hub-only link, disabled auto-registration, exact A record and normal public FQDN resolution using the client's **system DNS**. Both client runs must succeed. An NSG/route/DHCP configuration outside this project can still affect the clients.
6. **Hub endpoint:** enable the optional `blob-hub` entry, review/apply the sample plan after approval, remediate and run the same verification from a hub client.
7. **Idempotence:** rerun the staged remediation with fresh task names. Verify the same zone/group/link IDs and records remain, with no duplicates.
8. **Concurrency:** enable `blob-spoke2` along with `blob-spoke1`, review/apply together and remediate. They create distinct accounts in the same service zone. Verify both A records remain correct after repeated remediation.
9. **Deletion:** remove one optional endpoint entry, review a sample plan showing only its intended resource deletions, then apply with approval. Confirm its record is removed by the zone-group lifecycle, unrelated endpoint records still exist and shared zones remain. Purge-protected Key Vault names remain unavailable during retention.
10. **No ownership fight:** after Policy has attached groups, run `terraform plan -detailed-exitcode` in both roots. For unchanged inputs, require exit `0`; investigate exit `2` for actual diffs, and fail on exit `1`. No DNS-group deletion/replacement should be proposed.

## Security scan exceptions

Local Checkov checks are supplemented by mocked Terraform tests and the live acceptance procedure. Resource-level exceptions are annotated with reasons:

- LRS replication and no CMK: disposable DNS samples hold no critical data; production reliability/encryption requirements are out of scope.
- Queue logging: the Queue service is not used.
- Trusted Microsoft Services bypass: intentionally disabled for stricter private-only access.
- Storage public access: the scanner checks a deprecated attribute; the current provider setting is `public_network_access = "Disabled"`, tested explicitly.
- Storage/Key Vault endpoint graph checks: the scanner cannot trace the conditional per-service reference; tests verify the connection and live verification checks actual DNS integration.
- Resolver subnet NSGs: intentionally omitted on dedicated managed-service subnets in this demo. Production network controls require separate validated design.

These are **documented exceptions, not proof of complete production security**. No blanket suppression or remote scanning service is used.

## Cost and cleanup

DNS resolver inbound/outbound endpoints incur recurring charges even with an empty ruleset. Private endpoints, private DNS hosting/queries, Storage and Key Vault can also incur charges. VNet peering traffic is billable. Check regional pricing before approving deployment; no cost estimate or quota validation was run.

Destroy optional clients, then the optional samples, after reviewing their destroy plans and obtaining approval. Confirm endpoint record cleanup. Stop/delete only this assignment's outstanding remediation tasks before tearing down the foundation, to prevent resources being recreated during cleanup. See [guarded cleanup commands](./DEPLOY.md#8-tear-down-in-dependency-order); optional VMs, NAT gateways and egress public IPs incur additional recurring charges.

Policy-created zones/links/groups are not in Terraform state. AzureRM's resource-group deletion safety may refuse to destroy the non-empty shared DNS group. After sample endpoints are gone, inspect that group and explicitly delete only the demo's policy-owned links/zones with approval, then destroy the foundation. Do not disable the provider's non-empty-group safety or blindly delete shared infrastructure.

Key Vault purge protection cannot be bypassed for immediate name reuse; allow retention to expire or choose a new demo prefix. Do not purge unrelated vaults. Remote/local state should be retained/protected according to your organization's policy.

## References

- [Private Link and DNS integration at scale](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/private-link-and-dns-integration-at-scale)
- [Private Endpoint DNS integration and zone groups](https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration)
- [DNS Private Resolver architecture](https://learn.microsoft.com/azure/dns/private-resolver-architecture)
- [Resolver endpoints and rulesets](https://learn.microsoft.com/azure/dns/private-resolver-endpoints-rulesets)
- [DeployIfNotExists behavior and deployment scope](https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists)
- [Policy remediation and managed identity](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
- [Azure networking roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/networking#private-dns-zone-contributor)
- [Built-in Blob DNS policy](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Storage/StoragePrivateDnsZoneGroup_Blob.json) and [Key Vault DNS policy](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Key%20Vault/AutoConfigure_PrivateDNSZone_DINE.json): evaluated, but their loose existence checks and group-ID-only matching do not provide this demo's exact-ID auditing and target-type filtering.
- [AzureRM provider documentation](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
