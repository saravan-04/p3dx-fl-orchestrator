#!/bin/bash
# Runs LOCALLY, on whatever machine executes `terraform apply` — not on the
# VM (see README's "broker_host wiring" section for why: gov_layer is
# normally only reachable at localhost:8083 on that machine, not from an
# Azure VM). Called by data.external.output_owner (only for role =
# "data-provider") to find the current output-owner's IP so
# cloud-init.sh.tftpl can point the client at it. Must ALWAYS exit 0 with
# valid JSON (an "external" data source failure would fail terraform apply
# entirely) — an empty ip_address just means no output-owner is registered
# yet, or gov_layer is unreachable; wait_for_combine_fl's script turns that
# into a WARNING instead of starting the client with nowhere to connect.
set -uo pipefail

GOV_URL="${1:-}"
TOKEN="${2:-}"

auth_header=()
if [ -n "$TOKEN" ]; then
  auth_header=(-H "X-VM-Registry-Token: $TOKEN")
fi

BODY=$(curl -sf -m 10 "${auth_header[@]}" "$GOV_URL/vm-registry/output-owner" 2>/dev/null) || BODY=""

IP=$(printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("vm", {}).get("ip_address", ""))
except Exception:
    print("")
' 2>/dev/null)
IP="${IP//$'\n'/}"

printf '{"ip_address": "%s"}' "$IP"
