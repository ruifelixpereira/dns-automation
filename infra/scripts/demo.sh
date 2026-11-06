#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAIL: command failed at line %s; no later stage was run\n" "$LINENO" >&2' ERR

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
infra_dir=$(cd -- "$script_dir/.." && pwd)
command_timeout=${COMMAND_TIMEOUT_SECONDS:-600}
wait_timeout=${REMEDIATION_TIMEOUT_SECONDS:-1800}
poll_interval=${POLL_INTERVAL_SECONDS:-15}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

usage() {
  cat <<'USAGE'
Usage: bash infra/scripts/demo.sh COMMAND [ROOT]
  configure SUBSCRIPTION_ID [PREFIX] [REGION]  Write new local demo configs
  preflight                                  Check account, providers and aliases
  register-providers                         Explicitly register required providers
  plan ROOT | apply ROOT                     Review/apply a saved deploy plan
  plan-destroy ROOT | destroy ROOT            Review/apply a saved destroy plan
  seed-zone                                  Seed Blob zone before sample creation
  remediate                                  Wait for zones -> links -> groups
  status                                     Show zones, records and non-compliance
  verify                                     Check Azure metadata and DNS in both VMs
  test-deny                                  Test subscription-wide zone-location Deny
  cleanup-dns                                Cancel tasks and delete empty demo zones
ROOT is foundation, samples, or clients. Commands never switch the Azure CLI default.
USAGE
}

need_tools() {
  local tool
  for tool in terraform az jq timeout sha256sum awk; do
    command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"
  done
  [[ "$command_timeout" =~ ^[1-9][0-9]*$ && "$wait_timeout" =~ ^[1-9][0-9]*$ && "$poll_interval" =~ ^[1-9][0-9]*$ ]] ||
    fail "Timeouts and polling interval must be positive integer seconds"
}

module_dir() {
  case "$1" in
    foundation) printf '%s\n' "$infra_dir" ;;
    samples) printf '%s/examples/private-endpoints\n' "$infra_dir" ;;
    clients) printf '%s/examples/dns-clients\n' "$infra_dir" ;;
    *) fail "Unknown root: $1" ;;
  esac
}

configure() {
  local id=$1 prefix=${2:-dnsdemo} region=${3:-westeurope}
  [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ &&
     "$prefix" =~ ^[a-z][a-z0-9]{2,15}$ && "$region" =~ ^[a-z0-9]+$ ]] ||
    fail "Supply a subscription UUID, a 3-16 character lowercase alphanumeric prefix and an Azure region name"
  [[ ! -e "$infra_dir/demo.tfvars.json" && ! -e "$infra_dir/examples/private-endpoints/demo.tfvars.json" ]] ||
    fail "Demo config already exists; edit it deliberately rather than overwriting it"
  umask 077
  jq -n --arg id "$id" --arg prefix "$prefix" --arg region "$region" '{
    subscription_id: $id, name_prefix: $prefix, location: $region,
    base_cidr: "10.40.0.0/14", enforce_zone_location: false,
    tags: {"demo-prefix": $prefix}
  }' > "$infra_dir/demo.tfvars.json"
  jq -n '{endpoints: {
    "blob-spoke1": {service: "blob", network: "spoke1"},
    "vault-spoke2": {service: "vault", network: "spoke2"}
  }}' > "$infra_dir/examples/private-endpoints/demo.tfvars.json"
  log "Created local config files. Review CIDR, region, costs and subscription before preflight."
}

load_config() {
  local config="$infra_dir/demo.tfvars.json"
  [[ -f "$config" ]] || fail "Run configure first"
  jq -e '
    (.subscription_id | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) and
    (.name_prefix | test("^[a-z][a-z0-9]{2,15}$")) and
    (.location | test("^[a-z0-9]+$")) and
    (.enforce_zone_location | type == "boolean") and
    .tags["demo-prefix"] == .name_prefix
  ' "$config" >/dev/null || fail "Invalid demo config; preserve the demo-prefix ownership tag"
  subscription=$(jq -r '.subscription_id' "$config")
  prefix=$(jq -r '.name_prefix' "$config")
  work_dir="$infra_dir/.demo"
  umask 077
  mkdir -p "$work_dir"
  export ARM_SUBSCRIPTION_ID="$subscription" TF_IN_AUTOMATION=true
}

