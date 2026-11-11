# Terraform / OpenTofu for this kit — illustrative, not supported

This page exists because people ask for it. It is **documentation only**: the kit ships
two runnable provisioning paths (cloud-init and Ansible) and deliberately does not ship a
third one. Copy the HCL below only if you have decided you want it anyway.

## Why it is not a third path

Three provisioning flows that must stay behaviourally identical is a maintenance
liability, and for this shape Terraform buys little:

| You get | You pay |
|---|---|
| Dependency graph instead of `&&` chains | A state file (and its backup/ignore discipline) |
| `plan` diff before apply | Provider auth plumbing (socket path, project, client certs) |
| Drift detection on profiles | A fourth toolchain next to cloud-init + Ansible |
| CI-reviewable changes | Two sources of truth unless HCL becomes authoritative |

The kit creates ~3 resources on one host. Terraform's value scales with resource count and
environment count; it starts paying off when you add a second host, per-job ephemeral
containers, or a second environment.

Also note what Terraform does **not** solve here: `cloud-init.user-data` runs once at first
boot. A `terraform apply` that changes the user-data string on an existing instance reports
success and changes nothing inside it. Convergence still belongs to Ansible.

## Provider facts (verified 2026-11)

| Item | Value |
|---|---|
| Registry name | `lxc/incus` |
| Latest release | v1.2.1, 2026-10-14 |
| Also available at | `registry.opentofu.org` (same SHA) |
| Ancestor | `terraform-lxd/lxd` (forked into the `lxc` org, Dec 2023) |
| Registry tier | community, but maintained by the `lxc` org |
| Builds against | `github.com/lxc/incus/v7` since v1.1.1; 6.x is expected to work, not CI-proven |

Upstream Incus docs recommend exactly this split: Terraform/OpenTofu for infrastructure,
Ansible for workloads — <https://linuxcontainers.org/incus/docs/main/third_party/>.

## Minimal skeleton

```hcl
terraform {
  required_version = ">= 1.5"   # OpenTofu >= 1.10
  required_providers {
    incus = { source = "lxc/incus", version = "~> 1.2" }
  }
}

provider "incus" {}   # local unix socket by default

resource "incus_profile" "runner" {
  name = "python-fastapi"

  config = {
    "security.nesting"    = "true"
    "limits.cpu"          = "4"
    "limits.memory"       = "6GiB"
    "cloud-init.user-data" = file("${path.module}/../cloud-init/user-data.yaml")
  }
}

resource "incus_instance" "runner" {
  count    = 2
  name     = "python-fastapi-${count.index + 1}"
  image    = "images:ubuntu/26.04/cloud"
  profiles = ["default", incus_profile.runner.name]

  wait_for {
    type = "cloud-init"
  }
}
```

`file()` reads the artifact produced by `scripts/render.py`, so the profile YAML stays the
single source of truth. Do not paste a second copy of the packages into HCL.

## Gotchas that cost time

- **`wait_for { type = "cloud-init" }`** exists since v1.1.0 (2026-05-08). Without it,
  `apply` returns before first boot finishes and your first Ansible run races `apt`.
- **Import needs the image.** `terraform import incus_instance.x <project>/<name>,image=images:ubuntu/26.04/cloud`.
  Omit `image=` and the next apply **replaces** the instance.
- **State holds the full user-data string.** Never put a runner token there.
- **No SSH in the stock images.** `remote-exec` provisioners fail; use the instance's
  `file` and `exec` blocks (create-time, via the Incus API) or Ansible.
- **Auth:** the provider uses the local unix socket, or client certs from
  `$XDG_CONFIG_HOME/incus`. Running Terraform as root while `incus` was initialised as your
  user is the classic 20-minute yak shave.
- **Project scoping** is per resource; create the project first (`incus_project`).
- Config edits on a running instance are a live `PUT`; the provider only restarts on a
  `running` attribute change. `security.nesting` and `limits.*` are live-updatable, so this
  kit's keys are fine — do not assume that for every key.

## The Incus-native alternative

Before reaching for Terraform, note that Incus already has a declarative, idempotent
config layer:

```bash
incus admin init --preseed < preseed.yaml
```

Preseed accepts daemon config, storage pools, networks, projects and **profiles**, merges
with existing entities on re-run, and rolls back on conflict. It does not create
instances — profiles + `incus launch` still do that — but it removes most of the reason to
introduce a state file for a single-host lab.

<https://linuxcontainers.org/incus/docs/main/howto/initialize/#non-interactive-configuration>
