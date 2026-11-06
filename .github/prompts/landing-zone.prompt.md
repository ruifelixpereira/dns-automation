# Prompt: Minimal Azure landing zone with centralized private DNS governance

Act as a senior Azure networking, Azure Policy, and Terraform engineer. Create a complete, minimal Terraform project for the architecture and four governance requirements below. Verify feasibility against current official Microsoft documentation and Terraform provider documentation before writing code. Do not invent Azure Policy aliases, API capabilities, or resource arguments.

## Scope and architecture

- Deploy into a single Azure subscription and a configurable Azure region.
- Create separate resource groups for networking, shared private DNS zones, and Azure DNS Private Resolver resources.
- Create one hub VNet and two spoke VNets: three VNets total. Use configurable, non-overlapping address spaces and bidirectional hub-to-spoke peerings. Do not assume peering is transitive or add spoke-to-spoke peering.
- Give all three VNets a dedicated subnet for private endpoints.
- Deploy Azure DNS Private Resolver associated with the hub VNet, with inbound and outbound endpoints in separate, correctly delegated subnets. Do not reuse private endpoint subnets for resolver endpoints.
- Create a DNS forwarding ruleset associated with the outbound endpoint. Keep it without dummy forwarding rules unless a real forwarding destination is supplied. Explain whether a hub ruleset link is necessary for the chosen configuration.
- Configure both spokes to use the hub resolver's inbound IP as custom DNS. Keep the hub on Azure-provided DNS. Ensure required UDP/TCP port 53 connectivity.
- Store all private DNS zones in the shared DNS resource group and link them to the hub only, with auto-registration disabled.
- Explain why VNet peering alone does not make hub-linked private DNS zones resolvable from spokes.
- Initially support Azure Storage Blob and Azure Key Vault, using the verified mappings `blob` -> `privatelink.blob.core.windows.net` and `vault` -> `privatelink.vaultcore.azure.net` for Azure public cloud. Match both the target resource type and private endpoint group ID.
- Keep the service mapping explicit and extensible. Do not claim automatic support for every Azure Private Link service.
- This is a small demonstration environment, not a complete enterprise landing zone. Do not add Azure Firewall, gateways, on-premises connectivity, AKS, or unrelated services.

## Four Azure Policy requirements

### 1. Restrict private DNS zone creation

Use a Deny policy to prevent creation of any `Microsoft.Network/privateDnsZones` resource outside the shared DNS resource group, including zone creation attempted through private endpoint workflows.

Allow zones inside the shared DNS resource group so platform provisioning and policy remediation can create them. Explain that this enforces location, not caller identity; use appropriate RBAC to restrict who can create zones inside that group. Explain the effect of selecting portal DNS integration when it attempts to create a prohibited zone.

### 2. Associate private endpoints with existing shared zones

For supported private endpoints, deploy or remediate a `Microsoft.Network/privateEndpoints/privateDnsZoneGroups` association to the correct shared private DNS zone.

Use the zone group to let Azure manage the corresponding A records and their lifecycle. Do not manually deploy A records or enable VNet auto-registration for this purpose.

Validate the exact expected zone resource ID, not merely the presence of any zone group. Respect the single-zone-group-per-private-endpoint restriction. Explain handling of absent, incomplete, or incorrectly configured groups without overwriting unrelated valid associations.

### 3. Create missing shared zones

For supported private endpoints whose corresponding shared zone is absent, use DeployIfNotExists to create that zone in the shared DNS resource group.

Show how the endpoint service/group ID selects the zone, how existence is checked in the correct resource group, and how deployment is scoped there.

Do not assume policy 3 runs before policy 2. Explain asynchronous evaluation, failed initial association attempts, and the supported remediation procedure to converge after zone creation. Delays alone must not be presented as an ordering guarantee.

### 4. Link shared zones to the hub

When a private DNS zone is created in the shared DNS resource group, use DeployIfNotExists to create its hub VNet link with auto-registration disabled. Check the target hub VNet ID and registration setting, not just whether any VNet link exists.

Cover both Terraform-created and policy-created zones, including remediation of existing zones.

## Policy-only feasibility and implementation constraints

- Use Terraform and Azure Policy only. Do not add Functions, Logic Apps, Event Grid handlers, deployment scripts, or external runtime automation.
- Start with a feasibility table for each requirement: supported mechanism, limitations, and evidence.
- If an exact requirement cannot be reliably achieved with Policy alone, state the gap explicitly and provide the closest supported Policy-only behavior. Do not silently remove a requirement or promise synchronous, atomic automation.
- Preserve four logical policy requirements. If multiple service-specific definitions are necessary, group them in an initiative and explain why the definition count differs from four.
- Verify current built-in policies before choosing custom equivalents.
- Include actual policy definitions, initiative, assignments, managed identities, narrowly scoped role assignments, and remediation instructions.
- Verify aliases, policy mode, existence conditions, evaluation delay, deployment scope, ARM API versions, and cross-resource-group permissions.
- Explain that `roleDefinitionIds` does not itself grant the assignment identity permissions when provisioning through Terraform.
- Use supported inline/nested ARM templates for DeployIfNotExists, not unsupported linked templates.
- Address concurrent endpoint creation, idempotence, unsupported service types, duplicate DNS names, endpoint deletion, and the distinction between convergence and immediate enforcement.
- Define clear Terraform-versus-Policy ownership so a later Terraform plan does not delete or overwrite policy-created zones, links, or zone groups. Do not use blanket `ignore_changes` to conceal conflicting ownership.
- Keep sample endpoint deployment separate and optional. Do not attach DNS zone groups in Terraform for the policy acceptance tests, because doing so would bypass the behavior under test.

## Deliverables

1. A concise architecture description, DNS query flow, and feasibility table with official references.
2. Complete Terraform files, not pseudocode: providers/version constraints, resources, variables, outputs, policy JSON/templates, and an example variable file without credentials.
3. A README covering prerequisites, RBAC, deployment, expected remediation latency, troubleshooting, cost-bearing resources, resource ownership, cleanup, and known limitations.
4. Optional sample Blob and Key Vault resources/private endpoints distributed across the two spokes, plus a documented way to test a private endpoint in the hub subnet.
5. Validation commands: `terraform fmt -check`, `terraform init`, `terraform validate`, and `terraform plan`. Distinguish checks actually executed from instructions requiring an Azure subscription.
6. Acceptance tests demonstrating:
   - Zone creation outside the shared DNS resource group is denied; creation inside it is allowed.
   - A private endpoint uses an existing shared zone and obtains the correct A record through its zone group.
   - A missing zone is created centrally, linked to the hub, and associated with the endpoint through the documented Policy-only convergence/remediation process.
   - An existing but incorrect association is detected and handled explicitly.
   - Both spokes resolve the sample services' normal public FQDNs to the correct private endpoint IPs.
   - Hub links have auto-registration disabled.
   - Repeated remediation is idempotent.
   - Concurrent endpoint creation for distinct service resources does not lose DNS records.
   - Endpoint deletion performs the expected zone-group-managed record cleanup without deleting unrelated records.
   - A subsequent Terraform plan does not fight Policy-managed resources.

Do not run `terraform apply`, create Azure resources, or change live policy assignments without explicit approval. Clearly identify any requirement that remains unverified.
