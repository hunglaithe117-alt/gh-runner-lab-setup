# Setup explained: GitHub Actions runners in Incus system containers

This document explains *why* the lab is configured the way it is, not just *what* to
type. Read it once end to end, then use it as a reference while you experiment.

Audience: you are learning Incus, cloud-init and Ansible on a single Ubuntu 26.04 host.

---

## 1. The shape of the thing

```
Ubuntu 26.04 host (16 cores, 30 GiB RAM, /dev/kvm present but unused)
│
├── incusd ── storage pool "default" (dir driver, /var/lib/incus)
│         └── network "incusbr0" (managed bridge, 10.156.39.1/24, NAT)
│
├── profile "default"   → eth0 nic (incusbr0) + root disk (pool default)
├── profile "gh-runner" → security.nesting, limits.cpu, limits.memory,
│                         cloud-init.user-data
│
├── container gh-runner-1  (profiles: default, gh-runner)
│     cloud-init → postgres, redis, python, git, ...
│     /opt/actions-runner → Runner.Listener + gh-runner.service
│
└── container gh-runner-2  (identical)
```

Each container is a **system container**: a full Ubuntu userland with systemd as PID 1,
sharing the host kernel. It behaves like a small VM — `systemctl`, `apt`, `postgres`,
`redis` all work exactly as on a real machine, with no container-specific entrypoint
hacks.

Two profiles are stacked on each container. Devices (`eth0`, `root`) come from
`default`; limits, the nesting flag and cloud-init user-data come from `gh-runner`.
Incus merges profiles left to right, later ones overriding earlier ones, and the
instance's own config overrides all profiles.

---

## 2. Incus vocabulary you actually need

| Term | What it is | Where it appears here |
|---|---|---|
| **Instance** | A container or VM | `gh-runner-1`, `gh-runner-2` |
| **Profile** | Reusable bundle of config + devices | `default`, `gh-runner` |
| **Image** | Root filesystem template | `images:ubuntu/26.04/cloud` |
| **Storage pool** | Where instance disks live | `default` (dir driver) |
| **Network** | A managed bridge, or a physical link | `incusbr0` |
| **Project** | Namespace for instances/profiles/networks | `default` (you are in `incus-admin`, so you see it) |

`incus` commands talk to `incusd` over `/var/lib/incus/unix.socket`, which is owned by
`root:incus-admin` with mode `0770`. That single fact explains most early errors:

- Shell created **before** you were added to `incus-admin` → `You don't have the needed
  permissions to talk to the incus daemon`.
- Only a **new login** (or `su - $USER`) refreshes a process's supplementary groups.
  Ubuntu 26.04 no longer ships `newgrp`/`sg` binaries, so `su - $USER` is the practical
  fix. `id -nG | grep incus-admin` confirms it.

`incus exec <name> -- cmd` runs as **root inside the container by default**. That is why
none of the provisioning steps need `sudo` inside the container.

`incus exec` also **forwards its stdin** to the command. In a shell loop fed by a
here-string that silently truncates the list after the first iteration:

```bash
# Wrong: the first incus exec swallows the remaining lines.
while read -r name; do incus exec "$name" -- true; done <<<"$names"

# Right: iterate an array so nothing owns the list on stdin.
mapfile -t names <<<"$names"
for name in "${names[@]}"; do incus exec "$name" -- true; done
```

---

## 3. Host-level settings

### 3.1 The AppArmor sysctl (mandatory on 25.04+)

`lab.sh host-prep` writes `/etc/sysctl.d/50-incus-apparmor.conf`:

```
kernel.apparmor_restrict_unprivileged_unconfined=0
```

Ubuntu 25.04 tightened AppArmor for unprivileged unconfined profiles. Inside an Incus
container some confined processes cannot signal unconfined peers, so commands **hang**
instead of failing with an error — a miserable failure mode because there is no message
to search for. Setting the sysctl to `0` restores the pre-25.04 behaviour.

Source: <https://quan.hoabinh.vn/post/2025/11/fix-commands-hanging-in-incus-container-when-host-os-is-ubuntu>

If you prefer not to relax a host-wide sysctl, the narrower alternative from the same
post is an AppArmor snippet in a profile:

```bash
incus profile create apparmor-fix
incus profile set apparmor-fix raw.apparmor="signal peer=@{profile_name}//&unconfined,"
incus profile assign gh-runner-1 default,gh-runner,apparmor-fix
```

