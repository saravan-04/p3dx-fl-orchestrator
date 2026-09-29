#!/usr/bin/env bash
#
# deploy.sh — friendly wrapper around `terraform init/plan/apply` for this
# coordinated flotilla-e2e deployment (orchestrator + every data-provider
# VM, one Azure subscription, one apply). Takes ~15-20 minutes end to end:
# each VM installs Docker, builds a torch-based image from source, and the
# orchestrator runs a real 10-round FL session once every client connects.
#
# Usage:
#   ./deploy.sh              # login (if needed), init, plan, apply — no
#                             # confirmation prompt, runs straight through
#   ./deploy.sh --confirm    # ask "Create these VMs? [y/N]" before applying
#   ./deploy.sh --destroy    # tear everything down instead (always asks to
#                             # confirm, unless --yes is also passed)
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

# Deploying is non-interactive by default (per project convention here) —
# once `az login` succeeds, it runs straight through plan -> apply with no
# prompt. --confirm opts back into the "Create these VMs? [y/N]" prompt.
# --destroy is the opposite: always asks unless --yes is also passed, since
# that's a real teardown of whatever this run created.
CONFIRM=false
DESTROY_YES=false
ACTION=apply
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)  CONFIRM=true; shift ;;
    --yes|-y)   DESTROY_YES=true; shift ;;
    --destroy)  ACTION=destroy; shift ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
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

[[ -d ../../../Flotilla_Deployment/src ]] || warn "../../../Flotilla_Deployment not found relative to this directory — set flotilla_source_path in terraform.tfvars if your checkout lives elsewhere."

say "Checking Azure login"
if ! az account show >/dev/null 2>&1; then
  warn "not logged in — opening device-code login"
  run az login --use-device-code
fi
ACCOUNT_NAME="$(az account show --query name -o tsv)"
ACCOUNT_SUB="$(az account show --query id -o tsv)"
ok "logged in as: $ACCOUNT_NAME"
ok "active subscription: $ACCOUNT_SUB"
warn "make sure this matches subscription_id in terraform.tfvars."

export TF_VAR_created_by="$(az account show --query user.name -o tsv 2>/dev/null || echo "$ACCOUNT_SUB")"

say "Initializing Terraform"
run terraform init -input=false
ok "initialized"

if [[ "$ACTION" == "destroy" ]]; then
  say "Planning destroy"
  run terraform plan -destroy -out=tfplan.destroy -input=false
  if [[ "$DESTROY_YES" != "true" ]]; then
    read -r -p "  Destroy every VM created by this run? [y/N] " reply
    [[ "${reply,,}" == "y" ]] || { warn "aborted"; rm -f tfplan.destroy; exit 0; }
  fi
  say "Destroying"
  run terraform apply -input=false tfplan.destroy
  rm -f tfplan.destroy
  ok "destroyed"
  exit 0
fi

say "Planning (nothing is created yet)"
run terraform plan -out=tfplan -input=false
ok "plan ready"

if [[ "$CONFIRM" == "true" ]]; then
  read -r -p "  Create the orchestrator + data-provider VMs shown above, and run the FL session end to end? [y/N] " reply
  [[ "${reply,,}" == "y" ]] || { warn "aborted"; rm -f tfplan; exit 0; }
fi

say "Deploying — this normally takes 15-20 minutes (Docker install, image builds, dataset generation, waiting for clients, then a real FL session)"
run terraform apply -input=false tfplan
rm -f tfplan
ok "done"

echo
say "Connection details"
terraform output
