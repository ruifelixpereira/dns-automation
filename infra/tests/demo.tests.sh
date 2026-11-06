#!/usr/bin/env bash
set -Eeuo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/demo.sh
source "$test_dir/../scripts/demo.sh"
real_script_dir=$script_dir
temporary=$(mktemp -d)
infra_dir="$temporary/infra"
work_dir="$infra_dir/.demo"
subscription="11111111-1111-1111-1111-111111111111"
prefix=dnsdemo
mkdir -p "$work_dir" "$infra_dir/examples/private-endpoints" "$infra_dir/examples/dns-clients"
cleanup() {
  rm -f -- "$work_dir/test.tfplan" "$work_dir/test.receipt.json" "$work_dir/endpoints.json" \
    "$infra_dir/demo.tfvars.json" "$infra_dir/terraform.tfstate" \
    "$infra_dir/examples/private-endpoints/terraform.tfstate" \
    "$temporary/deleted" "$temporary/getent"
  rmdir "$work_dir" "$infra_dir/examples/private-endpoints" "$infra_dir/examples/dns-clients" \
    "$infra_dir/examples" "$infra_dir" "$temporary"
}
trap cleanup EXIT

run_case() {
  local name=$1 expected=$2 output code
  if output=$("$name" 2>&1); then code=0; else code=$?; fi
  if [[ "$expected" == pass ]]; then
    [[ $code == 0 ]] || fail "$name unexpectedly failed: $output"
  else
    [[ $code != 0 && "$output" == *"$expected"* ]] || fail "$name failed incorrectly: $output"
  fi
  printf 'PASS: %s\n' "$name"
}

setup_plan() {
  printf '{"subscription_id":"%s"}\n' "$subscription" > "$infra_dir/demo.tfvars.json"
  printf 'mock binary plan\n' > "$work_dir/test.tfplan"
  jq -n --arg sub "$subscription" --arg prefix "$prefix" --arg operation "${1:-deploy}" \
    --arg hash "$(sha256sum "$work_dir/test.tfplan" | awk '{print $1}')" \
    --arg config "$(config_fingerprint foundation)" \
    '{subscription:$sub,prefix:$prefix,root:"foundation",operation:$operation,plan_sha256:$hash,config_sha256:$config}' \
    > "$work_dir/test.receipt.json"
}
terraform() {
  [[ "$*" == *"show -json"* ]] || fail "Unexpected Terraform invocation: $*"
  printf '%s\n' "$plan_document"
}
validate_plan() {
  check_plan foundation "${1:-deploy}" "$work_dir/test.tfplan" "$work_dir/test.receipt.json"
}
valid_plan() { setup_plan; plan_document='{"resource_changes":[{"change":{"actions":["create"]}}]}'; validate_plan; }
tampered_plan() { setup_plan; printf 'tampered\n' >> "$work_dir/test.tfplan"; validate_plan; }
stale_config() { setup_plan; printf '{}\n' > "$infra_dir/demo.tfvars.json"; validate_plan; }
replacement_plan() { setup_plan; plan_document='{"resource_changes":[{"change":{"actions":["delete","create"]}}]}'; validate_plan; }
wrong_subscription() { setup_plan; subscription="22222222-2222-2222-2222-222222222222"; validate_plan; }
wrong_root() { setup_plan; check_plan samples deploy "$work_dir/test.tfplan" "$work_dir/test.receipt.json"; }
valid_destroy() { setup_plan destroy; plan_document='{"resource_changes":[{"change":{"actions":["delete"]}}]}'; validate_plan destroy; }
unsafe_destroy() { setup_plan destroy; plan_document='{"resource_changes":[{"change":{"actions":["update"]}}]}'; validate_plan destroy; }
confirmation_blocks_apply() {
  foundation_outputs() { :; }
  check_plan() { :; }
  terraform() {
    [[ "$*" != *" apply "* ]] || fail "UNSAFE: apply was called"
  }
  apply_root foundation deploy <<< "not approved"
}
run_case valid_plan pass
run_case tampered_plan 'Plan receipt/config mismatch'
run_case stale_config 'Plan receipt/config mismatch'
run_case replacement_plan 'Deploy plan includes deletion/replacement'
run_case wrong_subscription 'Plan receipt/config mismatch'
run_case wrong_root 'Plan receipt/config mismatch'
run_case valid_destroy pass
run_case unsafe_destroy 'Destroy plan contains unexpected'
run_case confirmation_blocks_apply 'Confirmation did not match'

