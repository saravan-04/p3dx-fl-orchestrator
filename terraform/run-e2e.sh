#!/usr/bin/env bash
#
# run-e2e.sh — continuous, non-interactive, one command: creates a fresh
# orchestrator VM + data-provider VM(s) via participant-vm, then
# immediately provisions server/client/session on them via
# flotilla-provision. No pause, no confirmation prompt in between.
#
# Usage:
#   ./run-e2e.sh                          # orchestrator=e2e-orch, 1 data provider=e2e-dp1
#   ./run-e2e.sh myorch dp1 dp2 dp3        # custom names, any number of data providers
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ORCH_NAME="${1:-e2e-orch}"
[[ $# -gt 0 ]] && shift
DP_NAMES=("$@")
if [[ ${#DP_NAMES[@]} -eq 0 ]]; then
  DP_NAMES=(e2e-dp1)
fi

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_INFO=$'\033[36m'
say() { printf '%s\n' "${C_INFO}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }

command -v terraform >/dev/null 2>&1 || { echo "terraform not found" >&2; exit 1; }
command -v az >/dev/null 2>&1 || { echo "azure-cli not found" >&2; exit 1; }

say "Checking Azure login"
if ! az account show >/dev/null 2>&1; then
  az login --use-device-code
fi
SUB_ID="$(az account show --query id -o tsv)"
echo "  using subscription $SUB_ID"

say "Creating orchestrator VM ($ORCH_NAME)"
(
  cd participant-vm
  terraform init -input=false >/dev/null
  terraform workspace select -or-create "$ORCH_NAME"
  terraform apply -auto-approve -input=false \
    -var "role=user" \
    -var "participant_name=$ORCH_NAME" \
    -var "subscription_id=$SUB_ID"
)

for dp in "${DP_NAMES[@]}"; do
  say "Creating data-provider VM ($dp)"
  (
    cd participant-vm
    terraform workspace select -or-create "$dp"
    terraform apply -auto-approve -input=false \
      -var "role=data-provider" \
      -var "participant_name=$dp" \
      -var "subscription_id=$SUB_ID"
  )
done

# Build a Terraform list literal like ["dp1","dp2"] from DP_NAMES.
DP_LIST_TF="["
for i in "${!DP_NAMES[@]}"; do
  [[ $i -gt 0 ]] && DP_LIST_TF+=","
  DP_LIST_TF+="\"${DP_NAMES[$i]}\""
done
DP_LIST_TF+="]"

say "Provisioning server/client/session (flotilla-provision)"
(
  cd flotilla-provision
  terraform init -input=false >/dev/null
  terraform apply -auto-approve -input=false \
    -var "subscription_id=$SUB_ID" \
    -var "orchestrator_participant_name=$ORCH_NAME" \
    -var "data_provider_participant_names=$DP_LIST_TF"
  echo
  say "Done — status"
  terraform output
)
