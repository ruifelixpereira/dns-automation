#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf 'FAIL: expected FQDN and private IP\n' >&2
  exit 1
fi

fqdn=$1
expected_ip=$2
if ! addresses=$(getent ahostsv4 "$fqdn"); then
  printf 'FAIL: system DNS could not resolve %s\n' "$fqdn" >&2
  exit 1
fi
resolved=$(printf '%s\n' "$addresses" | awk '{print $1}' | sort -u)
if [ "$resolved" != "$expected_ip" ]; then
  printf 'FAIL: %s resolved to %s, expected %s\n' "$fqdn" "$resolved" "$expected_ip" >&2
  exit 1
fi
printf 'DNS_DEMO_PASS %s %s\n' "$fqdn" "$expected_ip"