It must be applied per instance, so the sysctl is simpler for a lab.

### 3.2 `security.nesting=true`

Set on the `gh-runner` profile. It allows a container to create nested namespaces.

Two things need it:

1. **systemd user namespacing.** Services that harden themselves (`PrivateUsers=`,
   which Redis and several modern daemons use) call `unshare(CLONE_NEWUSER)`. Without
   nesting this fails with `Failed to set up user namespacing: No such file or
   directory`, and the unit will not start.
2. **Docker-in-Docker style jobs.** If a workflow runs `docker build`, the inner daemon
   needs nested namespaces and often `security.nesting` plus a `docker` package.

Trade-off, stated plainly: nesting means a compromised container has more kernel
surface. On a lab machine that is fine; on shared infrastructure, prefer a VM for jobs
you do not trust.

### 3.3 Resource limits

```
limits.cpu    4
limits.memory 6GiB
```

Applied per container. Two containers therefore cap at 8 CPUs / 12 GiB, leaving headroom
on a 16-core / 30 GiB host that is already running other things.

These are cgroup limits, exposed inside the container through lxcfs: `nproc` reports 4
and `free -h` reports 6 GiB, so tools make correct sizing decisions. Without lxcfs they
would see the whole host and oversubscribe.

`limits.disk` is deliberately not set. With the `dir` driver on ext4 that only works
when the filesystem has project quotas enabled, which this host does not. If you need
per-container disk caps, recreate the pool on ZFS or btrfs, where quotas and cheap
snapshots come for free.

### 3.4 Storage: what `dir` means for you

`incus admin init --minimal` created pool `default` with the `dir` driver: instance
disks are plain directories under `/var/lib/incus/storage-pools/default/`.

Consequences worth knowing:

- **Snapshots are full copies.** `incus snapshot` works but costs real disk, unlike
  ZFS/btrfs where it is nearly free. So do not plan a snapshot-per-job workflow on this
  host.
- **No copy-on-write instance cloning.** `incus copy` is a full data copy.
- **Simple to inspect and fix.** The container filesystem is reachable at
  `/var/lib/incus/storage-pools/default/containers/<name>/rootfs/` from the host, which
  is handy while learning.

525 GB free on `/` is plenty for a lab; a container with Postgres and Redis lands around
1.5 GB.

---

## 4. Networking, and the DNS bug you hit

### 4.1 What exists

`incusbr0` is a **managed** bridge:

| Setting | Value | Meaning |
|---|---|---|
| `ipv4.address` | `10.156.39.1/24` | Host side of the bridge, also DHCP/DNS server |
| `ipv4.nat` | `true` | Outbound traffic is masqueraded to the host's uplink |
| `ipv6.address` | `fd42:...::1/64` | ULA prefix, host-assigned |
| `ipv6.nat` | `true` | Same, for IPv6 |
| `raw.dnsmasq` | `server=1.1.1.1` | See below |

Incus runs one `dnsmasq` per managed bridge, bound to that bridge only
(`--bind-interfaces`), providing DHCPv4, stateless DHCPv6, router advertisements and
DNS. Containers get their address from it and use `10.156.39.1` as their DNS server.

Traffic path out: container → `incusbr0` → iptables/nftables NAT → host uplink
(`enp4s0`). `ufw` is inactive here, so nothing else interferes.

### 4.2 Why `raw.dnsmasq` was needed

Symptom: containers had an address, could ping `10.156.39.1` and `1.1.1.1`, but
`getent hosts github.com` failed with `Temporary failure in name resolution`.

Cause: the host resolves through `systemd-resolved`, so `/etc/resolv.conf` contains
`nameserver 127.0.0.53`. Incus's dnsmasq inherits that file and forwards queries to
`127.0.0.53` — but from a non-loopback source address, resolved's stub listener refuses
or is not reachable the way dnsmasq expects. Result: dnsmasq answers DHCP fine and
fails every upstream query.

Fix applied: `incus network set incusbr0 raw.dnsmasq "server=1.1.1.1"`, which appends
`server=1.1.1.1` to the generated dnsmasq config so it forwards upstream directly
instead of trusting `/etc/resolv.conf`.

Two side effects to remember:

- **`raw.dnsmasq` disables AppArmor confinement for that dnsmasq process.** You will see
  `Skipping AppArmor for dnsmasq due to raw.dnsmasq being set` in the journal. Acceptable
  for a lab; if you want it clean, instead pin upstream DNS on the host in
  `/etc/systemd/resolved.conf` (`DNS=1.1.1.1`), restart `systemd-resolved`, and remove
  `raw.dnsmasq`.