remediation_success() {
  az_cli() { printf '{"provisioningState":"Succeeded","deploymentStatus":{"totalDeployments":2,"successfulDeployments":2,"failedDeployments":0}}\n'; }
  wait_remediation mock
}
remediation_failed_deployment() {
  az_cli() { printf '{"provisioningState":"Complete","deploymentStatus":{"totalDeployments":2,"successfulDeployments":1,"failedDeployments":1}}\n'; }
  wait_remediation mock
}
remediation_missing_counts() {
  az_cli() { printf '{"provisioningState":"Complete"}\n'; }
  wait_remediation mock
}
remediation_failed_task() {
  az_cli() { printf '{"provisioningState":"Failed"}\n'; }
  wait_remediation mock
}
remediation_timeout() {
  az_cli() { printf '{"provisioningState":"Running"}\n'; }
  sleep() { wait_timeout=0; }
  wait_remediation mock
}
remediation_order() {
  foundation_outputs() {
    foundation='{"policy_reference_ids":{"value":{"zones":["create-zone-blob","create-zone-vault"],"links":["link-zone-hub"],"groups":["create-group-blob","create-group-vault"]}}}'
    assignment="/subscriptions/$subscription/providers/Microsoft.Authorization/policyAssignments/$prefix-central-dns"
  }
  confirm() { :; }
  az_cli() {
    [[ "$1 $2 $3" == "policy remediation create" ]] || fail "Unexpected command: $*"
    printf 'CREATE %s\n' "$*"
  }
  wait_remediation() { printf 'WAIT %s\n' "$1"; }
  local result events expected
  result=$(remediate)
  events=$(printf '%s\n' "$result" | awk '/^CREATE/ {print "create"} /^WAIT/ {print "wait"}')
  expected=$(printf 'create\nwait\ncreate\nwait\ncreate\nwait\ncreate\nwait\ncreate\nwait')
  [[ "$events" == "$expected" ]] || fail "Tasks were not awaited individually"
  [[ "$result" == *"Stage zones: create-zone-blob"*"Stage zones: create-zone-vault"*"Stage links: link-zone-hub"*"Stage groups: create-group-blob"*"Stage groups: create-group-vault"* ]] ||
    fail "Wrong remediation stage order"
}
missing_alias() {
  az_cli() {
    if [[ "$*" == *"--expand"* ]]; then printf '{"resourceTypes":[]}\n'; else printf 'Registered\n'; fi
  }
  preflight
}
wrong_foundation() {
  printf '{}\n' > "$infra_dir/terraform.tfstate"
  terraform() { printf '{"subscription_id":{"value":"different"},"name_prefix":{"value":"dnsdemo"}}\n'; }
  foundation_outputs
}
run_case remediation_success pass
run_case remediation_failed_deployment 'failed/incomplete deployments'
run_case remediation_missing_counts 'failed/incomplete deployments'
run_case remediation_failed_task 'failed; inspect ARM'
run_case remediation_timeout 'timed out'
run_case remediation_order pass
run_case missing_alias 'Required policy alias is not published'
run_case wrong_foundation 'different subscription or prefix'

mock_foundation() {
  dns_group=rg-dnsdemo-dns
  network_group=rg-dnsdemo-network
  assignment="/subscriptions/$subscription/providers/Microsoft.Authorization/policyAssignments/$prefix-central-dns"
}
deny_result() {
  foundation_outputs() { mock_foundation; }
  confirm() { :; }
  az_cli() {
    case "$1 $2 $3" in
      "policy assignment show") printf '{"parameters":{"denyEffect":{"value":"Deny"}},"enforcementMode":"Default"}\n' ;;
      "network private-dns zone")
        case "$4" in
          list) printf '[]\n' ;;
          create) printf '%s\n' "$denial" >&2; return 1 ;;
          *) fail "Unexpected mutation: $*" ;;
        esac ;;
      *) fail "Unexpected command: $*" ;;
    esac
  }
  test_deny
}
correct_deny() { denial="RequestDisallowedByPolicy /subscriptions/$subscription/providers/Microsoft.Authorization/policyAssignments/$prefix-central-dns"; deny_result; }
rbac_is_not_deny() { denial=AuthorizationFailed; deny_result; }
other_policy_is_not_deny() { denial="RequestDisallowedByPolicy /subscriptions/$subscription/providers/Microsoft.Authorization/policyAssignments/other"; deny_result; }
run_case correct_deny pass
run_case rbac_is_not_deny 'different reason'
run_case other_policy_is_not_deny 'different reason'

