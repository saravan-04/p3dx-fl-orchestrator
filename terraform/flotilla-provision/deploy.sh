#!/usr/bin/env bash
#
# deploy.sh — friendly wrapper around `terraform init/plan/apply` for
# flotilla-provision. Non-interactive by default: once `az login` succeeds
# it runs straight through plan -> apply with no confirmation prompt,
# provisioning the (already-existing) orchestrator + data-provider VMs via
# Azure Custom Script Extensions (no SSH needed), waiting for clients, then
# starting the FL session. Takes ~15-20 minutes end to end.
#
# Usage:
#   ./deploy.sh              # login (if needed), init, plan, apply — no
#                             # confirmation prompt, runs straight through
#   ./deploy.sh --confirm    # ask "Apply this plan? [y/N]" before applying
#   ./deploy.sh --destroy    # remove the extensions/NSG rule this created
#                             # (does NOT delete the underlying VMs — those
#                             # belong to terraform/participant-vm's own
#                             # state). Always asks unless --yes too.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'

say()  { printf '%s\n' "${C_INFO}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()   { printf '%s\n' "  ${C_OK}ok${C_RESET}   $*"; }
warn() { printf '%s\n' "  ${C_WARN}warn${C_RESET} $*"; }
die()  { printf '%s\n' "  ${C_ERR}error${C_RESET} $*" >&2; exit 1; }

run() {
  printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_RESET"
  "$@"
}

CONFIRM=false
DESTROY_YES=false
ACTION=apply
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)  CONFIRM=true; shift ;;
    --yes|-y)   DESTROY_YES=true; shift ;;
    --destroy)  ACTION=destroy; shift ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

say "Checking prerequisites"
command -v terraform >/dev/null 2>&1 || die "terraform not found. Install: https://developer.hashicorp.com/terraform/install"
ok "terraform $(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1)"

command -v az >/dev/null 2>&1 || die "azure-cli not found. Install: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
ok "azure-cli $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo '?')"

[[ -f terraform.tfvars ]] || die "terraform.tfvars not found. Run: cp terraform.tfvars.example terraform.tfvars, then edit it."
ok "terraform.tfvars present"

say "Checking Azure login"
if ! az account show >/dev/null 2>&1; then
  warn "not logged in — opening device-code login"
  run az login --use-device-code
fi
ACCOUNT_NAME="$(az account show --query name -o tsv)"
ACCOUNT_SUB="$(az account show --query id -o tsv)"
ok "logged in as: $ACCOUNT_NAME"
ok "active subscription: $ACCOUNT_SUB"
warn "make sure this matches subscription_id in terraform.tfvars — and that it's the subscription your orchestrator/data-provider VMs already exist in."

say "Initializing Terraform"
run terraform init -input=false
ok "initialized"

if [[ "$ACTION" == "destroy" ]]; then
  say "Planning destroy"
  run terraform plan -destroy -out=tfplan.destroy -input=false
  if [[ "$DESTROY_YES" != "true" ]]; then
    read -r -p "  Remove the provisioning extensions + NSG rule this created (VMs themselves are untouched)? [y/N] " reply
    [[ "${reply,,}" == "y" ]] || { warn "aborted"; rm -f tfplan.destroy; exit 0; }
  fi
  say "Destroying"
  run terraform apply -input=false tfplan.destroy
  rm -f tfplan.destroy
  ok "destroyed"
  exit 0
fi

say "Planning (nothing runs yet)"
run terraform plan -out=tfplan -input=false
ok "plan ready"

if [[ "$CONFIRM" == "true" ]]; then
  read -r -p "  Provision the server/client(s) shown above and run the FL session end to end? [y/N] " reply
  [[ "${reply,,}" == "y" ]] || { warn "aborted"; rm -f tfplan; exit 0; }
fi

say "Provisioning — this normally takes 15-20 minutes (each VM installs Docker, clones and builds Flotilla from source, then waits for clients and runs a real FL session)"
run terraform apply -input=false tfplan
rm -f tfplan
ok "done"

echo
say "Status"
terraform output
