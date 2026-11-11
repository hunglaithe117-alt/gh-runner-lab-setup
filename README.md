# gh-runner-lab

Small, self-contained lab: builds **2 Incus system containers**, each running
**one ephemeral GitHub Actions self-hosted runner** (a fresh runner per job).
Everything is driven by a single `lab.sh` script.

```
host Ubuntu 26.04 + incus 6.0.5
└── incusbr0 (10.156.39.0/24, NAT, dnsmasq)
    ├── gh-runner-1  (4 CPU, 6GiB)  → gh-runner.service → 1 job → restart
    └── gh-runner-2  (4 CPU, 6GiB)  → gh-runner.service → 1 job → restart
```

To push the repo to GitHub and run the runner on this machine directly (no Incus
needed), see [`GITHUB.md`](GITHUB.md) and [`local-runner/README.md`](local-runner/README.md).

## Two provisioning paths

The lab deliberately keeps **two** independent paths, each of which works on its
own:

| | Path A — cloud-init | Path B — Ansible |
|---|---|---|
| File | `cloud-init/runner.yaml` | `ansible/prepare.yml`, `ansible/runner.yml` |
| When it runs | Only on the container's first boot | Any time, as often as you like |
| Nature | Declarative, one-shot, cannot be amended | Idempotent, corrects drift on its own |
| Command | `./lab.sh create` | `./lab.sh ansible prepare`, `./lab.sh ansible runner` |
| Best for | Packaging a baseline for new containers | Repetition, fixing a container that is already running |

**What each path teaches.** Path A teaches how to describe a machine as data: the
whole file is declarative YAML, there are no steps, and you only see the result on
the container you just created. Path B teaches how to keep a machine in a desired
state: each task checks before it acts, so a second run changes nothing, and a
failure partway through is fixed by running again.

cloud-init **applies only on the first boot**. A later
`incus profile set ... cloud-init.user-data` affects only containers created
*after* the change; a running container receives nothing. That is why changes
that need repeating live in `ansible/`.

## Software in the container

| Component | Path A (cloud-init) | Path B (Ansible) |
|---|---|---|
| Base apt packages | `packages:` in `cloud-init/runner.yaml` | the "Install base packages" task in `ansible/prepare.yml`, same list |
| GitHub CLI | none | official apt repo + `gh` |
| uv | none | `/usr/local/bin/uv` for every user |
| ruff | none | `uv tool install ruff` for `ubuntu`, symlink `/usr/local/bin/ruff` |
| PostgreSQL | `postgresql`, `libpq-dev` | as above + the `ubuntu` role (idempotent) |
| Redis | `redis-server` | as above + unix socket (idempotent) |
| Runner binaries | none | `ansible/runner.yml` |

`gh`, `uv`, `ruff` exist only on Path B (and in `./lab.sh toolchain`) — cloud-init
stays with the minimal package list; the rest is the idempotent path's job.

## PostgreSQL and Redis

Both listen on loopback only (Redis `127.0.0.1:6379`, PostgreSQL
`127.0.0.1:5432`) and are **not** exposed on `eth0`; the lab uses a unix socket
for both, so there is no port to open.

**Redis** — socket `/run/redis/redis-server.sock`, permissions `766`, declared in
`/etc/redis/redis.conf` (`unixsocket`, `unixsocketperm`). Ubuntu has no `conf.d`
include, so both paths edit that file directly.

```bash
incus exec gh-runner-1 -- redis-cli -s /run/redis/redis-server.sock ping
```

**PostgreSQL** — the `ubuntu` role (superuser, **no password**) authenticates by
peer over the unix socket, so any user who can log in to the container reaches
the database under that same name.

```bash
incus exec gh-runner-1 -- psql -c 'select current_user, version()'
```

Environment variables for a FastAPI project (SQLAlchemy async + asyncpg pointed
at the socket):

```bash
DATABASE_URL=postgresql+asyncpg:///postgres?host=/var/run/postgresql
REDIS_URL=unix:///run/redis/redis-server.sock
```

## Checks before running

```bash
incus list                  # must list containers
id -nG | grep incus-admin   # must show incus-admin
```

If `incus list` reports a permission error, the login session lacks the group.
Fix it with `su - $USER`, `newgrp incus-admin`, or a full logout/login.

## Run order

```bash
sudo ./lab.sh host-prep          # one time only, needs sudo
./lab.sh create                  # profile + containers + cloud-init
./lab.sh toolchain               # or: ./lab.sh ansible prepare
./lab.sh runner                  # or: ./lab.sh ansible runner
./lab.sh register OWNER/REPO <token>
```

`toolchain`/`runner` are the imperative versions (they call `incus exec`);
`ansible prepare`/`ansible runner` do the same work through idempotent playbooks.
Pick one, or run both to compare — running them one after the other breaks
nothing.

Ansible must be installed on the **host**, not in the container:

```bash
sudo apt install -y ansible
ansible-galaxy collection install -r ansible/requirements.yml
./lab.sh ansible prepare
./lab.sh ansible runner
```

`./lab.sh ansible` generates `ansible/inventory.generated.yml` from the existing
containers (this file is **not** committed, and every run overwrites it). The
inventory uses `ansible_connection: community.general.incus`; add
`ansible_incus_project` only when the current user is **not** in the
`incus-admin` group.

