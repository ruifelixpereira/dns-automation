#!/usr/bin/env bash
set -euo pipefail
trap 'printf "FAIL: command failed at line %s\n" "$LINENO" >&2' ERR

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 4 || ( $# -eq 5 && "$5" == "--metadata-only" ) ]] ||
  fail "Usage: bash verify-live.sh SUBSCRIPTION_ID DNS_RESOURCE_GROUP HUB_VNET_ID ENDPOINTS_JSON [--metadata-only]"
subscription=$1
dns_group=$2
hub_id=$3
manifest=$4
metadata_only=false
if [[ $# -eq 5 ]]; then metadata_only=true; fi

tools=(az jq awk)
if [[ "$metadata_only" == "false" ]]; then tools+=(dig); fi
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"
done
[[ -r "$manifest" ]] || fail "Cannot read endpoint manifest: $manifest"

jq -e '
  type == "object" and length > 0 and
  all(.[]; (.id | type == "string") and (.name | type == "string") and
    (.fqdn | type == "string") and (.zone_id | type == "string") and
    (.private_ip | type == "string") and
    (.private_ip | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.service == "blob" or .service == "vault"))
' "$manifest" >/dev/null || fail "Manifest must contain provisioned Blob/Key Vault endpoints with IPs and zone IDs"

mapfile -t endpoint_keys < <(jq -r 'keys[]' "$manifest")
for key in "${endpoint_keys[@]}"; do
  endpoint=$(jq -c --arg key "$key" '.[$key]' "$manifest")
  endpoint_id=$(jq -r '.id' <<<"$endpoint")
  endpoint_name=$(jq -r '.name' <<<"$endpoint")
  endpoint_group=$(jq -r '.id | split("/")[4]' <<<"$endpoint")
  endpoint_subscription=$(jq -r '.id | split("/")[2]' <<<"$endpoint")
  fqdn=$(jq -r '.fqdn' <<<"$endpoint")
  expected_ip=$(jq -r '.private_ip' <<<"$endpoint")
  zone_id=$(jq -r '.zone_id' <<<"$endpoint")
  zone_name=${zone_id##*/}
  record_name=${fqdn%%.*}

  [[ "${endpoint_subscription,,}" == "${subscription,,}" ]] || fail "$key belongs to a different subscription"
  expected_zone_prefix="/subscriptions/$subscription/resourceGroups/$dns_group/providers/Microsoft.Network/privateDnsZones/"
  [[ "${zone_id,,}" == "${expected_zone_prefix,,}"* ]] || fail "$key references a zone outside the shared DNS resource group"

  groups=$(az network private-endpoint dns-zone-group list \
    --subscription "$subscription" --resource-group "$endpoint_group" \
    --endpoint-name "$endpoint_name" --output json)
  jq -e --arg zone "$zone_id" '
    length == 1 and any(.[0].privateDnsZoneConfigs[];
      (.privateDnsZoneId | ascii_downcase) == ($zone | ascii_downcase))
  ' <<<"$groups" >/dev/null || fail "$key lacks the exact shared-zone association ($endpoint_id)"

  links=$(az network private-dns link vnet list \
    --subscription "$subscription" --resource-group "$dns_group" \
    --zone-name "$zone_name" --output json)
  jq -e --arg hub "$hub_id" '
    length == 1 and
    (.[0].virtualNetwork.id | ascii_downcase) == ($hub | ascii_downcase) and
    .[0].registrationEnabled == false
  ' <<<"$links" >/dev/null || fail "$zone_name must have only a non-registering hub link"

  record=$(az network private-dns record-set a show \
    --subscription "$subscription" --resource-group "$dns_group" \
    --zone-name "$zone_name" --name "$record_name" --output json)
  jq -e --arg ip "$expected_ip" '
    [.aRecords[].ipv4Address] == [$ip]
  ' <<<"$record" >/dev/null || fail "$fqdn does not have exactly the expected A record $expected_ip"

  if [[ "$metadata_only" == "false" ]]; then
    resolved=$(dig +time=5 +tries=1 +noall +answer "$fqdn" A | awk '$4 == "A" {print $5}')
    [[ "$resolved" == "$expected_ip" ]] || fail "System DNS resolved $fqdn to '$resolved', expected '$expected_ip'"
  fi
  if [[ "$metadata_only" == "true" ]]; then
    printf 'PASS: Azure metadata for %s; expected IP %s; DNS not checked\n' "$fqdn" "$expected_ip"
  else
    printf 'PASS: %s -> %s; exact shared zone and non-registering hub link\n' "$fqdn" "$expected_ip"
  fi
done

if [[ "$metadata_only" == "true" ]]; then
  printf 'PASS: %s endpoint(s) Azure metadata validated. Client DNS was not checked.\n' "${#endpoint_keys[@]}"
else
  printf 'PASS: %s endpoint(s) validated from this client. Repeat from the other spoke.\n' "${#endpoint_keys[@]}"
fi