az_cli() {
  timeout "$command_timeout" az "$@" --subscription "$subscription" --only-show-errors
}

check_account() {
  local account cloud
  account=$(az_cli account show --output json)
  jq -e --arg id "$subscription" '
    (.id | ascii_downcase) == ($id | ascii_downcase) and .state == "Enabled"
  ' <<<"$account" >/dev/null || fail "The requested subscription is not accessible and Enabled; run az login"
  cloud=$(timeout "$command_timeout" az cloud show --query name --output tsv)
  [[ "$cloud" == "AzureCloud" ]] || fail "Only Azure public cloud DNS suffixes are supported"
  log "Target: subscription=$subscription, demo=$prefix"
}

confirm() {
  local action=$1 answer
  printf '\nType exactly "%s %s %s" to continue: ' "$action" "$subscription" "$prefix"
  read -r answer || fail "Confirmation input unavailable; nothing was changed"
  [[ "$answer" == "$action $subscription $prefix" ]] || fail "Confirmation did not match; nothing was changed"
}

foundation_outputs() {
  [[ -f "$infra_dir/terraform.tfstate" ]] || fail "Foundation local state is missing; this runner supports the default local backend only"
  foundation=$(terraform -chdir="$infra_dir" output -json)
  jq -e --arg id "$subscription" --arg prefix "$prefix" '
    (.subscription_id.value | ascii_downcase) == ($id | ascii_downcase) and .name_prefix.value == $prefix
  ' <<<"$foundation" >/dev/null || fail "Foundation state belongs to a different subscription or prefix"
  dns_group=$(jq -r '.resource_groups.value.dns' <<<"$foundation")
  network_group=$(jq -r '.resource_groups.value.network' <<<"$foundation")
  assignment=$(jq -r '.policy_assignment_id.value' <<<"$foundation")
}

preflight() {
  local namespace state metadata alias
  for namespace in Microsoft.Network Microsoft.Authorization Microsoft.ManagedIdentity Microsoft.PolicyInsights Microsoft.Storage Microsoft.KeyVault Microsoft.Compute; do
    state=$(az_cli provider show --namespace "$namespace" --query registrationState --output tsv)
    [[ "$state" == "Registered" ]] || fail "$namespace is $state; review and run register-providers"
  done
  metadata=$(az_cli provider show --namespace Microsoft.Network --expand resourceTypes/aliases --output json)
  local aliases=(
    'Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*]'
    'Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*].privateLinkServiceId'
    'Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*].groupIds[*]'
    'Microsoft.Network/privateEndpoints/manualPrivateLinkServiceConnections[*]'
    'Microsoft.Network/privateEndpoints/manualPrivateLinkServiceConnections[*].privateLinkServiceId'
    'Microsoft.Network/privateEndpoints/manualPrivateLinkServiceConnections[*].groupIds[*]'
    'Microsoft.Network/privateEndpoints/privateDnsZoneGroups/privateDnsZoneConfigs[*]'
    'Microsoft.Network/privateEndpoints/privateDnsZoneGroups/privateDnsZoneConfigs[*].privateDnsZoneId'
    'Microsoft.Network/privateDnsZones/virtualNetworkLinks/virtualNetwork.id'
    'Microsoft.Network/privateDnsZones/virtualNetworkLinks/registrationEnabled'
  )
  for alias in "${aliases[@]}"; do
    jq -e --arg alias "$alias" 'any(.resourceTypes[].aliases[]?; .name == $alias)' <<<"$metadata" >/dev/null ||
      fail "Required policy alias is not published: $alias"
  done
  az_cli policy assignment list --scope "/subscriptions/$subscription" --disable-scope-strict-match \
    --query '[].{name:name,scope:scope,enforcement:enforcementMode}' --output table
  log "PASS: provider/alias checks. Review inherited policy, RBAC, regional availability, VM SKU/quota, CIDR and costs separately."
}

