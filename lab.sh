#!/usr/bin/env bash
# Lab: GitHub Actions self-hosted runners inside Incus system containers.
# `./lab.sh help` lists the commands; every subcommand is safe to re-run.
set -Eeuo pipefail

# Config, overridable from the environment.
RUNNER_COUNT="${RUNNER_COUNT:-2}"
RUNNER_PREFIX="${RUNNER_PREFIX:-gh-runner}"
PROFILE="${PROFILE:-gh-runner}"
IMAGE="${IMAGE:-images:ubuntu/26.04/cloud}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,incus}"
RUNNER_VERSION="${RUNNER_VERSION:-}"
RUNNER_CPU="${RUNNER_CPU:-4}"
RUNNER_MEM="${RUNNER_MEM:-6GiB}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/opt/actions-runner}"
# Optional PAT the in-container wrapper uses to mint registration tokens.
GH_RUNNER_PAT="${GH_RUNNER_PAT:-}"
# The unit and the runner directory are owned by this user. It must match a
# PostgreSQL role, because peer auth compares the OS user to the role name.
RUNNER_USER="${RUNNER_USER:-ubuntu}"
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLOUD_INIT="${LAB_DIR}/cloud-init/runner.yaml"
APT_PACKAGES=(git curl wget jq unzip zip tar xz-utils zstd ca-certificates
  build-essential libssl-dev libffi-dev python3 python3-dev python3-venv
  python3-pip pipx ripgrep fd-find iproute2 netcat-openbsd rsync
  postgresql redis-server libpq-dev)

# Helpers
log() { printf '[lab] %s\n' "$*"; }
die() { printf '[lab] error: %s\n' "$*" >&2; exit 1; }
require_incus() {
  incus info >/dev/null 2>&1 && return 0
  cat >&2 <<'EOF'
[lab] error: this shell cannot talk to the Incus daemon.
[lab] The login session probably predates the incus-admin group.
[lab] Fix: su - $USER   (or newgrp incus-admin, or a full re-login)
[lab] Verify: id -nG | grep incus-admin
EOF
  exit 1
}

