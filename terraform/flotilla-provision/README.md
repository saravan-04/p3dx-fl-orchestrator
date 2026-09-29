# flotilla-provision

Provisions the flotilla-server and flotilla-client(s) **onto VMs that
already exist** (created separately via `terraform/participant-vm`'s
`deploy.sh`), then runs a real FL session — all with **no SSH access
needed** from the machine running `terraform apply`. Each VM's setup runs
entirely from the inside, via Azure's Custom Script Extension: Terraform
tells Azure's control plane "run this script on this VM," and the VM's own
Azure guest agent executes it locally, as root. The only thing this needs
from wherever `terraform apply` runs is Azure Resource Manager API access
to the same subscription — not a matching SSH key, not inbound
connectivity to the VM at all (except later, to poll the REST API over
plain HTTP).

This exists because `terraform/flotilla-e2e` (the other config in this
repo) *creates* its own VMs and provisions them over SSH — which doesn't
fit when the VMs were already created by someone else's `deploy.sh` run
(the real decentralized flow this project is built around: a data provider
or the FL owner each provision their own VM independently) and you don't
have their SSH key.

## What happens, in order

1. Looks up the orchestrator VM (`flo-user-<orchestrator_participant_name>`)
   and each data-provider VM (`flo-data-provider-<name>` for each entry in
   `data_provider_participant_names`) by their deterministic
   `terraform/participant-vm` naming convention — no VM is created.
2. Opens port 12345 (REST API) on the orchestrator's existing NSG — that
   module only opens 22/50051/50052-60, not the REST port this needs.
3. **Orchestrator**: a Custom Script Extension installs Docker, clones
   `Flotilla_Deployment` from GitHub, builds `flotilla-server` +
   `flotilla-session`, generates the demo CIFAR10 validation split, and
   brings up `docker compose` (server + redis + mosquitto).
4. **Each data provider** (in parallel): a Custom Script Extension installs
   Docker, clones the same source, builds `flotilla-client`, generates its
   own CIFAR10 training split, and starts the client pointed at the
   orchestrator's public IP.
5. `wait_for_clients` — polls the orchestrator's `GET /client_status`
   (locally, plain HTTP) until every client above has registered.
6. **Session** — another Custom Script Extension on the orchestrator runs
   `flotilla-session` against `localhost:12345` with the demo config
   (`flotilla_quicksetup_config.yaml`), which POSTs the training request
   and exits.

`generate_dataset.py` isn't committed to the `Flotilla_Deployment` repo as
of this writing, so its content is embedded directly into each script
rather than relying on the clone for it.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- The orchestrator and every data-provider VM must **already exist** (run
  `terraform/participant-vm`'s `deploy.sh` first for each, if you haven't)
  and be in the **same subscription** this runs against.
- Each VM needs the standard Azure Linux Guest Agent running — true by
  default on the Canonical Ubuntu 24.04 image `participant-vm` uses.

## Usage

```bash
cd terraform/flotilla-provision
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: subscription_id, orchestrator_participant_name,
# data_provider_participant_names

./deploy.sh
```

`deploy.sh` opens device-code Azure login if needed, then runs straight
through `plan` → `apply` with no further prompt. Watch for `STAGE: ...`
lines as each script progresses (Docker install → clone → build → dataset
generation → container start), plus `wait_for_clients`'s own `STAGE:`
lines locally once VM provisioning finishes.

When it's done:

```bash
terraform output
# client_status_url -> curl it to see who's registered
```

Checking training progress (`docker logs -f flotilla-server` on the
orchestrator) needs either SSH access to that VM or the Azure Portal's
"Run command" feature — this config doesn't set up a way to stream that
output back automatically.

## Tearing down

```bash
./deploy.sh --destroy
```

This only removes what this config created (the extensions + the NSG
rule) — it does **not** delete the VMs, and does **not** stop the running
containers on them (the extensions having "run once" is a one-time
action, not a managed service). To actually stop the containers, run
`docker compose down` / `docker rm -f flotilla-client` on each VM, or
destroy the VMs themselves via `terraform/participant-vm`.

## Notes / known limits

- **Re-running**: a Custom Script Extension only re-executes if its
  script content changes (Terraform sees no diff otherwise). Each script
  does a fresh `git clone` (wiping any prior `/root/flotilla` on that VM)
  when it does re-run — including checkpoints/logs written under it. Fine
  for a first provision; be aware a forced re-run starts training over.
- **NSG posture**: `allowed_fl_cidr` defaults to `0.0.0.0/0` like
  `participant-vm`'s own defaults. Tighten in `terraform.tfvars` for
  anything left running.
- **Stale gov_layer entries**: `data_provider_participant_names` is
  explicit on purpose — gov_layer's `/vm-registry/data-providers` list
  keeps entries for VMs that were destroyed later, so it can't be trusted
  as "who's actually live right now."
