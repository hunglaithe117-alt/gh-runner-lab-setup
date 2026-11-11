# Runner setup kit — copy this folder into your repo

Two Incus system containers, each running an ephemeral GitHub Actions self-hosted runner,
provisioned from **one YAML file that lists what your project needs**. Copy the folder,
edit one profile, run the commands below.

```
your-repo/
└── runner-kit/            ← this folder, renamed however you like
    ├── requirements/
    │   └── my-project.yml ← the only file you normally edit
    ├── schema/            ← editor validation + documentation of the format
    ├── scripts/render.py  ← profile → cloud-init + Ansible vars
    ├── cloud-init/        ← generated; first-boot baseline
    ├── ansible/           ← idempotent convergence
    ├── tests/             ← contract tests (stdlib unittest)
    └── setup.sh           ← create / prepare / register / destroy
```

## Quick start

```bash
cd runner-kit
cp requirements/python-fastapi.yml requirements/my-project.yml
$EDITOR requirements/my-project.yml          # name + your packages

./setup.sh render requirements/my-project.yml
./setup.sh create                            # profile + containers, waits for cloud-init
./setup.sh prepare                           # idempotent: converges what cloud-init cannot
./setup.sh runner                            # unpack the Actions runner
GH_RUNNER_PAT=github_pat_... ./setup.sh register OWNER/REPO "$(gh api -X POST \
  /repos/OWNER/REPO/actions/runners/registration-token -q .token)"
```

Prerequisites on the host:

- Incus reachable by your user: `incus list` works, `id -nG | grep incus-admin` shows it.
- `python3` with PyYAML (`sudo apt install python3-yaml`).
- `ansible` (`sudo apt install ansible`); collections are installed by `setup.sh`.
- `gh` only if you want a PAT-driven ephemeral loop (token minting in the quick start).
- On Ubuntu 25.04+, the AppArmor sysctl, or commands inside containers hang with no output:

  ```bash
  echo 'kernel.apparmor_restrict_unprivileged_unconfined=0' \
    | sudo tee /etc/sysctl.d/50-incus-apparmor.conf
  sudo sysctl --system
  ```

## The profile file

`requirements/<name>.yml` is validated strictly: **an unknown key is an error**, not a
warning. That is on purpose — a silently ignored typo in a copied file is worse than a
render that refuses to run.

```yaml
name: my-project            # required, [a-z0-9-]; becomes the profile/container prefix
description: what this is for
image: images:ubuntu/26.04/cloud
runner_user: ubuntu         # must already exist in the image, with a home and sudo

timezone: Asia/Ho_Chi_Minh
locale: en_US.UTF-8

apt:
  update: true
  packages: [git, curl, jq, build-essential]
  repositories:             # Ansible path only
    - name: githubcli
      uri: https://cli.github.com/packages
      suite: stable
      components: [main]
      key_url: https://cli.github.com/packages/githubcli-archive-keyring.gpg
      packages: [gh]

python:
  uv_tools: [ruff, mypy]    # Ansible path only

node:
  major: 24                 # Ansible path only
  npm_globals: [pnpm]       # requires major

services:
  postgres:
    enabled: true
    role: ubuntu            # peer auth: must equal runner_user
  redis:
    enabled: true
    unixsocket: /run/redis/redis-server.sock
    unixsocketperm: "766"   # quoted: YAML reads 0766 as decimal 502

sysctl:
  fs.inotify.max_user_instances: 8192
  vm.max_map_count: 262144

env:
  DATABASE_URL: postgresql+asyncpg:///postgres?host=/var/run/postgresql
  REDIS_URL: unix:///run/redis/redis-server.sock
```

Rules worth knowing before you edit:

- `name` becomes an Incus profile name and the container prefix. It must start and end with
  a letter or digit (no trailing hyphen, max 60 chars, so `<name>-<n>` still fits Incus's
  63-char instance limit). `default` and `docker` are refused: the kit will not touch a
  profile it does not own. Every kit profile carries `user.kit=<name>`; a profile created by
  an earlier version of this kit has no marker and must be adopted once:

  ```bash
  incus profile set <profile> user.kit <name>
  ```
- `services.postgres: {}` enables it. A bare `postgres:` (null) is an error — write `{}`
  or `enabled: false`. Disabling a service skips its tasks; it does **not** revert edits
  already made to `redis.conf` or the PostgreSQL role.
- Enabling a service **injects its package** (`postgresql`, `redis-server`) into the
  cloud-init package list and into `gen_service_packages` for Ansible. Do not add it
  yourself. `timezone`/`locale` likewise pull in `tzdata`/`locales`.
- The Redis socket's parent directory is created only when missing, with `redis:redis 2755`.
  An existing directory is never re-owned or re-moded, so keep the socket under a dedicated
  path (the default `/run/redis`); pointing it at `/tmp` or `/run` will not chown those, but
  Redis's own unit may still refuse to write there.
- `runner_user` must already exist in the image, with a home directory and passwordless
  sudo for the connection user. The kit does not create users; `prepare` fails with the
  field name when the account is missing.
- `env` keys must be shell identifiers and may not be reserved names: the prefixes `GH_`
  and `LD_`, plus `PATH`, `HOME`, `SHELL`, `IFS`, `BASH_ENV`, `ENV`, `PYTHONPATH` — the
  runner wrapper owns those. Values are written as `KEY="value"` lines with
  four-character escaping, which systemd's `EnvironmentFile=` and a shell `set -a; .`
  both read identically. `/etc/runner-env.sh` is mode `0640` and **not a secret store**.