config_fingerprint() {
  local root=$1 dir
  dir=$(module_dir "$root")
  if [[ "$root" == "foundation" ]]; then
    sha256sum "$infra_dir/demo.tfvars.json" | awk '{print $1}'
  else
    sha256sum "$infra_dir/demo.tfvars.json" "$dir/demo.tfvars.json" | sha256sum | awk '{print $1}'
  fi
}

check_plan() {
  local root=$1 operation=$2 plan=$3 receipt=$4 document
  [[ -f "$plan" && -f "$receipt" ]] || fail "Create a fresh $operation plan for $root first"
  jq -e --arg sub "$subscription" --arg prefix "$prefix" --arg root "$root" --arg operation "$operation" \
    --arg hash "$(sha256sum "$plan" | awk '{print $1}')" --arg config "$(config_fingerprint "$root")" '
    .subscription == $sub and .prefix == $prefix and .root == $root and .operation == $operation and
    .plan_sha256 == $hash and .config_sha256 == $config
  ' "$receipt" >/dev/null || fail "Plan receipt/config mismatch; create and review a fresh plan"
  document=$(terraform -chdir="$(module_dir "$root")" show -json "$plan")
  if [[ "$operation" == "deploy" ]]; then
    jq -e 'all(.resource_changes[]?; (.change.actions | index("delete")) == null)' <<<"$document" >/dev/null ||
      fail "Deploy plan includes deletion/replacement; inspect it manually, not through this demo runner"
  else
    jq -e 'all(.resource_changes[]?; all(.change.actions[]; . == "delete" or . == "no-op" or . == "read"))' <<<"$document" >/dev/null ||
      fail "Destroy plan contains unexpected creation or modification"
  fi
}

check_foundation_teardown() {
  foundation_outputs
  local root dir remaining zones tasks
  for root in clients samples; do
    dir=$(module_dir "$root")
    if [[ -f "$dir/terraform.tfstate" ]]; then
      remaining=$(terraform -chdir="$dir" state list)
      [[ -z "$remaining" ]] || fail "Destroy the $root root before destroying foundation"
    fi
  done
  zones=$(az_cli network private-dns zone list --resource-group "$dns_group" --output json)
  jq -e 'length == 0' <<<"$zones" >/dev/null || fail "Run cleanup-dns before destroying foundation"
  tasks=$(az_cli policy remediation list --output json)
  jq -e --arg id "$assignment" '
    all(.[]; (.policyAssignmentId | ascii_downcase) != ($id | ascii_downcase) or
      (.provisioningState == "Complete" or .provisioningState == "Succeeded" or
       .provisioningState == "Canceled" or .provisioningState == "Failed"))
  ' <<<"$tasks" >/dev/null || fail "Stop this assignment's active remediation tasks before destroying foundation"
}

plan_root() {
  local root=$1 operation=$2 dir plan receipt workspace
  dir=$(module_dir "$root")
  [[ -f "$dir/demo.tfvars.json" ]] || fail "Missing $dir/demo.tfvars.json; see DEPLOY.md"
  if [[ "$root" != "foundation" ]]; then foundation_outputs; fi
  if [[ "$root" == "foundation" && -f "$infra_dir/terraform.tfstate" ]]; then foundation_outputs; fi
  if [[ "$root" == "foundation" && "$operation" == "deploy" ]]; then preflight; fi
  if [[ "$root" == "foundation" && "$operation" == "destroy" ]]; then check_foundation_teardown; fi
  terraform -chdir="$dir" init -input=false
  workspace=$(terraform -chdir="$dir" workspace show)
  [[ "$workspace" == "default" ]] || fail "Demo runner requires the default workspace"
  terraform -chdir="$dir" validate
  plan="$work_dir/$root-$operation.tfplan"
  receipt="$work_dir/$root-$operation.receipt.json"
  local args=(-input=false "-var-file=$dir/demo.tfvars.json" "-out=$plan")
  if [[ "$operation" == "destroy" ]]; then args+=(-destroy); fi
  terraform -chdir="$dir" plan "${args[@]}"
  jq -n --arg sub "$subscription" --arg prefix "$prefix" --arg root "$root" --arg operation "$operation" \
    --arg hash "$(sha256sum "$plan" | awk '{print $1}')" --arg config "$(config_fingerprint "$root")" \
    '{subscription:$sub,prefix:$prefix,root:$root,operation:$operation,plan_sha256:$hash,config_sha256:$config}' > "$receipt"
  check_plan "$root" "$operation" "$plan" "$receipt"
  log "Saved $root $operation plan. Review the printed diff before running apply/destroy."
}