- **It is per network.** A second bridge needs the same treatment, or the host-side DNS
  fix.

Check the state any time with:

```bash
incus network show incusbr0
incus exec gh-runner-1 -- getent hosts github.com
```

### 4.3 What `curl` returning 403 did *not* mean

`curl -sI https://api.github.com` returns `403` without a `User-Agent` header. That is
GitHub's edge policy, not a network fault — TLS completed, HTTP worked. Use
`curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/actions/runner/releases/latest`
or `ping` for connectivity checks.

---

## 5. Provisioning path A — cloud-init

File: `cloud-init/runner.yaml`. Loaded into the `gh-runner` profile by
`./lab.sh create`:

```bash
incus profile set gh-runner cloud-init.user-data - < cloud-init/runner.yaml
```

Incus exposes instance user-data to cloud-init through a NoCloud datasource, so the
container sees it on first boot. `images:ubuntu/26.04/cloud` is used because the plain
`ubuntu` images ship without cloud-init; the `/cloud` suffix is the only difference that
matters here.

### 5.1 What each key does

| Key | Effect |
|---|---|
| `package_update: true` | `apt-get update` before installing |
| `packages:` | Installs the baseline: postgres, redis, python3-dev/venv, libpq-dev, git, build-essential |
| `timezone` / `locale` | Sets `/etc/timezone` and generates `en_US.UTF-8` |
| `write_files:` | Drops `/etc/sysctl.d/60-gh-runner.conf` and `/usr/local/bin/gh-runner-info` |
| `runcmd:` | Runs shell after packages: `sysctl --system`, `locale-gen`, Redis socket rewrite, Postgres role |

The sysctl drop-in raises `fs.inotify.max_user_instances` to 8192 and
`vm.max_map_count` to 262144. Both are common CI failures: file watchers
(`uvicorn --reload`, `watchfiles`, Jest) exhaust inotify instances, and JVM/Electron
style workloads need a higher map count.

### 5.2 The Redis socket rewrite

Ubuntu's `redis-server` config has no `conf.d` include, so the socket is configured by
rewriting the two directives in place:

```bash
sed -i -E \
  -e 's|^#?[[:space:]]*unixsocket[[:space:]]+.*|unixsocket /run/redis/redis-server.sock|' \
  -e 's|^#?[[:space:]]*unixsocketperm[[:space:]]+.*|unixsocketperm 766|' \
  /etc/redis/redis.conf
```

The `^#?` makes the expression match both the commented default and the already-written
line, so re-running the snippet changes nothing — that is the small piece of idempotency
worth noticing here.

`766` rather than the default `700`: Redis runs as user `redis`, CI jobs run as another
user, and `766` lets both open the socket. It is permissive, and it is contained inside
an unprivileged container.

Why a unix socket at all: a FastAPI test suite that talks to Redis/Postgres over
loopback TCP pays for connection setup and port allocation on every test. Unix sockets
skip TCP entirely, are marginally faster, and remove port clashes when several runners
share the bridge.

### 5.3 The PostgreSQL role

```bash
su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='ubuntu'\""
su postgres -c "psql -c 'CREATE ROLE ubuntu SUPERUSER LOGIN'"
```

Creating a role **named after the login user** is what makes peer authentication work:
PostgreSQL trusts the OS user over the unix socket, so no password exists anywhere. The
`-tAc` existence check keeps the snippet re-runnable.

`SUPERUSER` is a lab convenience — a CI job that runs migrations, creates extensions
(`pgvector`, `pg_trgm`) and drops schemas needs it. In production, grant narrowly.

### 5.4 The one-shot property (the important limitation)

cloud-init consumes user-data **once, at first boot**. Editing
`cloud-init/runner.yaml` afterwards changes nothing for existing containers:
`incus profile set ... cloud-init.user-data` only affects containers created later.

Three ways to deal with that:

```bash
# 1. Recreate the container (fastest for a lab)
./lab.sh destroy --yes && ./lab.sh create

# 2. Re-run cloud-init inside an existing container
incus exec gh-runner-1 -- cloud-init clean --logs --reboot

# 3. Stop depending on cloud-init for anything mutable — use Ansible (path B)
```

Inspect what cloud-init actually did:

```bash
incus exec gh-runner-1 -- cloud-init status --long
incus exec gh-runner-1 -- tail -n 60 /var/log/cloud-init-output.log
```

`status --long` is the authoritative answer; `cloud-init-output.log` shows the exact
stderr of every `runcmd` line.

---

## 6. Provisioning path B — Ansible

Ansible is the learning payload: it is declarative *and* re-runnable, which cloud-init is
not. Everything in this path can be run ten times with the same result.

### 6.1 Why the Incus connection plugin

The containers have no SSH server and no SSH key (deliberately — fewer moving parts).
`community.general.incus` shells out to `incus exec` on the control node instead, so
Ansible needs no network path into the container at all.

`ansible/inventory.generated.yml` is produced by `./lab.sh ansible` from the live
container list:

```yaml
all:
  hosts:
    gh-runner-1:
      ansible_user: ubuntu
      ansible_become: true
      ansible_become_method: sudo
      ansible_connection: community.general.incus
      ansible_python_interpreter: /usr/bin/python3
```

- `ansible_user: ubuntu` — the image's default user; `incus exec` still lands as root,
  Ansible then `sudo`s to the declared user where it matters.
- `ansible_become: true` — play-level privilege escalation; `become_user: ubuntu` is
  used for exactly one task (installing `ruff` into that user's home).
- `ansible_incus_project` is only needed when you are *not* in `incus-admin`; you are, so
  it is omitted.
- The file is regenerated every run, which is why it is not committed.

Install the two collections once:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

`community.general` supplies the connection plugin; `community.postgresql` is the
"proper" module set you will want once you outgrow the shell fallback in §6.3.

### 6.2 `ansible/prepare.yml`

`gather_facts: true` with `gather_subset: ["!all"]` collects no facts. Nothing in the
playbook branches on facts, and skipping them removes a full round trip per host — with
the Incus connection each round trip is a process spawn, so it is measurable.

The task order is deliberate:

| # | Task | Why this order |
|---|---|---|
| 1 | `apt` base packages | Must run first; also installs `python3-debian`, which the next task's module needs *on the target* |
| 2 | keyring dir, keyring, `deb822_repository` | Needs `python3-debian` from step 1 |
| 3 | `apt` install `gh` | Needs the repo from step 2 |
| 4 | `fdfind` → `fd` symlink | Purely cosmetic; `when:` guarded by a `stat:` |
| 5 | `get_url` uv installer, run with `UV_INSTALL_DIR=/usr/local/bin` | `creates: /usr/local/bin/uv` makes it a no-op on re-run |
| 6 | `uv tool install ruff` as `ubuntu` | `creates: /home/ubuntu/.local/bin/ruff`; `HOME` is set explicitly because `uv` resolves its tool dir from `$HOME` |
| 7 | symlink `ruff` into `/usr/local/bin` | `when:` guarded — the file only exists after a non-skipped step 6 |
| 8 | Redis runtime dir + two `lineinfile` + `notify` | Handlers fire only on change |
| 9 | PostgreSQL started, role check, `CREATE ROLE` | Check-then-act; `changed_when: false` on the probe so a no-op run reports no change |

Two patterns repeat and are worth internalising:

- **`creates:`** turns a `command` into an idempotent one. The module skips when the
  path exists. This is the idiomatic escape hatch for installers that have no module.
- **probe → `register` → `when`** for anything stateful. `changed_when: false` on the
  probe keeps `--check` and the change summary honest.

Handlers (`Restart redis-server`, `Restart postgresql`) run once at the end of the play
even if several tasks notified them — that batching is the point of handlers.

### 6.3 The `become_user: postgres` caveat

The obvious way to create the role is:

```yaml
community.postgresql.postgresql_user:
  name: ubuntu
  role_attr_flags: SUPERUSER
become: true
become_user: postgres
```

That fails over the Incus connection: the module needs the `postgres` user's environment
(locale, `PGDATA`, `PATH`), and `incus exec` + `sudo -u` does not reproduce it. It works
over SSH with `ansible_ssh_pipelining: true`. The playbook therefore uses:

```yaml
ansible.builtin.shell:
  cmd: runuser -u postgres -- psql -c 'CREATE ROLE ubuntu SUPERUSER LOGIN'
```

`runuser` sets up the target login environment properly, which is exactly what the module
needed. This is a good example of a real constraint you will hit whenever you mix a
connection plugin with `become_user`: the plugin decides how much of a login session
exists for the target user.

### 6.4 `ansible/runner.yml`

Installs binaries only — registration stays in `lab.sh` because it needs a secret.

| Task | Detail |
|---|---|
| `uri` → `set_fact` | Reads the `Location` header of `github.com/actions/runner/releases/latest` when `lab_runner_version` is empty. The REST API allows 60 unauthenticated calls/hour per egress IP and containers share that budget, so the redirect is used instead; `regex_replace('^v','')` strips the tag prefix because the tarball name has no `v` |
| `fail` guard | Aborts with a clear message when the redirect yields nothing, instead of downloading a URL with an empty version |
| `stat` on `bin/Runner.Listener` | Decides whether the download is needed at all |
| `get_url` + `unarchive` | `creates:` on the listener makes the unpack idempotent |
| `installdependencies.sh` | Not idempotent upstream, so success is recorded in `.dependencies-installed` and `creates:` guards it |
| `Runner.Listener --version` | `failed_when: false` because the binary exits non-zero on some builds while still printing the version |

Pin a version for reproducibility:

```bash
./lab.sh ansible runner -e lab_runner_version=2.330.0
```

Anything after the play name is forwarded to `ansible-playbook`, so `-e`, `--check` and
`--diff` all work.

---

## 7. Services inside the container

| Service | Transport | Address | Auth |
|---|---|---|---|
| PostgreSQL | unix socket | `/var/run/postgresql/.s.PGSQL.5432` | peer, role `ubuntu` |
| Redis | unix socket | `/run/redis/redis-server.sock` (perm 766) | none, filesystem permissions only |
| GitHub runner | outbound HTTPS | `github.com` via NAT | registration token at register time |

No TCP ports are published. Nothing in the container is reachable from the LAN, and you
do not need `incus config device proxy` for this lab.

FastAPI environment:

```dotenv
DATABASE_URL=postgresql+asyncpg:///postgres?host=/var/run/postgresql
REDIS_URL=unix:///run/redis/redis-server.sock
```

The empty host in `postgresql+asyncpg:///postgres` plus `?host=/var/run/postgresql` is
how SQLAlchemy points asyncpg at a unix socket. `asyncpg` is not installed by this lab —
`uv sync` in your project brings it.

---

## 8. Runner lifecycle

### 8.1 Registration flags

```bash
./config.sh --unattended \
  --url https://github.com/OWNER/REPO \
  --token "$TOKEN" \
  --labels self-hosted,linux,x64,incus \
  --name gh-runner-1 \
  --work _work \
  --replace \
  --ephemeral
```

| Flag | Effect |
|---|---|
| `--unattended` | No interactive prompts |
| `--url` | Scope: repo (`/OWNER/REPO`), org (`--org`), or enterprise |
| `--token` | Registration token, valid ~1 hour, single-purpose |
| `--labels` | Extra labels; `self-hosted`, `linux`, `x64` are implied, the rest are yours — `incus` is what lets a workflow target `runs-on: [self-hosted, incus]` |
| `--name` | Must be unique within the scope |
| `--work` | Job workspace directory, relative to the runner dir |
| `--replace` | Takes over the name if a stale registration exists — essential when you recreate containers |
| `--ephemeral` | The runner accepts **one** job, then deregisters itself |

### 8.2 Why `--ephemeral` changes the design

`--ephemeral` is the isolation you actually want in CI: no state, no leftover
credentials, no poisoned `node_modules` from job N leaking into job N+1. The cost is that
the registration token is consumed by the single job, so the next job needs a fresh one.

`run-ephemeral.sh` (written into the container by `./lab.sh register`) closes that gap:

```
no PAT at /etc/gh-runner/token  → config.sh once, then run.sh; one job only
PAT present                     → gh api POST .../registration-token before every
                                  run.sh, so systemd's Restart=always keeps working
```

The systemd unit is what makes it a loop:

```ini
Restart=always
RestartSec=10
TimeoutStopSec=5min
```

Every restart re-registers and runs one job. `TimeoutStopSec=5min` gives a running job
time to finish on `systemctl stop`.

Getting the token

`--ephemeral` leaves `.runner` and `.credentials` behind after the job, and `config.sh`
refuses to configure a directory that already has them — `--replace` only replaces the
*remote* registration. That is why `run-ephemeral.sh` deletes those two files (and
`_work`, so the next job does not inherit the previous workspace) before every
`config.sh`. Forget it and the unit crash-loops on `Cannot configure the runner because
it is already configured`.

Get a token by hand when you are experimenting:

```bash
gh api -X POST /repos/OWNER/REPO/actions/runners/registration-token -q .token
```

### 8.3 Persistent runners instead

Delete `--ephemeral` from `config.sh` and point the unit at `./run.sh`:

```bash
./config.sh --unattended --url ... --token ... --labels ... --name ... --replace
# unit: ExecStart=/opt/actions-runner/run.sh
```

Simpler, and wrong for anything security-sensitive: the workspace persists between jobs.

### 8.4 The unit runs as `ubuntu`

`gh-runner.service` gets `User=ubuntu` and `Group=ubuntu` from `RUNNER_USER` (default
`ubuntu`), and `./lab.sh runner` / `./lab.sh register` both `chown -R ubuntu:ubuntu` the
runner directory so the service can read it.

That user choice is not cosmetic: PostgreSQL peer auth compares the **OS user** of the
connecting process to the **role name**, so a runner that runs as `root` cannot connect
as role `ubuntu` and jobs fail with `FATAL: role "root" does not exist`. `RUNNER_USER`
is what keeps the two in sync.

Run as root instead (older behaviour) with:

```bash
RUNNER_USER= ./lab.sh register OWNER/REPO "$TOKEN"
```

Then either give jobs a matching PostgreSQL role or accept that peer auth fails.

`security.nesting` and root-in-container interact: a nested Docker daemon run by root
inside the container has real (container-scoped) privileges. For untrusted workflows, use
a VM instance instead of a container.

---

## 9. `lab.sh` command map

| Command | Touches | Idempotent |
|---|---|---|
| `host-prep` | Host sysctl | Yes (skips when content matches) |
| `create` | Profile + containers | Yes (skips existing) |
| `toolchain` | `incus exec` apt/uv/ruff/redis/pg | Mostly — apt and symlinks yes, `sed` yes |
| `ansible prepare` | Same as `toolchain`, via Ansible | Fully |
| `runner` / `ansible runner` | `/opt/actions-runner` | Yes (`creates:` guards) |
| `register` | `config.sh`, wrapper, unit | Yes (`--replace`) |
| `status`, `logs` | Read-only | Yes |
| `destroy` | Deletes containers + profile | N/A |

Environment overrides:

| Variable | Default | Notes |
|---|---|---|
| `RUNNER_COUNT` | `2` | Containers `gh-runner-1..N` |
| `RUNNER_PREFIX` | `gh-runner` | Container name prefix |
| `PROFILE` | `gh-runner` | Profile holding limits + cloud-init |
| `IMAGE` | `images:ubuntu/26.04/cloud` | `/cloud` is required for cloud-init |
| `RUNNER_CPU` / `RUNNER_MEM` | `4` / `6GiB` | Per container |
| `RUNNER_LABELS` | `self-hosted,linux,x64,incus` | Extend, do not shrink |
| `RUNNER_VERSION` | empty → latest | Pin for reproducible rebuilds |
| `GH_RUNNER_TOKEN` | empty | Registration token, ~1 h lifetime |
| `GH_RUNNER_PAT` | empty | Enables token refresh, so jobs 2+ can run |

---

## 10. Which path should you change?

| You want to… | Use | Why |
|---|---|---|
| Bake a new baseline package into every future container | `cloud-init/runner.yaml` + recreate | Boot-time is exactly what cloud-init is for |
| Fix something on containers that already exist | `ansible/prepare.yml` | cloud-init cannot reach them |
| Iterate on a package list | Ansible | Fast feedback, no recreate |
| Understand idempotency, handlers, `creates:` | Ansible | That is the whole point |
| Understand datasources and boot ordering | cloud-init + `cloud-init status --long` | Nothing else exposes it as clearly |

Running both is not redundant: cloud-init gets a container usable in one shot with no
control node, Ansible keeps it correct over time. That split — boot-time baseline versus
continuous convergence — is the actual lesson.

---

## 11. Verification checklist

After `sudo ./lab.sh host-prep && ./lab.sh create`:

```bash
sysctl -n kernel.apparmor_restrict_unprivileged_unconfined   # expect 0
incus list                                                    # expect 2 RUNNING with IPv4
incus profile show default                                    # eth0 -> incusbr0, root -> default
incus profile show gh-runner                                  # security.nesting, limits, user-data
incus exec gh-runner-1 -- cloud-init status --long            # expect done
incus exec gh-runner-1 -- getent hosts github.com             # expect an address
```

After provisioning:

```bash
incus exec gh-runner-1 -- psql --version
incus exec gh-runner-1 -- redis-server --version
incus exec gh-runner-1 -- uv --version
incus exec gh-runner-1 -- ruff --version
incus exec gh-runner-1 -- su - ubuntu -c "psql -c 'select current_user'"
incus exec gh-runner-1 -- su - ubuntu -c "redis-cli -s /run/redis/redis-server.sock ping"
```

After `register`:

```bash
./lab.sh status
gh api /repos/OWNER/REPO/actions/runners -q '.runners[] | "\(.name) \(.status)"'
```

The runner shows `online` until it takes one job; with `--ephemeral` it then disappears
from the list and reappears ~10 s later when systemd restarts the unit.

---

## 12. Troubleshooting matrix

| Symptom | Cause | Fix |
|---|---|---|
| `You don't have the needed permissions to talk to the incus daemon` | Shell predates the `incus-admin` membership | `su - $USER` or full re-login; verify `id -nG \| grep incus-admin` |
| Commands inside a container hang, no output | AppArmor restriction on 25.04+ | `sudo ./lab.sh host-prep` |
| `Failed to set up user namespacing` from systemd | No nesting | `security.nesting=true` on the profile |
| `Temporary failure in name resolution` in a container | dnsmasq forwarding to host `127.0.0.53` | `incus network set incusbr0 raw.dnsmasq "server=1.1.1.1"` |
| DNS works, `apt` slow | IPv6 route without working upstream | `incus network set incusbr0 ipv6.nat=true`, or `ipv6.address=none` |
| `cloud-init status` = `error` | A `runcmd` line failed | `incus exec <name> -- tail -50 /var/log/cloud-init-output.log` |
| Edited user-data not applied | cloud-init is one-shot | Recreate, or `cloud-init clean --logs --reboot`, or use Ansible |
| Ansible `UNREACHABLE` | Collection missing, or not in `incus-admin` | `ansible-galaxy collection install -r ansible/requirements.yml` |
| Ansible `become_user: postgres` failure | Incus connection lacks the login environment | Use `runuser -u postgres` (§6.3) |
| Runner registers, then vanishes after one job | `--ephemeral`, as designed | Set `GH_RUNNER_PAT` so the wrapper can mint new tokens |
| `--ephemeral` runner cannot be reconfigured: `Cannot configure the runner because it is already configured` | `--replace` only replaces the *remote* registration; a local `.runner`/`.credentials` still blocks `config.sh` | Delete the local state first: `rm -f .runner .credentials .credentials_rsaparams`. `lab.sh` and `run-ephemeral.sh` both do this |
| Only the first container in a `lab.sh` loop is processed | `incus exec` forwards its stdin, so a command inside `while read … done <<<"$list"` consumes the rest of the list | Iterate an array (`mapfile -t`), as `load_containers` does |
| Job/run stuck `in_progress` while every step shows ✓ | GitHub has not processed the runner's terminal event yet. Ephemeral runners make it likely: the runner deregisters seconds after reporting, so the run aggregate is reconciled lazily. Clock skew produces the same symptom, so check `date -u +%s` inside each container first | Wait 1–5 minutes and re-run `gh run view <id>`; it resolves on its own. `Cannot cancel a workflow run that is completed` from `gh run cancel` confirms the backend already considers it done. Do not re-run the workflow |
| `--replace` needed every run | Stale registration with the same name | Already passed; make sure the token is fresh |

---

## 13. Security posture, stated once

- **Containers are unprivileged.** Root inside maps to your unprivileged host UID; no
  real privilege on the host.
- **`incus-admin` is effectively root on the host.** Members can mount host paths and
  change container security settings. Treat it like `sudo`.
- **No inbound network exposure.** Postgres and Redis listen on unix sockets only; no
  proxy devices; NAT is outbound-only.
- **`security.nesting` widens kernel surface** inside the container. Fine for trusted
  workflows, not for arbitrary PRs from strangers.
- **`raw.dnsmasq` disables AppArmor for that dnsmasq instance.** Prefer fixing host DNS
  if that bothers you.
- **Runner tokens are short-lived by design.** PATs are not — if you store one at
  `/etc/gh-runner/token`, scope it to `administration:write` on that repository only, and
  rotate it.