unsafe_cleanup() {
  foundation_outputs() { mock_foundation; }
  az_cli() {
    case "$1 $2 $3" in
      "network private-endpoint list"|"vm list --resource-group") printf '[]\n' ;;
      "network private-dns zone") printf '%s\n' "$cleanup_zones" ;;
      "network private-dns record-set") printf '[{"type":"Microsoft.Network/privateDnsZones/A"}]\n' ;;
      *) printf 'mutation\n' > "$temporary/deleted"; fail "UNSAFE mutation: $*" ;;
    esac
  }
  cleanup_dns
}
unowned_zone() { cleanup_zones='[{"name":"unrelated.internal","tags":{}}]'; unsafe_cleanup; }
populated_zone() { cleanup_zones='[{"name":"privatelink.blob.core.windows.net","tags":{"workload":"central-private-dns","demo-prefix":"dnsdemo"}}]'; unsafe_cleanup; }
child_state_blocks_foundation() {
  printf '{}\n' > "$infra_dir/examples/private-endpoints/terraform.tfstate"
  foundation_outputs() { mock_foundation; }
  terraform() { printf 'azurerm_private_endpoint.sample\n'; }
  check_foundation_teardown
}
active_task_blocks_foundation() {
  foundation_outputs() { mock_foundation; }
  terraform() { :; }
  az_cli() {
    case "$1 $2 $3" in
      "network private-dns zone") printf '[]\n' ;;
      "policy remediation list") jq -n --arg id "$assignment" '[{policyAssignmentId:$id,provisioningState:"Running"}]' ;;
      *) fail "Unexpected command: $*" ;;
    esac
  }
  check_foundation_teardown
}
run_case unowned_zone 'Unexpected/unowned DNS zones'
run_case populated_zone 'still contains non-SOA records'
[[ ! -e "$temporary/deleted" ]] || fail "Unsafe cleanup made a mutation"
run_case child_state_blocks_foundation 'Destroy the samples root'
run_case active_task_blocks_foundation 'active remediation tasks'

verify_guests() {
  foundation_outputs() {
    mock_foundation
    foundation='{"vnet_ids":{"value":{"hub":"/hub"}}}'
  }
  terraform() {
    if [[ "$*" == *"output -json clients" ]]; then
      printf '{"spoke1":{"name":"vm-spoke1"},"spoke2":{"name":"vm-spoke2"}}\n'
    else
      jq . "$test_dir/fixtures/sample-endpoints.json"
    fi
  }
  timeout() {
    [[ "$2" == bash && "$*" == *"--metadata-only"* ]] || fail "Unexpected metadata command"
  }
  az_cli() {
    [[ "$1 $2 $3" == "vm run-command invoke" ]] || fail "Unexpected guest command"
    while [[ $# -gt 0 && "$1" != "--parameters" ]]; do shift; done
    [[ $# -ge 3 ]] || fail "Missing positional guest parameters"
    local marker="DNS_DEMO_PASS $2 $3"
    case "$guest_result" in
      missing) marker="guest command failed" ;;
      wrong_ip) marker="${marker}0" ;;
    esac
    jq -n --arg marker "$marker" '{value:[{code:"ComponentStatus/StdOut/succeeded",message:($marker+"\n")}]}'
  }
  verify
}
both_spokes_verified() {
  guest_result=success
  local result
  result=$(verify_guests)
  [[ "$result" == *"PASS: spoke1:"*"PASS: spoke2:"* ]] || fail "Both spokes were not checked"
}
cli_success_is_not_guest_success() { guest_result=missing; verify_guests; }
marker_must_match_exact_ip() { guest_result=wrong_ip; verify_guests; }
run_case both_spokes_verified pass
run_case cli_success_is_not_guest_success 'Guest DNS check failed'
run_case marker_must_match_exact_ip 'Guest DNS check failed'

# Run the POSIX guest script with a fake resolver, never the host's DNS.
cat > "$temporary/getent" <<'GUEST'
#!/bin/sh
case "$MOCK_DNS" in
  correct) printf '10.41.1.4 STREAM\n10.41.1.4 DGRAM\n' ;;
  wrong) printf '203.0.113.1 STREAM\n' ;;
  multiple) printf '10.41.1.4 STREAM\n10.41.1.5 STREAM\n' ;;
  error) exit 2 ;;
esac
GUEST
chmod +x "$temporary/getent"
guest_correct() { MOCK_DNS=correct PATH="$temporary:$PATH" sh "$real_script_dir/resolve.sh" sample.blob.core.windows.net 10.41.1.4; }
guest_wrong() { MOCK_DNS=wrong PATH="$temporary:$PATH" sh "$real_script_dir/resolve.sh" sample.blob.core.windows.net 10.41.1.4; }
guest_multiple() { MOCK_DNS=multiple PATH="$temporary:$PATH" sh "$real_script_dir/resolve.sh" sample.blob.core.windows.net 10.41.1.4; }
guest_failure() { MOCK_DNS=error PATH="$temporary:$PATH" sh "$real_script_dir/resolve.sh" sample.blob.core.windows.net 10.41.1.4; }
run_case guest_correct pass
run_case guest_wrong 'expected 10.41.1.4'
run_case guest_multiple 'expected 10.41.1.4'
run_case guest_failure 'system DNS could not resolve'