apply_root() {
  local root=$1 operation=$2 dir plan receipt
  dir=$(module_dir "$root")
  plan="$work_dir/$root-$operation.tfplan"
  receipt="$work_dir/$root-$operation.receipt.json"
  if [[ "$root" != "foundation" || -f "$infra_dir/terraform.tfstate" ]]; then foundation_outputs; fi
  if [[ "$root" == "foundation" && "$operation" == "destroy" ]]; then check_foundation_teardown; fi
  check_plan "$root" "$operation" "$plan" "$receipt"
  terraform -chdir="$dir" show -no-color "$plan"
  log "This changes billable resources. Foundation Deny, if enabled, affects the entire subscription."
  confirm "${operation^^}-$root"
  terraform -chdir="$dir" apply -input=false "$plan"
  rm -f -- "$receipt" "$plan"
}

wait_remediation() {
  local name=$1 allow_canceled=${2:-false} start=$SECONDS result state
  while (( SECONDS - start < wait_timeout )); do
    result=$(az_cli policy remediation show --name "$name" --output json)
    state=$(jq -er '.provisioningState' <<<"$result")
    case "$state" in
      Complete|Succeeded)
        jq -e '
          .deploymentStatus.failedDeployments == 0 and
          (.deploymentStatus.totalDeployments | type == "number") and
          .deploymentStatus.totalDeployments == .deploymentStatus.successfulDeployments
        ' <<<"$result" >/dev/null || {
          az_cli policy remediation deployment list --name "$name" --output json
          fail "$name completed with failed/incomplete deployments"
        }
        log "PASS: $name ($state)"
        return
        ;;
      Canceled)
        [[ "$allow_canceled" == "true" ]] || fail "$name was canceled"
        return
        ;;
      Failed)
        az_cli policy remediation deployment list --name "$name" --output json
        fail "$name failed; inspect ARM deployment errors before retrying"
        ;;
      Running|Accepted|Evaluating|Cancelling) sleep "$poll_interval" ;;
      *) fail "Unknown remediation state for $name: $state" ;;
    esac
  done
  fail "$name timed out; the task may still be running in Azure. Inspect it before retrying."
}

remediate() {
  foundation_outputs
  confirm REMEDIATE
  local stage reference task references
  for stage in zones links groups; do
    references=$(jq -er --arg stage "$stage" '.policy_reference_ids.value[$stage] | .[]' <<<"$foundation")
    while IFS= read -r reference; do
      task="$prefix-$reference-$(date -u +%Y%m%d%H%M%S)-$RANDOM"
      log "Stage $stage: $reference"
      az_cli policy remediation create --name "$task" --policy-assignment "$assignment" \
        --definition-reference-id "$reference" --resource-discovery-mode ReEvaluateCompliance --output none
      wait_remediation "$task"
    done <<<"$references"
  done
  log "Remediation deployments completed. Run verify and status; a zero-deployment task alone is not proof of convergence."
}

seed_zone() {
  foundation_outputs
  local zones zone="privatelink.blob.core.windows.net"
  zones=$(az_cli network private-dns zone list --resource-group "$dns_group" --output json)
  jq -e --arg zone "$zone" 'all(.[]; .name != $zone)' <<<"$zones" >/dev/null ||
    fail "Blob zone already exists; it was not overwritten. Use a fresh demo to show the existing-zone scenario."
  confirm SEED-BLOB-ZONE
  az_cli network private-dns zone create --resource-group "$dns_group" --name "$zone" \
    --tags "workload=central-private-dns" "demo-prefix=$prefix" "managed-by=demo-script" --output none
  log "Seeded Blob zone. Leave the Key Vault zone absent before creating samples."
}