# Prints the existing containers one per line; dies when there are none.
containers() {
  local i found=""
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    if incus info "${RUNNER_PREFIX}-${i}" >/dev/null 2>&1; then
      found+="${RUNNER_PREFIX}-${i}"$'\n'
    fi
  done
  [[ -n "$found" ]] || die "no ${RUNNER_PREFIX}-* containers; run ./lab.sh create first"
  printf '%s' "$found"
}
# Loads the container names into CONTAINERS. Iterating an array is not a style
# choice: incus exec forwards its stdin, so a command inside a `while read` loop
# fed by a here-string swallows the remaining lines of the list.
load_containers() {
  mapfile -t CONTAINERS < <(containers)
  (( ${#CONTAINERS[@]} > 0 )) \
    || die "no ${RUNNER_PREFIX}-* containers; run ./lab.sh create first"
}
wait_for_ipv4() {
  local waited=0 ip=""
  while ((waited < 120)); do
    ip="$(incus list "$1" --format csv -c 4 2>/dev/null | sed -n '1p' | tr -d ' ' || true)"
    [[ -n "$ip" ]] && { log "$1 has ipv4 $ip"; return 0; }
    sleep 2
    waited=$((waited + 2))
  done
  die "timed out after 120s waiting for an IPv4 on $1"
}
resolve_runner_version() {
  local version=""
  # The /releases/latest redirect carries the tag in its Location header, so it
  # resolves the version without spending one of the 60 unauthenticated REST API
  # calls per hour, which is a limit shared with every other container.
  if command -v curl >/dev/null 2>&1; then
    version="$(curl -fsSI -o /dev/null -w '%{redirect_url}' \
      https://github.com/actions/runner/releases/latest 2>/dev/null || true)"
    version="${version##*/}"
  fi
  if [[ -z "$version" ]] && command -v gh >/dev/null 2>&1; then
    version="$(gh release view --repo actions/runner --json tagName -q .tagName 2>/dev/null || true)"
  fi
  if [[ -z "$version" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    version="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest 2>/dev/null \
      | jq -r '.tag_name // empty' || true)"
  fi
  version="${version#v}"
  [[ -n "$version" ]] || die "cannot resolve the runner version: need curl (or gh), or set RUNNER_VERSION"
  printf '%s\n' "$version"
}

# Subcommands
cmd_host_prep() {
  local conf=/etc/sysctl.d/50-incus-apparmor.conf
  local line="kernel.apparmor_restrict_unprivileged_unconfined=0"
  # Ubuntu 25.04+ restricts unprivileged unconfined profiles, which makes
  # commands inside Incus containers hang instead of failing.
  # Source: https://quan.hoabinh.vn/post/2025/11/fix-commands-hanging-in-incus-container-when-host-os-is-ubuntu
  if [[ -f "$conf" ]] && [[ "$(<"$conf")" == "$line" ]]; then
    log "$conf already correct"
  else
    log "writing $conf"
    printf '%s\n' "$line" | sudo tee "$conf" >/dev/null
  fi
  log "reloading sysctl configuration"
  sudo sysctl --system >/dev/null
  printf 'kernel.apparmor_restrict_unprivileged_unconfined=%s\n' \
    "$(sysctl -n kernel.apparmor_restrict_unprivileged_unconfined || true)"
}

cmd_create() {
  local i
  [[ -f "$CLOUD_INIT" ]] || die "missing cloud-init user-data: $CLOUD_INIT"
  incus profile show "$PROFILE" >/dev/null 2>&1 \
    || { log "creating profile $PROFILE"; incus profile create "$PROFILE"; }
  log "setting profile $PROFILE: security.nesting, limits.cpu=$RUNNER_CPU, limits.memory=$RUNNER_MEM"
  incus profile set "$PROFILE" security.nesting true
  incus profile set "$PROFILE" limits.cpu "$RUNNER_CPU"
  incus profile set "$PROFILE" limits.memory "$RUNNER_MEM"
  log "loading cloud-init user-data from $CLOUD_INIT"
  incus profile set "$PROFILE" cloud-init.user-data - <"$CLOUD_INIT"
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    if incus info "${RUNNER_PREFIX}-${i}" >/dev/null 2>&1; then
      log "${RUNNER_PREFIX}-${i} already exists"
    else
      log "launching ${RUNNER_PREFIX}-${i} from $IMAGE"
      incus launch "$IMAGE" "${RUNNER_PREFIX}-${i}" --profile default --profile "$PROFILE"
    fi
  done
  log "waiting for IPv4 addresses"
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    wait_for_ipv4 "${RUNNER_PREFIX}-${i}"
  done
  log "cloud-init user-data is only applied on a container's first boot"
  incus list
}
cmd_toolchain() {
  local name
  load_containers
  for name in "${CONTAINERS[@]}"; do
    log "$name: apt-get update and base toolchain"
    incus exec "$name" -- env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    incus exec "$name" -- env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y -qq "${APT_PACKAGES[@]}"
    log "$name: GitHub CLI from the official apt repository, plus fd and bat symlinks"
    incus exec "$name" -- bash -s <<'GHCLI_EOF'
set -Eeuo pipefail
keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$keyring"
chmod 0644 "$keyring"
printf 'deb [arch=amd64 signed-by=%s] https://cli.github.com/packages stable main\n' \
  "$keyring" > /etc/apt/sources.list.d/github-cli.list
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
if [ -x /usr/bin/fdfind ]; then ln -sf /usr/bin/fdfind /usr/local/bin/fd; fi
if [ -x /usr/bin/batcat ]; then ln -sf /usr/bin/batcat /usr/local/bin/bat; fi
GHCLI_EOF
    log "$name: uv, ruff, Redis unix socket, PostgreSQL role"
    incus exec "$name" -- bash -s <<'TOOLS_EOF'
set -Eeuo pipefail
curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
runuser -u ubuntu -- env HOME=/home/ubuntu /usr/local/bin/uv tool install ruff
if [ -x /home/ubuntu/.local/bin/ruff ]; then
  ln -sf /home/ubuntu/.local/bin/ruff /usr/local/bin/ruff
fi
# Ubuntu's redis-server has no conf.d include: rewrite the two socket
# directives in place. Both seds match the commented and the rewritten line.
install -d -o redis -g redis -m 0775 /run/redis
sed -i -E \
  -e 's|^#?[[:space:]]*unixsocket[[:space:]]+.*|unixsocket /run/redis/redis-server.sock|' \
  -e 's|^#?[[:space:]]*unixsocketperm[[:space:]]+.*|unixsocketperm 766|' \
  /etc/redis/redis.conf
systemctl restart redis-server
# Peer auth over the unix socket: no password is stored anywhere.
if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='ubuntu'\"" | grep -q 1; then
  su postgres -c "psql -c 'CREATE ROLE ubuntu SUPERUSER LOGIN'"
fi
TOOLS_EOF
    log "$name: versions"
    incus exec "$name" -- bash -s <<'VERSIONS_EOF'
git --version; gh --version; python3 --version
psql --version; redis-server --version; uv --version; ruff --version
VERSIONS_EOF
  done
}
cmd_runner() {
  local name version="${RUNNER_VERSION#v}"
  [[ -n "$version" ]] || version="$(resolve_runner_version)"
  log "runner version $version"
  load_containers
  for name in "${CONTAINERS[@]}"; do
    log "$name: unpacking actions-runner-linux-x64-$version.tar.gz in $RUNNER_WORKDIR"
    incus exec "$name" -- bash -s -- "$RUNNER_WORKDIR" "$version" <<'RUNNER_EOF'
set -Eeuo pipefail
mkdir -p "$1"
cd "$1"
url="https://github.com/actions/runner/releases/download/v${2}/actions-runner-linux-x64-${2}.tar.gz"
curl -fsSL -o runner.tar.gz "$url"
tar xzf runner.tar.gz
rm -f runner.tar.gz
./bin/installdependencies.sh
test -x ./bin/Runner.Listener || exit 1
./bin/Runner.Listener --version 2>&1 || true
RUNNER_EOF
    if [[ -n "$RUNNER_USER" ]]; then
      log "$name: chown $RUNNER_WORKDIR to $RUNNER_USER"
      incus exec "$name" -- chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_WORKDIR"
    fi
  done
}
cmd_register() {
  local scope="" kind="repos" token="" url api name
  case "${1:-}" in
    --org) kind="orgs"; shift ;;
    "" | -h | --help)
      printf '%s\n' "usage: ./lab.sh register <owner/repo> [token]" \
        "       ./lab.sh register --org <org> [token]" \
        "the token defaults to \$GH_RUNNER_TOKEN"
      return 1
      ;;
  esac
  scope="${1:-}"
  [[ -n "$scope" ]] || die "usage: ./lab.sh register <owner/repo> [token]"
  token="${2:-${GH_RUNNER_TOKEN:-}}"
  [[ -n "$token" ]] || die "missing registration token (argument or GH_RUNNER_TOKEN)"
  [[ "$token" != *[[:space:]]* ]] \
    || die "registration token contains whitespace; check the command that produced it (gh auth status)"
  url="https://github.com/${scope}"
  api="/${kind}/${scope}/actions/runners/registration-token"
  load_containers
  for name in "${CONTAINERS[@]}"; do
    log "$name: writing /etc/gh-runner/config"
    incus exec "$name" -- mkdir -p /etc/gh-runner
    printf 'GH_URL=%s\nGH_NAME=%s\nGH_DIR=%s\nGH_LABELS=%s\nGH_REG_TOKEN_API=%s\n' \
      "$url" "$name" "$RUNNER_WORKDIR" "$RUNNER_LABELS" "$api" \
      | incus exec "$name" -- tee /etc/gh-runner/config >/dev/null
    log "$name: registering an ephemeral runner against $url"
    # config.sh refuses to run as root, and the generated credentials must be
    # readable by the unit's user, so configure as RUNNER_USER.
    local config_cmd=(bash -s -- "$RUNNER_WORKDIR" "$url" "$token" "$RUNNER_LABELS" "$name")
    if [[ -n "$RUNNER_USER" ]]; then
      incus exec "$name" -- chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_WORKDIR"
      config_cmd=(runuser -u "$RUNNER_USER" -- env "HOME=/home/${RUNNER_USER}" bash -s -- \
        "$RUNNER_WORKDIR" "$url" "$token" "$RUNNER_LABELS" "$name")
    fi
    incus exec "$name" -- "${config_cmd[@]}" <<'CONFIGSH_EOF'
set -Eeuo pipefail
cd "$1"
# config.sh refuses to reconfigure an existing installation, and --replace only
# replaces the remote registration, so the local state has to go first.
rm -f .runner .credentials .credentials_rsaparams
./config.sh --unattended --url "$2" --token "$3" --labels "$4" --name "$5" \
  --work _work --replace --ephemeral
CONFIGSH_EOF
    log "$name: writing $RUNNER_WORKDIR/run-ephemeral.sh"
    incus exec "$name" -- tee "$RUNNER_WORKDIR/run-ephemeral.sh" >/dev/null <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Registers this runner for one job, then runs it. --ephemeral means it
# deregisters after a single job, so every restart needs a fresh token:
# mint one from the API when a PAT exists, else reuse the lab.sh one.
set -Eeuo pipefail
# shellcheck source=/dev/null
. /etc/gh-runner/config
cd "$GH_DIR"
if [ -r /etc/gh-runner/token ] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN="$(cat /etc/gh-runner/token)"
  export GH_TOKEN
  token="$(gh api -X POST "$GH_REG_TOKEN_API" -q .token)"
  # --ephemeral leaves .runner/.credentials behind after the job, and config.sh
  # refuses to reconfigure an existing installation. Clearing both plus the
  # workspace is what makes one-job-per-boot actually clean.
  rm -f .runner .credentials .credentials_rsaparams
  rm -rf _work
  ./config.sh --unattended --url "$GH_URL" --token "$token" \
    --labels "$GH_LABELS" --name "$GH_NAME" --work _work \
    --replace --ephemeral
else
  printf 'run-ephemeral: no PAT in /etc/gh-runner/token, reusing the lab.sh registration\n' >&2
fi
exec ./run.sh
WRAPPER_EOF
    incus exec "$name" -- chmod 0755 "$RUNNER_WORKDIR/run-ephemeral.sh"
    if [[ -n "$GH_RUNNER_PAT" ]]; then
      log "$name: storing the PAT in /etc/gh-runner/token"
      printf '%s\n' "$GH_RUNNER_PAT" \
        | incus exec "$name" -- bash -c 'umask 077; cat >/etc/gh-runner/token'
    fi
    local unit_user=""
    if [[ -n "$RUNNER_USER" ]]; then
      log "$name: chown $RUNNER_WORKDIR and the token to $RUNNER_USER"
      incus exec "$name" -- chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_WORKDIR"
      [[ -n "$GH_RUNNER_PAT" ]] \
        && incus exec "$name" -- chown "${RUNNER_USER}:${RUNNER_USER}" /etc/gh-runner/token
      unit_user="User=${RUNNER_USER}
Group=${RUNNER_USER}"
    fi
    log "$name: enabling gh-runner.service"
    incus exec "$name" -- tee /etc/systemd/system/gh-runner.service >/dev/null <<UNIT_EOF
[Unit]
Description=GitHub Actions self-hosted runner (ephemeral)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$RUNNER_WORKDIR
${unit_user}
ExecStart=$RUNNER_WORKDIR/run-ephemeral.sh
Restart=always
RestartSec=10
TimeoutStopSec=5min
[Install]
WantedBy=multi-user.target
UNIT_EOF
    incus exec "$name" -- systemctl daemon-reload
    incus exec "$name" -- systemctl reset-failed gh-runner.service || true
    incus exec "$name" -- systemctl enable --now gh-runner.service
  done
  cat <<'EOF'
[lab] --ephemeral caveat: the runner deregisters after one job, so every
[lab] restart needs a fresh registration token. run-ephemeral.sh mints one
[lab] from the API only when a PAT is at /etc/gh-runner/token (export
[lab] GH_RUNNER_PAT=... before register); without a PAT only job one runs.
EOF
}
cmd_ansible() {
  local play="${1:-}" inventory="${LAB_DIR}/ansible/inventory.generated.yml"
  local name
  case "$play" in
    prepare | runner) ;;
    "")
      printf '%s\n' "usage: ./lab.sh ansible <prepare|runner> [ansible-playbook args]"
      return 1
      ;;
    *) die "unknown play: $play (use prepare or runner)" ;;
  esac
  shift
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    cat >&2 <<'EOF'
[lab] error: ansible-playbook not found.
[lab] Fix: sudo apt install -y ansible
[lab]      ansible-galaxy collection install -r ansible/requirements.yml
EOF
    exit 1
  fi
  log "installing collections from ansible/requirements.yml (already present ones are skipped)"
  ansible-galaxy collection install -r "${LAB_DIR}/ansible/requirements.yml"
  load_containers
  {
    printf 'all:\n  hosts:\n'
    for name in "${CONTAINERS[@]}"; do
      printf '    %s:\n' "$name"
      printf '      ansible_user: ubuntu\n'
      printf '      ansible_become: true\n'
      printf '      ansible_become_method: sudo\n'
      printf '      ansible_connection: community.general.incus\n'
      printf '      ansible_python_interpreter: /usr/bin/python3\n'
    done
  } >"$inventory"
  log "wrote $inventory"
  log "ansible_incus_project is only needed when this user is not in incus-admin"
  # Resolve on the host so the plays never call the rate-limited GitHub API.
  if [[ "$play" == runner ]] && [[ "${*:-}" != *lab_runner_version* ]] && [[ -z "$RUNNER_VERSION" ]]; then
    local version
    if version="$(resolve_runner_version 2>/dev/null)"; then
      log "resolved runner version $version on the host"
      set -- -e "lab_runner_version=${version}" "$@"
    fi
  fi
  ansible-playbook -i "$inventory" "${LAB_DIR}/ansible/${play}.yml" "$@"
}
cmd_status() {
  local name
  incus list
  load_containers
  for name in "${CONTAINERS[@]}"; do
    printf '%s: gh-runner.service = ' "$name"
    incus exec "$name" -- systemctl is-active gh-runner.service || true
  done
}
cmd_logs() {
  local name="${1:-${RUNNER_PREFIX}-1}"
  incus info "$name" >/dev/null 2>&1 || die "container $name does not exist"
  incus exec "$name" -- journalctl -u gh-runner -n 50 --no-pager
}
cmd_destroy() {
  local assume_yes=false name reply=""
  if [[ $# -gt 0 ]] && [[ "${1:-}" != --yes ]] && [[ "${1:-}" != -y ]]; then
    die "unknown option: $1 (usage: ./lab.sh destroy [--yes])"
  fi
  [[ $# -gt 0 ]] && assume_yes=true
  load_containers
  if [[ "$assume_yes" != true ]]; then
    log "this deletes ${RUNNER_PREFIX}-1..${RUNNER_COUNT} and profile $PROFILE"
    read -r -p "Continue? [y/N] " reply || die "no confirmation on stdin; re-run with --yes"
    [[ "$reply" =~ ^[Yy]$ ]] || { log "aborted"; return 0; }
  fi
  for name in "${CONTAINERS[@]}"; do
    log "deleting $name"
    incus delete --force "$name"
  done
  if incus profile show "$PROFILE" >/dev/null 2>&1; then
    log "deleting profile $PROFILE"
    incus profile delete "$PROFILE"
  fi
}
cmd_help() {
  cat <<'EOF'
Usage: ./lab.sh <command> [args]

  host-prep                      Write the AppArmor sysctl fix (needs sudo)
  create                         Create the Incus profile and launch containers
  toolchain                      Install git, gh, uv, ruff, Postgres, Redis inside
  ansible <prepare|runner>       Same result through Ansible (idempotent)
  runner                         Unpack the runner into RUNNER_WORKDIR
  register <owner/repo> [token]  Register ephemeral runners for a repository
  register --org <org> [token]   Register ephemeral runners for an organisation
  status                         Show containers and gh-runner.service state
  logs [container]               Last 50 journal lines of gh-runner
  destroy [--yes]                Delete the containers and the profile

Two provisioning paths, both runnable on their own:
  cloud-init/runner.yaml   applied by Incus once, at container creation only
  ansible/prepare.yml      re-runnable; repairs a container that already exists

Env overrides: RUNNER_COUNT RUNNER_PREFIX PROFILE IMAGE RUNNER_LABELS
  RUNNER_VERSION RUNNER_CPU RUNNER_MEM RUNNER_WORKDIR RUNNER_USER
  GH_RUNNER_TOKEN (registration token) GH_RUNNER_PAT (token refresh)
Order: sudo ./lab.sh host-prep && ./lab.sh create
  && ./lab.sh toolchain            (or: ./lab.sh ansible prepare)
  && ./lab.sh runner               (or: ./lab.sh ansible runner)
  && ./lab.sh register owner/repo <token>
EOF
}

# Main dispatch
main() {
  local sub="${1:-help}" fn
  [[ $# -gt 0 ]] && shift
  case "$sub" in help | -h | --help) cmd_help; return 0 ;; esac
  fn="cmd_${sub//-/_}"
  if ! declare -F "$fn" >/dev/null; then
    cmd_help
    die "unknown command: $sub"
  fi
  require_incus
  "$fn" "$@"
}
main "$@"