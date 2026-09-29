# flotilla-e2e

One coordinated Terraform apply that provisions an **orchestrator** VM
(flotilla-server) and one or more **data-provider** VMs (flotilla-client),
each installing Docker and building its image from source, wires the
clients to the server directly (via Terraform outputs, no lookup needed),
waits for every client to actually register, then runs a real FL session on
the orchestrator — all in one `terraform apply`.

This is additive: `terraform/participant-vm` (each participant deploying
independently into their own subscription) and
`terraform/modules/flotilla-vm` (the reusable module this config is built
on) are both untouched by this.

## What happens, in order

1. `module.orchestrator` — one VM: installs Docker, builds
   `flotilla-server`/`flotilla-session` from `Flotilla_Deployment/`,
   generates the demo CIFAR10 validation split, brings up
   `docker compose` (server + redis + mosquitto).
2. `module.data_provider` (one per `data_provider_names` entry, in
   parallel) — each VM: installs Docker, builds `flotilla-client`,
   generates its own CIFAR10 training split, starts the client container
   with `SERVER_GRPC_HOST` pointed at the orchestrator's public IP and
   `CLIENT_ADVERTISE_HOST` set to its own public IP.
3. `null_resource.wait_for_clients` — polls the orchestrator's
   `GET /client_status` (locally, from whatever machine runs `terraform
   apply`) until every client above has registered, up to
   `wait_timeout_s` (default 900s).
4. `null_resource.start_session` — uploads `session_config_path` (default:
   the verified `flotilla_quicksetup_config.yaml` demo config —
   FedAT_CNN / CIFAR10_IID, 10 rounds) to the orchestrator and runs the
   `flotilla-session` container **there**, which POSTs the training config
   to the server's REST API and exits.

Each VM builds its own image from source rather than pulling from a
registry — no registry to stand up, and it works the same regardless of
what's on the machine running `terraform apply`. That does mean apply time
is dominated by Docker installs + two-ish torch builds + CIFAR10 downloads,
not by VM boot — budget **15-20 minutes**.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- An SSH key pair (`ssh-keygen -t ed25519` if you don't have one) — used
  both to log into each VM and by Terraform's own provisioners to copy
  source and run the build/start scripts over SSH.
- A local checkout of `Flotilla_Deployment` (defaults to `../../Flotilla_Deployment`
  relative to this directory — i.e. this workspace's own copy; override
  `flotilla_source_path` in `terraform.tfvars` if yours lives elsewhere).

## Usage

```bash
cd terraform/flotilla-e2e
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: subscription_id, data_provider_names

./deploy.sh
```

`deploy.sh` is non-interactive by default: it opens device-code Azure login
if you're not already signed in, and once that succeeds it runs straight
through `plan` → `apply` with no confirmation prompt — no further user
interaction needed after login. Pass `--confirm` if you want the
"Create these VMs? [y/N]" prompt back before it applies.

Watch the output — each VM's provisioning script prints `STAGE: ...` lines
as it goes (Docker install → image build → dataset generation → container
start), and `wait_for_clients`/`start_session` print their own `STAGE:`
lines locally.

When it's done:

```bash
terraform output
# client_status_url        -> curl it to see who's registered
# orchestrator_ssh_command -> ssh in, `sudo docker logs -f flotilla-server`
#                              to watch training rounds happen live
```

## Tearing down

```bash
./deploy.sh --destroy
# or: terraform destroy
```

## Notes / known limits

- **NSG posture**: `allowed_ssh_cidr`/`allowed_fl_cidr` both default to
  `0.0.0.0/0` (open), same posture as `participant-vm`. Fine for a quick
  test; tighten in `terraform.tfvars` for anything left running.
- **Dataset**: every VM (client and server) independently downloads
  CIFAR10 via `torchvision` and re-derives its own split via
  `generate_dataset.py` — there's no shared/real dataset here, this is the
  same synthetic demo split used in `PROGRESS.md`'s verified run. Point
  `session_config_path` at a different config (and adjust what each client
  generates) to run something real.
- **Re-running `terraform apply`** after a partial failure re-runs
  `null_resource.provision_flotilla`'s script from the top on any VM whose
  trigger changed — the script is written to be safely re-runnable
  (`docker build` layer-caches, `docker compose up -d` and `docker rm -f
  flotilla-client` before `docker run` are both idempotent).
- **Scaling clients**: add names to `data_provider_names` and re-apply —
  new VMs come up alongside existing ones; `wait_for_clients` and
  `start_session` re-trigger since their `triggers` include the current
  client VM id list.