- Top-level keys starting with `x-` are ignored anchor containers. They exist so you can
  reuse blocks with YAML merge keys:

  ```yaml
  x-base: &base
    update: true
    packages: [git, jq]
  apt:
    <<: *base
  ```

  Nested blocks stay strict; only the top level accepts `x-*`.
- The renderer de-duplicates package lists; the schema rejects duplicates. Treat the schema
  as the contract and keep lists unique.

Full field reference: `schema/requirements.schema.json` (point your editor at it via
`# yaml-language-server: $schema=...` for inline validation).

## Two paths, one boundary

| | cloud-init | Ansible |
|---|---|---|
| File | `cloud-init/user-data.yaml` (generated) | `ansible/prepare.yml` |
| When | first boot only, never again | any time, re-runnable |
| Does | apt baseline, sysctl, `/etc/runner-env.sh`, Redis socket, PostgreSQL peer role, `gh-runner-info` | packages and services above, plus extra apt repositories, uv tools, Node, npm globals, and repair of running containers |
| Command | `./setup.sh create` | `./setup.sh prepare` |

This split is the point, not duplication. cloud-init gets a container usable with no control
node; Ansible keeps it correct afterwards. cloud-init writes a few things Ansible does not
recreate (`/usr/local/bin/gh-runner-info`). Editing the profile after `create` changes
nothing for existing containers — re-render and run `prepare`, or `destroy` and `create`
again.

## Commands

| Command | What it does |
|---|---|
| `./setup.sh render <profile>` | validate the profile, write `cloud-init/user-data.yaml` + `ansible/vars/generated.yml` |
| `./setup.sh render <profile> --check` | CI guard: exit 1 when the rendered files are stale |
| `./setup.sh create` | Incus profile + containers, waits for `cloud-init status --wait` (15 min timeout) |
| `./setup.sh prepare` | `ansible-playbook ansible/prepare.yml` (idempotent) |
| `./setup.sh runner` | `ansible-playbook ansible/runner.yml` |
| `./setup.sh register <owner/repo> [token]` | ephemeral runner registration; token defaults to `$GH_RUNNER_TOKEN` |
| `./setup.sh register --org <org> [token]` | same, organisation scope |
| `./setup.sh status` | containers + `gh-runner.service` state |
| `./setup.sh logs [container]` | last 50 journal lines of `gh-runner` |
| `./setup.sh destroy [--yes]` | delete containers and the Incus profile; containers must be attached to the kit's marked profile, the profile must carry `user.kit` |

Environment overrides: `KIT_PYTHON`, `CONTAINER_COUNT`, `CONTAINER_PREFIX`, `CONTAINER_CPU`,
`CONTAINER_MEM`, `INCUS_PROFILE`, `RUNNER_LABELS`, `GH_RUNNER_TOKEN`, `GH_RUNNER_PAT`.
Run commands from the kit root — `render --check` with no argument resolves the profile
relative to the current directory.

`create` refuses to modify a profile or container it does not own: the profile must carry
`user.kit=<name>` and the container must be attached to that profile. That prevents
`name: default` from rewriting the host's shared profile.

## Ephemeral runners and the PAT trade-off

`config.sh` runs with `--ephemeral`: the runner accepts one job and deregisters. The
systemd unit is `Restart=always`, and `run-ephemeral.sh` mints a fresh registration token
before each start **if a PAT is stored**:

```bash
GH_RUNNER_PAT=github_pat_... ./setup.sh register OWNER/REPO <token>
```

Without a PAT (or when `gh` is not installed in the image), only the first job runs; the
wrapper warns and reuses the existing registration rather than failing silently. After that
job the unit restarts with an already-consumed registration, so it can crash-loop — register
again with a fresh token or add a PAT.

**Read this before storing a PAT.** Jobs run as the same operating-system user as the
runner, so a job can read `/etc/gh-runner/token` (or the listener's environment) and
exfiltrate it. Ephemeral runners isolate *job from job*, not *job from host credentials*.
Register only repositories whose workflows are trusted — no `pull_request_target` running
untrusted fork code, protected branches, reviewed workflows. For untrusted pull requests,
use GitHub-hosted runners or a VM, not this kit with a PAT.

Use a **fine-grained** PAT (`github_pat_...`) limited to `Administration: write` on that one
repository; a classic `ghp_...` token cannot express that permission and is broader than
needed. Rotate it, and remember it is written into the container at register time, not
injected at boot.

## Copying this into your repo — checklist

1. Copy the folder (e.g. `runner-kit/`) and keep it self-contained; nothing here imports
   from the lab it came from.
2. Copy an example profile, set `name`, then add packages.
3. Keep `cloud-init/user-data.yaml`, `ansible/vars/generated.yml` and
   `ansible/inventory.generated.yml` out of git (already ignored in this folder).
4. Regenerate before committing config changes: `./setup.sh render <profile> --check`
   in CI catches stale artifacts.
5. Run the contract tests after editing the renderer or schema:
   `cd runner-kit && /usr/bin/python3 -m unittest discover -s tests -t .`
6. If you point `runner_user` at a non-stock account, build or choose an image where that
   account exists with a home and sudo — `create`/`prepare` fail fast otherwise.

## Terraform?

Not shipped as a path. `terraform/README.md` explains why, gives the `lxc/incus` provider
skeleton if you want it anyway, and shows the Incus-native `preseed` alternative.
