#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
subscription="11111111-1111-1111-1111-111111111111"
dns_group="rg-demo-dns"
hub_id="/subscriptions/$subscription/resourceGroups/rg-demo-network/providers/Microsoft.Network/virtualNetworks/vnet-demo-hub"
zone_id="/subscriptions/$subscription/resourceGroups/$dns_group/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
export hub_id zone_id

az() {
  case "$1 $2 $3" in
    "network private-endpoint dns-zone-group")
      if [[ "$TEST_SCENARIO" == "command_error" ]]; then
        printf 'Azure read failed\n' >&2
        return 1
      fi
      local zone=$zone_id
      [[ "$TEST_SCENARIO" != "wrong_zone" ]] || zone="${zone_id}wrong"
      jq -n --arg zone "$zone" '[{privateDnsZoneConfigs: [{privateDnsZoneId: $zone}]}]'
      ;;
    "network private-dns link")
      local registration=false
      [[ "$TEST_SCENARIO" != "registration_enabled" ]] || registration=true
      jq -n --arg hub "$hub_id" --argjson registration "$registration" \
        '[{virtualNetwork: {id: $hub}, registrationEnabled: $registration}]'
      ;;
    "network private-dns record-set")
      local ip="10.41.1.4"
      [[ "$TEST_SCENARIO" != "wrong_record" ]] || ip="10.41.1.5"
      jq -n --arg ip "$ip" '{aRecords: [{ipv4Address: $ip}]}'
      ;;
    *)
      printf 'Unexpected Azure command: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

dig() {
  local ip="10.41.1.4"
  [[ "$TEST_SCENARIO" != "public_dns" ]] || ip="203.0.113.10"
  printf 'stdemo.blob.core.windows.net. 10 IN A %s\n' "$ip"
}

export -f az dig

for scenario in success wrong_zone registration_enabled wrong_record public_dns command_error; do
  if result=$(TEST_SCENARIO="$scenario" bash "$test_dir/verify-live.sh" \
    "$subscription" "$dns_group" "$hub_id" "$test_dir/fixtures/sample-endpoints.json" 2>&1); then
    [[ "$scenario" == "success" ]] || {
      printf 'FAIL: %s incorrectly succeeded\n%s\n' "$scenario" "$result" >&2
      exit 1
    }
    [[ "$result" == *"PASS: 1 endpoint(s) validated"* ]] || {
      printf 'FAIL: success omitted its verification summary\n%s\n' "$result" >&2
      exit 1
    }
  else
    [[ "$scenario" != "success" && "$result" == *"FAIL:"* ]] || {
      printf 'FAIL: %s lacked the expected explicit failure\n%s\n' "$scenario" "$result" >&2
      exit 1
    }
  fi
  printf 'PASS: %s\n' "$scenario"
done

result=$(TEST_SCENARIO=public_dns bash "$test_dir/verify-live.sh" \
  "$subscription" "$dns_group" "$hub_id" "$test_dir/fixtures/sample-endpoints.json" --metadata-only)
[[ "$result" == *"Client DNS was not checked"* ]] || {
  printf 'FAIL: metadata-only mode must explicitly report skipped client DNS\n' >&2
  exit 1
}
printf 'PASS: metadata_only_reports_skipped_dns\n'

if result=$(TEST_SCENARIO=wrong_zone bash "$test_dir/verify-live.sh" \
  "$subscription" "$dns_group" "$hub_id" "$test_dir/fixtures/sample-endpoints.json" --metadata-only 2>&1); then
  printf 'FAIL: metadata-only mode accepted the wrong zone\n' >&2
  exit 1
fi
[[ "$result" == *"lacks the exact shared-zone association"* ]] || {
  printf 'FAIL: unexpected metadata-only failure\n%s\n' "$result" >&2
  exit 1
}
printf 'PASS: metadata_only_rejects_wrong_zone\n'