status() {
  foundation_outputs
  az_cli network private-dns zone list --resource-group "$dns_group" --output table
  local zones zone
  zones=$(az_cli network private-dns zone list --resource-group "$dns_group" --output json)
  while IFS= read -r zone; do
    [[ -n "$zone" ]] || continue
    log "Zone: $zone"
    az_cli network private-dns link vnet list --resource-group "$dns_group" --zone-name "$zone" --output table
    az_cli network private-dns record-set a list --resource-group "$dns_group" --zone-name "$zone" --output table
  done < <(jq -r '.[].name' <<<"$zones")
  az_cli policy state list --filter "PolicyAssignmentId eq '$assignment' and ComplianceState eq 'NonCompliant'" \
    --query '[].{reference:policyDefinitionReferenceId,resource:resourceId,state:complianceState}' --output table
}

verify() {
  foundation_outputs
  local manifest clients endpoint vm result fqdn ip
  manifest=$(terraform -chdir="$(module_dir samples)" output -json endpoints)
  jq -e 'type == "object" and length > 0' <<<"$manifest" >/dev/null || fail "No sample endpoints in state"
  printf '%s\n' "$manifest" > "$work_dir/endpoints.json"
  timeout "$command_timeout" bash "$script_dir/../tests/verify-live.sh" "$subscription" "$dns_group" \
    "$(jq -r '.vnet_ids.value.hub' <<<"$foundation")" "$work_dir/endpoints.json" --metadata-only
  clients=$(terraform -chdir="$(module_dir clients)" output -json clients)
  jq -e 'has("spoke1") and has("spoke2")' <<<"$clients" >/dev/null || fail "Both optional client VMs must be deployed"
  local spoke key
  for spoke in spoke1 spoke2; do
    vm=$(jq -r --arg spoke "$spoke" '.[$spoke].name' <<<"$clients")
    while IFS= read -r key; do
      endpoint=$(jq -c --arg key "$key" '.[$key]' <<<"$manifest")
      fqdn=$(jq -r '.fqdn' <<<"$endpoint")
      ip=$(jq -r '.private_ip' <<<"$endpoint")
      log "Checking $fqdn from $spoke via Run Command"
      result=$(az_cli vm run-command invoke --resource-group "$network_group" --name "$vm" \
        --command-id RunShellScript --scripts "@$script_dir/resolve.sh" --parameters "$fqdn" "$ip" --output json)
      jq -e --arg marker "DNS_DEMO_PASS $fqdn $ip" '
        any(.value[]; (.code | endswith("/StdOut/succeeded")) and
          ((.message | split("\n") | index($marker)) != null))
      ' <<<"$result" >/dev/null || { printf '%s\n' "$result" >&2; fail "Guest DNS check failed in $spoke"; }
      log "PASS: $spoke: $fqdn -> $ip"
    done < <(jq -r 'keys[]' <<<"$manifest")
  done
}

test_deny() {
  foundation_outputs
  local current zones result zone="denied.$prefix.demo.internal"
  current=$(az_cli policy assignment show --name "${assignment##*/}" --scope "/subscriptions/$subscription" --output json)
  jq -e '.parameters.denyEffect.value == "Deny" and .enforcementMode != "DoNotEnforce"' <<<"$current" >/dev/null ||
    fail "Apply enforce_zone_location=true first; Audit is not a Deny test"
  zones=$(az_cli network private-dns zone list --resource-group "$network_group" --output json)
  jq -e --arg zone "$zone" 'all(.[]; .name != $zone)' <<<"$zones" >/dev/null || fail "Test zone already exists; refusing to overwrite it"
  confirm TEST-DENY
  if result=$(az_cli network private-dns zone create --resource-group "$network_group" --name "$zone" --output json 2>&1); then
    az_cli network private-dns zone delete --resource-group "$network_group" --name "$zone" --yes
    fail "The test zone was unexpectedly allowed and has been deleted. Wait for assignment propagation and investigate."
  fi
  [[ "$result" == *"RequestDisallowedByPolicy"* && "${result,,}" == *"${assignment,,}"* ]] ||
    fail "Creation failed for a different reason, not the expected assignment: $result"
  log "PASS: this demo's assignment denied zone creation outside the shared resource group"
}