Environment overrides: `RUNNER_COUNT`, `RUNNER_PREFIX`, `PROFILE`, `IMAGE`,
`RUNNER_LABELS`, `RUNNER_VERSION`, `RUNNER_CPU`, `RUNNER_MEM`,
`RUNNER_WORKDIR`, `GH_RUNNER_TOKEN`, `GH_RUNNER_PAT`.

## Gotchas and how to handle them

| Symptom | Cause | Fix |
|---|---|---|
| Commands inside the container hang and never return | Ubuntu 25.04+ restricts AppArmor for unprivileged unconfined profiles | `host-prep` writes `/etc/sysctl.d/50-incus-apparmor.conf` with `kernel.apparmor_restrict_unprivileged_unconfined=0` (source: quan.hoabinh.vn, the 2025/11 post "fix commands hanging in incus container") |
| systemd in the container cannot start a unit, or a job needs Docker/user namespaces | Nesting is missing | The `gh-runner` profile sets `security.nesting=true` |
| The container cannot resolve DNS | `systemd-resolved` on the host (127.0.0.53) does not serve containers | `incusbr0` already sets `raw.dnsmasq "server=1.1.1.1"`; note that this setting disables AppArmor for Incus's dnsmasq process |
| `/dev/kvm` exists on the host but goes unused | We run system containers, not VMs | Ignore it, no configuration needed |
| `./lab.sh ansible ...` cannot reach the container | The group is missing, or the collection is not installed | `id -nG \| grep incus-admin` must show `incus-admin`; check that `ansible-galaxy collection install -r ansible/requirements.yml` has finished (`ansible-galaxy collection list \| grep community.general`) |
| You edit `cloud-init.user-data` and the container does not change | cloud-init runs only on the first boot | Recreate the container (`./lab.sh destroy --yes && ./lab.sh create`), or use `./lab.sh ansible prepare` |

## Getting a registration token

Option 1 — web UI: repo → **Settings → Actions → Runners → New self-hosted
runner**, copy the value after `--token`.

Option 2 — CLI:

```bash
gh api -X POST /repos/OWNER/REPO/actions/runners/registration-token -q .token
```

The token expires after about 1 hour, so fetch it right before `register`.

## Ephemeral: read this before using it

`config.sh` is called with `--ephemeral`: the runner **unregisters itself after
exactly one job**, so every restart needs a new registration token. That is why
`lab.sh register` also installs `/opt/actions-runner/run-ephemeral.sh` and a
systemd unit with `Restart=always`: the wrapper fetches a new token from the
GitHub API and only then runs `./run.sh`.

The wrapper can fetch a new token only when a PAT is present at
`/etc/gh-runner/token` (export `GH_RUNNER_PAT` before running `register`).
Without a PAT, only the first job runs.

To go back to a **persistent** runner (register once, run forever):

1. Drop `--ephemeral` from the `config.sh` call (both in `lab.sh register` and in
   `run-ephemeral.sh`).
2. Have the unit run `./run.sh` directly instead of the wrapper, or let the
   wrapper call `./run.sh` without re-registering.

## Troubleshooting

```bash
incus list
incus exec gh-runner-1 -- ping -c1 10.156.39.1     # check outbound to the gateway
incus exec gh-runner-1 -- journalctl -u gh-runner -f
./lab.sh status
./lab.sh logs                # last 50 lines of gh-runner on gh-runner-1
./lab.sh logs gh-runner-2
incus exec gh-runner-1 -- gh-runner-info           # container name + IP
```

Job never picked up: check that `RUNNER_LABELS` matches `runs-on` in the workflow
(default `self-hosted,linux,x64,incus`).

## Reusing for another repo — `template/`

This lab is a reference implementation for one project. `template/` is the
**copy-and-adapt** version: copy the whole directory into your repo, edit exactly
one YAML file, run a few commands. Its docs are written in English so you can
hand them to someone else.

```
template/
├── requirements/<repo>.yml   # the only file you edit: apt packages, apt repos, uv, node, service, sysctl, env
├── scripts/render.py         # YAML → cloud-init/user-data.yaml + ansible/vars/generated.yml
├── schema/                   # JSON Schema for editor validation
├── ansible/                  # prepare.yml (idempotent) + runner.yml
├── tests/                    # 36 contract test, stdlib unittest
└── setup.sh                  # render / create / prepare / runner / register / status / destroy
```

```bash
cd template
./setup.sh render requirements/python-fastapi.yml
./setup.sh create && ./setup.sh prepare && ./setup.sh runner
```

Deliberate differences from `lab.sh`:

| | `lab.sh` (this lab) | `template/setup.sh` |
|---|---|---|
| Names, image, user, packages | hardcoded in the script | generated from `requirements/*.yml` |
| Incus profile | `gh-runner` | `<name>` + the `user.kit` marker (refuses to modify a foreign profile, including `default`) |
| Foreign container with the same name | not checked | refused; only containers carrying the right profile are accepted |
| PAT for ephemeral | `export GH_TOKEN` | used only for a single `gh api` call, with a fallback on error |

Three things to read before using a PAT: jobs run as the same user as the runner,
so they **can read** `/etc/gh-runner/token`; register only repos with trusted
workflows; use a fine-grained PAT limited to `Administration: write`. Details in
`template/README.md`.

Terraform is not a third path — the reasoning and a skeleton live in
`template/terraform/README.md` (docs-only).

## Cleanup

```bash
./lab.sh destroy          # asks for confirmation
./lab.sh destroy --yes    # delete containers + profile, no prompt
```
