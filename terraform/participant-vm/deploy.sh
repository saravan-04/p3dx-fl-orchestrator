#!/usr/bin/env bash
#
# deploy.sh — friendly wrapper around `terraform init/plan/apply` for this
# participant-vm config. Shows what's happening and echoes every command it
# runs before running it, instead of leaving you staring at a blank prompt.
#
# Usage:
#   ./deploy.sh              # init, plan, ask to confirm, apply
#   ./deploy.sh --yes        # skip the confirmation prompt
#   ./deploy.sh --destroy    # tear the VM down instead
#
# Set PROVISION_TOKEN (and optionally PROVISION_BACKEND_URL) — printed by the
# FL dashboard's "Get provisioning command" button — to also push live
# progress to your own FL page there. Purely additive: this script still
# creates the VM entirely on its own against your local `az login` session
# either way, and works fine with PROVISION_TOKEN unset.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'

say()  { printf '%s\n' "${C_INFO}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()   { printf '%s\n' "  ${C_OK}ok${C_RESET}   $*"; }
warn() { printf '%s\n' "  ${C_WARN}warn${C_RESET} $*"; }
die()  { printf '%s\n' "  ${C_ERR}error${C_RESET} $*" >&2; exit 1; }

# Echoes a command in full before running it, so it's always visible what's
# actually being executed against your Azure subscription.
run() {
  printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_RESET"
  "$@"
}

# Best-effort status push to the FL dashboard (see terraform/participant-vm
# in the README, and p3dx-aaa's vmProvisioning.service.js on the receiving
# end). Silently does nothing if PROVISION_TOKEN isn't set, curl is missing,
# or the backend is unreachable — this is a visibility nicety, never a
# dependency for actually creating the VM.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
report() {
  [[ -n "${PROVISION_TOKEN:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local step="$1" status="$2" cmd="${3:-}" msg="${4:-}"
  local url="${PROVISION_BACKEND_URL:-http://localhost:3002/p3dx}/vm-provisioning/events"
  local body
  body=$(printf '{"token":"%s","step":"%s","status":"%s","command":"%s","message":"%s"}' \
    "$(json_escape "$PROVISION_TOKEN")" "$(json_escape "$step")" "$(json_escape "$status")" \
    "$(json_escape "$cmd")" "$(json_escape "$msg")")
  curl -s -m 5 -X POST -H 'Content-Type: application/json' -d "$body" "$url" >/dev/null 2>&1 || true
}
[[ -n "${PROVISION_TOKEN:-}" ]] && ok "live status will be pushed to your FL dashboard"
trap 'report "deploy.sh" "error" "" "exited with an error (line $LINENO) — see terminal output above"' ERR

AUTO_YES=false
ACTION=apply
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)   AUTO_YES=true; shift ;;
    --destroy)  ACTION=destroy; shift ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
say "Checking prerequisites"
report "Checking prerequisites" running

command -v terraform >/dev/null 2>&1 || die "terraform not found. Install: https://developer.hashicorp.com/terraform/install"
ok "terraform $(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1)"

command -v az >/dev/null 2>&1 || die "azure-cli not found. Install: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
ok "azure-cli $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo '?')"

[[ -f terraform.tfvars ]] || die "terraform.tfvars not found. Run: cp terraform.tfvars.example terraform.tfvars, then edit it."
ok "terraform.tfvars present"
report "Checking prerequisites" ok

# ---------------------------------------------------------------------------
# 2. Azure login
# ---------------------------------------------------------------------------
say "Checking Azure login"
report "Azure login" running

if ! az account show >/dev/null 2>&1; then
  warn "not logged in — opening device-code login"
  run az login --use-device-code
fi
ACCOUNT_NAME="$(az account show --query name -o tsv)"
ACCOUNT_SUB="$(az account show --query id -o tsv)"
ok "logged in as: $ACCOUNT_NAME"
ok "active subscription: $ACCOUNT_SUB"
warn "make sure this matches subscription_id in terraform.tfvars — az login and this file must agree on whose subscription gets the VM."
report "Azure login" ok "" "signed in as $ACCOUNT_NAME ($ACCOUNT_SUB)"

# The signed-in identity (UPN for a user, appId for a service principal) —
# used to name/tag the VM so it's traceable back to who created it.
IDENTITY="$(az account show --query user.name -o tsv 2>/dev/null || true)"
[[ -n "$IDENTITY" ]] || IDENTITY="$ACCOUNT_SUB"
export TF_VAR_created_by="$IDENTITY"

if grep -qE '^\s*participant_name\s*=' terraform.tfvars 2>/dev/null; then
  ok "participant_name is set explicitly in terraform.tfvars — leaving it as-is"
else
  IDENTITY_SLUG="$(printf '%s' "$IDENTITY" | cut -d'@' -f1 | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-22)"
  [[ -n "$IDENTITY_SLUG" ]] || IDENTITY_SLUG="participant"
  export TF_VAR_participant_name="$IDENTITY_SLUG"
  ok "VM will be named after your Azure identity: $IDENTITY -> participant_name=\"$IDENTITY_SLUG\""
fi

# ---------------------------------------------------------------------------
# 3. Init
# ---------------------------------------------------------------------------
say "Initializing Terraform (downloads the azurerm provider on first run)"
report "Terraform init" running "terraform init -input=false"
run terraform init -input=false
ok "initialized"
report "Terraform init" ok

if [[ "$ACTION" == "destroy" ]]; then
  say "Planning destroy"
  report "Planning destroy" running "terraform plan -destroy -out=tfplan.destroy -input=false"
  run terraform plan -destroy -out=tfplan.destroy -input=false
  report "Planning destroy" ok
  if [[ "$AUTO_YES" != "true" ]]; then
    read -r -p "  Destroy the VM and everything above? [y/N] " reply
    [[ "${reply,,}" == "y" ]] || { warn "aborted"; rm -f tfplan.destroy; exit 0; }
  fi
  say "Destroying"
  report "Destroying VM" running "terraform apply -input=false tfplan.destroy"
  run terraform apply -input=false tfplan.destroy
  rm -f tfplan.destroy
  ok "destroyed"
  report "Destroying VM" done "" "VM and its resources were destroyed"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Plan
# ---------------------------------------------------------------------------
say "Planning (nothing is created yet)"
report "Planning" running "terraform plan -out=tfplan -input=false"
run terraform plan -out=tfplan -input=false
ok "plan ready"
report "Planning" ok

if [[ "$AUTO_YES" != "true" ]]; then
  read -r -p "  Create the VM shown above? [y/N] " reply
  [[ "${reply,,}" == "y" ]] || { warn "aborted"; rm -f tfplan; exit 0; }
fi

# ---------------------------------------------------------------------------
# 5. Apply
# ---------------------------------------------------------------------------
say "Creating VM — this normally takes 1-3 minutes"
report "Creating VM" running "terraform apply -input=false tfplan"
run terraform apply -input=false tfplan
rm -f tfplan
ok "VM created"

echo
say "Connection details"
terraform output
report "Creating VM" done "" "VM created — $(terraform output -json 2>/dev/null | grep -o '"ssh_command":{[^}]*"value":"[^"]*"' | sed -E 's/.*"value":"([^"]*)".*/\1/')"