cleanup_dns() {
  foundation_outputs
  local endpoints vms tasks name state zones zone records
  endpoints=$(az_cli network private-endpoint list --resource-group "$network_group" --output json)
  vms=$(az_cli vm list --resource-group "$network_group" --output json)
  jq -e 'length == 0' <<<"$endpoints" >/dev/null || fail "Destroy samples first; endpoints still exist"
  jq -e 'length == 0' <<<"$vms" >/dev/null || fail "Destroy clients first; VMs still exist"
  zones=$(az_cli network private-dns zone list --resource-group "$dns_group" --output json)
  jq -e --arg prefix "$prefix" '
    all(.[]; (.name == "privatelink.blob.core.windows.net" or .name == "privatelink.vaultcore.azure.net") and
      .tags.workload == "central-private-dns" and .tags["demo-prefix"] == $prefix)
  ' <<<"$zones" >/dev/null || fail "Unexpected/unowned DNS zones found; inspect them manually. Nothing was deleted."
  while IFS= read -r zone; do
    [[ -n "$zone" ]] || continue
    records=$(az_cli network private-dns record-set list --resource-group "$dns_group" --zone-name "$zone" --output json)
    jq -e 'all(.[]; (.type | ascii_downcase) == "microsoft.network/privatednszones/soa")' <<<"$records" >/dev/null ||
      fail "$zone still contains non-SOA records; inspect rather than deleting records blindly"
  done < <(jq -r '.[].name' <<<"$zones")
  log "Only empty, tagged demo service zones will be deleted from $dns_group."
  confirm CLEANUP-DNS
  tasks=$(az_cli policy remediation list --output json)
  tasks=$(jq -c --arg id "$assignment" '[.[] | select((.policyAssignmentId | ascii_downcase) == ($id | ascii_downcase))]' <<<"$tasks")
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    state=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .provisioningState' <<<"$tasks")
    case "$state" in
      Running|Accepted|Evaluating)
        az_cli policy remediation cancel --name "$name" --output none
        wait_remediation "$name" true
        ;;
      Cancelling) wait_remediation "$name" true ;;
      Complete|Succeeded|Canceled|Failed) ;;
      *) fail "Unknown remediation state for cleanup: $state" ;;
    esac
    az_cli policy remediation delete --name "$name"
  done < <(jq -r '.[].name' <<<"$tasks")
  while IFS= read -r zone; do
    [[ -n "$zone" ]] || continue
    az_cli network private-dns zone delete --resource-group "$dns_group" --name "$zone" --yes
  done < <(jq -r '.[].name' <<<"$zones")
  log "Demo DNS zones removed. Review a foundation destroy plan next; do not bypass non-empty-group safety."
}

main() {
  local action=${1:-help} root
  case "$action" in
    help|-h|--help) usage; return ;;
    configure)
      [[ $# -ge 2 && $# -le 4 ]] || fail "configure needs SUBSCRIPTION_ID [PREFIX] [REGION]"
      command -v jq >/dev/null || fail "Missing jq"
      configure "${@:2}"
      return
      ;;
    plan|apply|plan-destroy|destroy)
      [[ $# -eq 2 ]] || fail "$action needs exactly one root"
      root=$2
      module_dir "$root" >/dev/null
      ;;
    preflight|register-providers|seed-zone|remediate|status|verify|test-deny|cleanup-dns)
      [[ $# -eq 1 ]] || fail "$action takes no arguments"
      ;;
    *) fail "Unknown command: $action (use help)" ;;
  esac
  need_tools
  load_config
  check_account
  case "$action" in
    preflight) preflight ;;
    register-providers)
      confirm REGISTER-PROVIDERS
      local namespace
      for namespace in Microsoft.Network Microsoft.Authorization Microsoft.ManagedIdentity Microsoft.PolicyInsights Microsoft.Storage Microsoft.KeyVault Microsoft.Compute; do
        az_cli provider register --namespace "$namespace" --wait
      done
      ;;
    plan) plan_root "$root" deploy ;;
    plan-destroy) plan_root "$root" destroy ;;
    apply) apply_root "$root" deploy ;;
    destroy) apply_root "$root" destroy ;;
    seed-zone) seed_zone ;;
    remediate) remediate ;;
    status) status ;;
    verify) verify ;;
    test-deny) test_deny ;;
    cleanup-dns) cleanup_dns ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
