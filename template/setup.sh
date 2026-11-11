#!/usr/bin/env bash
# Runner template kit: render a requirements profile, create the Incus
# containers, converge them with Ansible and register ephemeral GitHub Actions
# runners. Every subcommand is safe to re-run. `./setup.sh help` lists them.
set -Eeuo pipefail

KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLAYBOOK_DIR="${KIT_DIR}/ansible"
VARS_FILE="${PLAYBOOK_DIR}/vars/generated.yml"
INVENTORY_FILE="${PLAYBOOK_DIR}/inventory.generated.yml"
CLOUD_INIT_FILE="${KIT_DIR}/cloud-init/user-data.yaml"
RENDERER="${KIT_DIR}/scripts/render.py"

# Fixed by ansible/runner.yml and the unit this script writes.
RUNNER_DIR=/opt/actions-runner
SERVICE_NAME=gh-runner.service

# Config, overridable from the environment. GEN_*, CONTAINER_PREFIX and
# INCUS_PROFILE are filled in by load_vars() from the rendered profile.
KIT_PYTHON="${KIT_PYTHON:-python3}"
CONTAINER_COUNT="${CONTAINER_COUNT:-2}"
CONTAINER_CPU="${CONTAINER_CPU:-4}"
CONTAINER_MEM="${CONTAINER_MEM:-6GiB}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-}"
INCUS_PROFILE="${INCUS_PROFILE:-}"
GH_RUNNER_TOKEN="${GH_RUNNER_TOKEN:-}"
GH_RUNNER_PAT="${GH_RUNNER_PAT:-}"
# No architecture label is added: the same profile runs on amd64 and arm64.
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,incus}"
GEN_NAME=""
GEN_IMAGE=""
GEN_RUNNER_USER=""
# Host temp file holding the registration token, removed by cmd_register's
# cleanup trap, along with any container copy it left behind.
REG_TOKEN_FILE=""
REG_TOKEN_CONTAINERS=()
CONTAINERS=()
EXISTING=()

log() { printf '[setup] %s\n' "$*"; }
die() { printf '[setup] error: %s\n' "$*" >&2; exit 1; }

# Picks an interpreter for the renderer. KIT_PYTHON may name one without
# PyYAML, so the fallback is tried before giving up.
resolve_python() {
  if "$KIT_PYTHON" -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import yaml' >/dev/null 2>&1; then
    KIT_PYTHON=/usr/bin/python3
    return 0
  fi
  cat >&2 <<'EOF'
[setup] error: no Python interpreter with PyYAML was found.
[setup] The renderer needs it to read the profile and the generated vars.
[setup] Fix: sudo apt install -y python3-yaml
[setup]      or: export KIT_PYTHON=/path/to/python3-with-pyyaml
EOF
  exit 1
}

# Prints one key of the rendered vars file. Parsing with PyYAML keeps the value
# byte-exact; grep would turn quoting and empty strings into guesswork.
read_var() {
  "$KIT_PYTHON" - "$VARS_FILE" "$1" <<'PY'
import sys

import yaml

path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
except OSError as exc:
    sys.stderr.write(f"cannot read {path}: {exc.strerror}\n")
    raise SystemExit(1)
sys.stdout.write(str(data.get(key, "")))
PY
}

# Fills GEN_*, CONTAINER_PREFIX, INCUS_PROFILE and CONTAINERS from the rendered
# profile, so nothing downstream carries a project-specific name.
load_vars() {
  resolve_python
  [[ -f "$VARS_FILE" ]] \
    || die "missing rendered vars ${VARS_FILE}; next: ./setup.sh render requirements/minimal.yml"
  GEN_NAME="$(read_var gen_name)"
  GEN_IMAGE="$(read_var gen_image)"
  GEN_RUNNER_USER="$(read_var gen_runner_user)"
  [[ -n "$GEN_NAME" && -n "$GEN_IMAGE" && -n "$GEN_RUNNER_USER" ]] \
    || die "generated.yml has no gen_name/gen_image/gen_runner_user; next: re-render it with ./setup.sh render <profile>"
  [[ "$CONTAINER_COUNT" =~ ^[0-9]+$ ]] && (( CONTAINER_COUNT > 0 )) \
    || die "CONTAINER_COUNT='${CONTAINER_COUNT}' is not a positive integer; next: export CONTAINER_COUNT=2"
  CONTAINER_PREFIX="${CONTAINER_PREFIX:-$GEN_NAME}"
  INCUS_PROFILE="${INCUS_PROFILE:-$GEN_NAME}"
  CONTAINERS=()
  local i
  for ((i = 1; i <= CONTAINER_COUNT; i++)); do
    CONTAINERS+=("${CONTAINER_PREFIX}-${i}")
  done
  # Both checks run here, so every subcommand refuses a shared profile or an
  # impossible container name before it touches the daemon.
  require_kit_profile_name
  require_container_names
}

# Incus's own rule for a profile name: lowercase, no trailing hyphen, 63 at most.
# It is deliberately looser than the renderer's 60-character gen_name cap, which
# has to leave room for the "-<n>" container suffix.
PROFILE_NAME_PATTERN='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
# Profiles the kit must never take over: `default` ships with Incus, and
# `docker` is the conventional name for a profile many hosts already share.
RESERVED_PROFILES=(default docker)
# Incus allows 63 characters for an instance name, which must end in a letter
# or a digit. Every generated name is <prefix>-<n>.
CONTAINER_NAME_MAX=63

# The longest suffix is CONTAINER_COUNT, so the last generated name decides
# whether the whole set fits.
require_container_names() {
  local name
  for name in "${CONTAINERS[@]}"; do
    (( ${#name} <= CONTAINER_NAME_MAX )) \
      || die "container name '${name}' is ${#name} characters, but Incus allows at most ${CONTAINER_NAME_MAX}. Names are <CONTAINER_PREFIX>-<n> with CONTAINER_PREFIX='${CONTAINER_PREFIX}' and CONTAINER_COUNT=${CONTAINER_COUNT}; next: shorten CONTAINER_PREFIX or lower CONTAINER_COUNT"
    [[ "$name" =~ [a-z0-9]$ ]] \
      || die "container name '${name}' must end in a letter or digit; next: export CONTAINER_PREFIX=<prefix without a trailing hyphen>"
  done
}

profile_exists() { incus profile show "$1" >/dev/null 2>&1; }

# Value of the ownership marker on a profile, empty when it has none.
profile_marker() { incus profile get "$1" user.kit 2>/dev/null || true; }

require_kit_profile_name() {
  local reserved
  [[ "$INCUS_PROFILE" =~ $PROFILE_NAME_PATTERN ]] \
    || die "INCUS_PROFILE='${INCUS_PROFILE}' is not an Incus-safe name; it must match ${PROFILE_NAME_PATTERN} (lowercase letters, digits and hyphens, no trailing hyphen, at most 63 characters); next: export INCUS_PROFILE=<name>"
  for reserved in "${RESERVED_PROFILES[@]}"; do
    [[ "$INCUS_PROFILE" != "$reserved" ]] \
      || die "INCUS_PROFILE='${INCUS_PROFILE}' is a shared profile the kit does not own; next: export INCUS_PROFILE=<your-kit-name>"
  done
}

# Every profile the kit creates carries user.kit=<gen_name>. create, destroy and
# every command that runs inside a container refuse a profile without the
# marker: taking it over would change every container that shares it, including
# other kits' containers. The check is cached because each subcommand asks for
# it once per container.
PROFILE_OWNERSHIP_CHECKED=0
require_owned_profile() {
  if (( PROFILE_OWNERSHIP_CHECKED == 1 )); then
    return 0
  fi
  require_kit_profile_name
  if profile_exists "$INCUS_PROFILE"; then
    local marker
    marker="$(profile_marker "$INCUS_PROFILE")"
    [[ "$marker" == "$GEN_NAME" ]] \
      || die "profile '${INCUS_PROFILE}' exists and is marked user.kit='${marker:-none}', not '${GEN_NAME}', so it belongs to another kit or to you. Refusing to adopt it automatically. If an earlier version of this kit created it, adopt it once and re-run: incus profile set ${INCUS_PROFILE} user.kit ${GEN_NAME}"
  fi
  PROFILE_OWNERSHIP_CHECKED=1
}

require_incus() {
  if incus info >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<'EOF'
[setup] error: this shell cannot talk to the Incus daemon.
[setup] The login session probably predates the incus-admin group.
[setup] Fix: su - "$USER"   (or a full re-login)
[setup] Verify: id -nG | grep incus-admin
EOF
  exit 1
}

require_ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<'EOF'
[setup] error: ansible-playbook was not found on this host.
[setup] Fix: sudo apt install -y ansible
[setup] Then re-run this command; it installs the collections itself.
EOF
  exit 1
}

container_exists() { incus info "$1" >/dev/null 2>&1; }

# Reads a container's status and profile membership in one Incus call, so the
# ownership check does not pay for two round trips. Prints `status=<state>`
# followed by one `profile=<name>` line per attached profile.
read_container_facts() {
  incus list "$1" --format json | "$KIT_PYTHON" -c '
import json
import sys

data = json.load(sys.stdin)
if not data:
    raise SystemExit(1)
print("status=" + str(data[0].get("status", "")))
for profile in data[0].get("profiles") or ():
    print("profile=" + str(profile))
'
}

# A name match is not ownership: a container launched by hand can carry the same
# name. The kit's containers are the ones attached to INCUS_PROFILE, and that
# profile must carry the kit's marker, so every subcommand that acts inside a
# container checks both. The facts land in CONTAINER_FACTS because a command
# substitution would run die() in a subshell.
CONTAINER_FACTS=""
require_owned_container() {
  local name="$1"
  CONTAINER_FACTS="$(read_container_facts "$name")" \
    || die "cannot read ${name} from Incus; next: incus list ${name} --format json"
  grep -qxF -- "profile=${INCUS_PROFILE}" <<<"$CONTAINER_FACTS" \
    || die "container '${name}' exists but does not use profile '${INCUS_PROFILE}', so it is not this kit's. Refusing to adopt it. Next: incus delete --force ${name}   (or export CONTAINER_PREFIX=<a free prefix>)"
  # Membership is not ownership either: a profile someone else made can carry
  # the kit's containers, so the marker is checked before anything runs inside
  # them.
  require_owned_profile
}

# Keeps only containers that exist, so a half-created lab does not produce an
# UNREACHABLE host and a confusing failure.
collect_existing_containers() {
  local name
  EXISTING=()
  for name in "${CONTAINERS[@]}"; do
    if container_exists "$name"; then
      require_owned_container "$name"
      EXISTING+=("$name")
    fi
  done
}

load_existing_containers() {
  collect_existing_containers
  (( ${#EXISTING[@]} > 0 )) \
    || die "none of ${CONTAINERS[*]} exist; next: ./setup.sh create"
  # A stopped container fails the Incus connection and every later `incus exec`
  # with an error that names nothing useful, so it is started here instead.
  local name
  for name in "${EXISTING[@]}"; do
    require_owned_container "$name"
    if grep -qxF 'status=Running' <<<"$CONTAINER_FACTS"; then
      continue
    fi
    log "$name is not running; starting it"
    incus start "$name"
    wait_for_ipv4 "$name"
  done
}

wait_for_ipv4() {
  local waited=0 ip=""
  while (( waited < 120 )); do
    ip="$(incus list "$1" --format csv -c 4 2>/dev/null | sed -n '1p' | tr -d ' ' || true)"
    if [[ -n "$ip" ]]; then
      log "$1 has ipv4 $ip"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  die "no IPv4 address on $1 after 120s; next: incus info $1 , then check the bridge with incus network list"
}

# Prints the latest release tag, or nothing when the host cannot resolve it.
# The /releases/latest redirect carries the tag in its Location header, which
# is not subject to the 60-calls-per-hour unauthenticated REST API budget.
resolve_runner_version() {
  local version=""
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
  printf '%s\n' "${version#v}"
}

# Reads the profile path recorded in the header of the rendered vars file, so
# `render --check` can verify the artifacts without being told the profile.
rendered_profile() {
  "$KIT_PYTHON" - "$VARS_FILE" <<'PY'
import re
import sys

pattern = re.compile(r"^# Generated by scripts/render\.py from (.+)\.$", re.MULTILINE)
with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()
match = pattern.search(text)
sys.stdout.write(match.group(1) if match else "")
PY
}

# Removes the host copy of the registration token and, belt and braces, any copy
# a failed register left inside a container. Installed as cmd_register's EXIT
# trap so a die() halfway through cannot leave the token on disk.
cleanup_reg_token() {
  if [[ -n "${REG_TOKEN_FILE}" ]]; then
    rm -f "${REG_TOKEN_FILE}"
  fi
  local container
  for container in "${REG_TOKEN_CONTAINERS[@]}"; do
    incus exec "$container" -- rm -f /run/gh-reg-token >/dev/null 2>&1 || true
  done
}

# Prints the host-side sysctl command that mirrors the profile's kernel
# tunables, or nothing when the profile sets none. Some tunables cannot be set
# from inside a container, so the host is where the operator has to act.
host_sysctl_command() {
  "$KIT_PYTHON" - "$VARS_FILE" <<'PY'
import shlex
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}
pairs = [
    shlex.quote(f"{key}={value}")
    for key, value in (data.get("gen_sysctl") or {}).items()
]
if pairs:
    sys.stdout.write("sudo sysctl " + " ".join(pairs))
PY
}

write_inventory() {
  local name
  log "writing ${INVENTORY_FILE}"
  {
    printf 'all:\n  hosts:\n'
    for name in "${EXISTING[@]}"; do
      printf '    %s:\n' "$name"
      printf '      ansible_user: %s\n' "$GEN_RUNNER_USER"
      printf '      ansible_become: true\n'
      printf '      ansible_become_method: sudo\n'
      printf '      ansible_connection: community.general.incus\n'
      printf '      ansible_python_interpreter: /usr/bin/python3\n'
    done
  } >"${INVENTORY_FILE}"
}

install_collections() {
  log "installing collections from ansible/requirements.yml (present ones are skipped)"
  ansible-galaxy collection install -r "${PLAYBOOK_DIR}/requirements.yml"
}

# Subcommands
cmd_render() {
  resolve_python
  local profile="" check=0 arg
  for arg in "$@"; do
    case "$arg" in
      --check) check=1 ;;
      -*) die "unknown render option '${arg}'; next: ./setup.sh render <profile> [--check]" ;;
      *)
        [[ -z "$profile" ]] || die "render takes one profile, got '${profile}' and '${arg}'; next: ./setup.sh render requirements/minimal.yml"
        profile="$arg"
        ;;
    esac
  done
  if [[ -z "$profile" ]]; then
    (( check == 1 )) \
      || die "render needs a profile; next: ./setup.sh render requirements/minimal.yml   (or ./setup.sh render --check after one render)"
    [[ -f "$VARS_FILE" ]] \
      || die "nothing rendered yet, so there is nothing to check; next: ./setup.sh render requirements/minimal.yml"
    profile="$(rendered_profile)"
    [[ -n "$profile" ]] \
      || die "cannot tell which profile ${VARS_FILE} was rendered from; next: ./setup.sh render requirements/minimal.yml"
  fi
  if (( check == 1 )); then
    "$KIT_PYTHON" "$RENDERER" --profile "$profile" --check
  else
    "$KIT_PYTHON" "$RENDERER" --profile "$profile"
  fi
}

cmd_create() {
  load_vars
  require_incus
  [[ -f "$CLOUD_INIT_FILE" ]] \
    || die "missing rendered cloud-init ${CLOUD_INIT_FILE}; next: ./setup.sh render requirements/minimal.yml"
  require_owned_profile
  if ! profile_exists "$INCUS_PROFILE"; then
    log "creating profile $INCUS_PROFILE"
    incus profile create "$INCUS_PROFILE"
    # The marker is what makes the profile provably this kit's on every later
    # create/destroy; it is read back by require_owned_profile.
    incus profile set "$INCUS_PROFILE" user.kit "$GEN_NAME"
  fi
  log "setting $INCUS_PROFILE: security.nesting, limits.cpu=$CONTAINER_CPU, limits.memory=$CONTAINER_MEM"
  # security.nesting is what lets systemd's PrivateUsers= services (Redis,
  # among others) create a nested user namespace inside the container.
  incus profile set "$INCUS_PROFILE" security.nesting true
  incus profile set "$INCUS_PROFILE" limits.cpu "$CONTAINER_CPU"
  incus profile set "$INCUS_PROFILE" limits.memory "$CONTAINER_MEM"
  log "loading cloud-init user-data from $CLOUD_INIT_FILE"
  incus profile set "$INCUS_PROFILE" cloud-init.user-data - <"$CLOUD_INIT_FILE"
  local name status_out status_rc sysctl_hint
  for name in "${CONTAINERS[@]}"; do
    if container_exists "$name"; then
      require_owned_container "$name"
      if grep -qxF 'status=Running' <<<"$CONTAINER_FACTS"; then
        log "$name already exists"
      else
        log "$name exists but is stopped; starting it"
        incus start "$name"
      fi
      continue
    fi
    log "launching $name from $GEN_IMAGE"
    incus launch "$GEN_IMAGE" "$name" --profile default --profile "$INCUS_PROFILE"
  done
  for name in "${CONTAINERS[@]}"; do
    wait_for_ipv4 "$name"
  done
  for name in "${CONTAINERS[@]}"; do
    log "$name: waiting for cloud-init (up to 15 minutes)"
    status_rc=0
    status_out="$(timeout 900 incus exec "$name" -- cloud-init status --wait 2>&1)" \
      || status_rc=$?
    if (( status_rc != 0 )) || [[ "$status_out" != *"status: done"* ]]; then
      if (( status_rc == 124 )); then
        printf '[setup] error: cloud-init did not finish inside %s within 900s\n' "$name" >&2
      else
        printf '[setup] error: cloud-init did not finish cleanly inside %s\n' "$name" >&2
      fi
      printf '[setup] ---------- tail of /var/log/cloud-init-output.log ----------\n' >&2
      timeout -k 10 60 incus exec "$name" -- \
        tail -n 40 /var/log/cloud-init-output.log >&2 || true
      printf '[setup] ------------------------------------------------------------\n' >&2
      sysctl_hint="$(host_sysctl_command)"
      if [[ -n "$sysctl_hint" ]]; then
        printf '[setup] A kernel tunable in the profile may have to be set on the host: %s\n' "$sysctl_hint" >&2
      fi
      printf '[setup] Next: fix the profile or the container network, then ./setup.sh destroy --yes && ./setup.sh create\n' >&2
      exit 1
    fi
  done
  # The image, not the profile, decides whether the account exists. Failing here
  # names the field instead of leaving it to a later step.
  for name in "${CONTAINERS[@]}"; do
    timeout -k 10 60 incus exec "$name" -- getent passwd "$GEN_RUNNER_USER" \
      >/dev/null 2>&1 \
      || die "runner_user '${GEN_RUNNER_USER}' does not exist inside ${name}; next: set runner_user in the profile to an account the image provides"
  done
  log "cloud-init user-data is applied on a container's first boot only"
  incus list
}

cmd_prepare() {
  load_vars
  require_ansible
  require_incus
  load_existing_containers
  write_inventory
  install_collections
  ansible-playbook -i "${INVENTORY_FILE}" "${PLAYBOOK_DIR}/prepare.yml" "$@"
}

cmd_runner() {
  load_vars
  require_ansible
  require_incus
  load_existing_containers
  write_inventory
  install_collections
  local -a extra=("$@")
  local version
  # Resolved here, once, so the play does not spend the shared GitHub API
  # budget from every container. The play still resolves on its own when this
  # host has no way out.
  if [[ "${extra[*]:-}" != *kit_runner_version* ]]; then
    version="$(resolve_runner_version)"
    if [[ -n "$version" ]]; then
      log "resolved runner version $version on this host"
      extra=(-e "kit_runner_version=${version}" "${extra[@]}")
    else
      log "could not resolve the runner version here; the play will try the release redirect itself"
    fi
  fi
  ansible-playbook -i "${INVENTORY_FILE}" "${PLAYBOOK_DIR}/runner.yml" "${extra[@]}"
}

cmd_register() {
  local kind="repos" scope="" token="" url api=""
  case "${1:-}" in
    --org)
      kind="orgs"
      shift
      ;;
    "" | -h | --help)
      printf '%s\n' \
        "usage: ./setup.sh register <owner/repo> [token]" \
        "       ./setup.sh register --org <org> [token]" \
        "the token defaults to \$GH_RUNNER_TOKEN"
      return 1
      ;;
  esac
  load_vars
  scope="${1:-}"
  [[ -n "$scope" ]] \
    || die "register needs a scope; next: ./setup.sh register <owner/repo> [token]"
  # Validated before it reaches a URL, a file and the API path. --org strips the
  # slash, so the second group is optional.
  [[ "$scope" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ ]] \
    || die "scope '${scope}' is not a GitHub owner/repo or org name; next: ./setup.sh register <owner/repo> [token]   (or ./setup.sh register --org <org> [token])"
  token="${2:-${GH_RUNNER_TOKEN:-}}"
  [[ -n "$token" ]] \
    || die "no registration token. A registration token expires after one hour, so mint a fresh one: export GH_RUNNER_TOKEN=\$(gh api -X POST /${kind}/${scope}/actions/runners/registration-token -q .token)"
  [[ "$token" != *[[:space:]]* ]] \
    || die "the registration token contains whitespace; next: mint a fresh one with 'gh api -X POST /${kind}/${scope}/actions/runners/registration-token -q .token'"
  require_incus
  # Also the B6 guard: nothing to configure is an error, not a silent success.
  load_existing_containers
  url="https://github.com/${scope}"
  api="/${kind}/${scope}/actions/runners/registration-token"
  # The token reaches the container as a 0600 file, never as an argument:
  # `incus exec` argv is visible to every local user through ps and lands in
  # audit logs, and the token stays valid for an hour.
  REG_TOKEN_FILE="$(mktemp)"
  REG_TOKEN_CONTAINERS=()
  trap cleanup_reg_token EXIT
  printf '%s\n' "$token" >"$REG_TOKEN_FILE"
  local name group home account
  for name in "${EXISTING[@]}"; do
    REG_TOKEN_CONTAINERS+=("$name")
    if ! incus exec "$name" -- test -x "${RUNNER_DIR}/config.sh" >/dev/null 2>&1; then
      die "${name} has no runner binaries at ${RUNNER_DIR}; next: ./setup.sh runner"
    fi
    # One getent read gives the account, its home and its primary group: images
    # routinely name the group differently and place the home elsewhere.
    account="$(incus exec "$name" -- getent passwd "$GEN_RUNNER_USER" 2>/dev/null)" \
      || die "the runner user '${GEN_RUNNER_USER}' does not exist inside ${name}; next: set runner_user in the profile to an account the image provides"
    group="$(incus exec "$name" -- id -gn "$GEN_RUNNER_USER" 2>/dev/null)" \
      || die "the runner user '${GEN_RUNNER_USER}' has no primary group inside ${name}"
    home="$(printf '%s\n' "$account" | cut -d: -f6)"
    [[ -n "$home" ]] \
      || die "${name}: getent passwd ${GEN_RUNNER_USER} has no home directory; next: fix the account in the image"
    # A running unit would re-register with the credentials the next step
    # deletes, and would race the new registration. A non-zero exit here is
    # expected when the unit does not exist yet (a first register), so the
    # state is verified instead of the exit code being trusted.
    log "$name: stopping ${SERVICE_NAME} before replacing its registration"
    incus exec "$name" -- systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    if incus exec "$name" -- systemctl is-active --quiet "$SERVICE_NAME" \
        >/dev/null 2>&1; then
      die "${SERVICE_NAME} is still active inside ${name}; it would re-register with the credentials this command deletes. Next: incus exec ${name} -- systemctl stop ${SERVICE_NAME}, then re-run ./setup.sh register"
    fi
    log "$name: writing /etc/gh-runner/config"
    incus exec "$name" -- mkdir -p /etc/gh-runner
    # %q, not the raw value: the wrapper is bash and sources this file, so a
    # label containing a space survives and no value can break the line.
    {
      printf 'GH_URL=%q\n' "$url"
      printf 'GH_NAME=%q\n' "$name"
      printf 'GH_DIR=%q\n' "$RUNNER_DIR"
      printf 'GH_LABELS=%q\n' "$RUNNER_LABELS"
      printf 'GH_REG_TOKEN_API=%q\n' "$api"
    } | incus exec "$name" -- tee /etc/gh-runner/config >/dev/null
    log "$name: registering an ephemeral runner against $url"
    incus exec "$name" -- chown -R "${GEN_RUNNER_USER}:${group}" "$RUNNER_DIR"
    incus file push --mode 0600 "$REG_TOKEN_FILE" "${name}/run/gh-reg-token"
    # config.sh refuses to run as root and accepts the token only as an
    # argument, so the token is the one value this call cannot keep off argv.
    incus exec "$name" -- bash -s -- \
      "$RUNNER_DIR" "$url" "$RUNNER_LABELS" "$name" "$GEN_RUNNER_USER" "$home" \
      <<'CONFIGSH_EOF'
set -Eeuo pipefail
cd "$1"
IFS= read -r token </run/gh-reg-token
rm -f /run/gh-reg-token
# config.sh refuses to reconfigure an existing installation, and --replace only
# replaces the remote registration, so the local state has to go first.
rm -f .runner .credentials .credentials_rsaparams
runuser -u "$5" -- env "HOME=$6" ./config.sh --unattended --url "$2" \
  --token "$token" --labels "$3" --name "$4" --work _work \
  --replace --ephemeral
CONFIGSH_EOF
    log "$name: writing ${RUNNER_DIR}/run-ephemeral.sh"
    incus exec "$name" -- tee "${RUNNER_DIR}/run-ephemeral.sh" >/dev/null <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Registers this runner for one job, then runs it. --ephemeral means it
# deregisters after a single job, so every restart needs a fresh token: mint
# one from the API when a PAT exists, else reuse the registration setup.sh made.
set -Eeuo pipefail
# Sourced before the kit config so the kit's assignments always win over
# whatever the profile exported. The unit already reads this file through
# EnvironmentFile=; sourcing it here keeps a hand-run wrapper identical.
if [ -r /etc/runner-env.sh ]; then
  set -a
  # shellcheck source=/dev/null
  . /etc/runner-env.sh
  set +a
fi
# shellcheck source=/dev/null
. /etc/gh-runner/config
cd "$GH_DIR"
if [ -r /etc/gh-runner/token ] && command -v gh >/dev/null 2>&1; then
  # GH_TOKEN is set for this one command only. Exporting it would hand the PAT
  # to config.sh and to every job step.
  if token="$(GH_TOKEN="$(cat /etc/gh-runner/token)" \
      gh api -X POST "$GH_REG_TOKEN_API" -q .token)" \
      && [ -n "$token" ]; then
    # --ephemeral leaves .runner/.credentials behind after the job, and config.sh
    # refuses to reconfigure an existing installation. Clearing both plus the
    # workspace is what makes one-job-per-boot actually clean.
    rm -f .runner .credentials .credentials_rsaparams
    rm -rf _work
    ./config.sh --unattended --url "$GH_URL" --token "$token" \
      --labels "$GH_LABELS" --name "$GH_NAME" --work _work \
      --replace --ephemeral
  else
    printf 'run-ephemeral: could not mint a token, reusing the setup.sh registration\n' >&2
  fi
elif [ -r /etc/gh-runner/token ]; then
  printf 'run-ephemeral: gh is not installed, reusing the setup.sh registration\n' >&2
else
  printf 'run-ephemeral: no PAT at /etc/gh-runner/token, reusing the setup.sh registration\n' >&2
fi
exec ./run.sh
WRAPPER_EOF
    incus exec "$name" -- chmod 0755 "${RUNNER_DIR}/run-ephemeral.sh"
    if [[ -n "$GH_RUNNER_PAT" ]]; then
      log "$name: storing the PAT in /etc/gh-runner/token"
      # install(1) sets the mode as it creates the file, so there is no window
      # in which the PAT is readable by anyone else.
      printf '%s\n' "$GH_RUNNER_PAT" \
        | incus exec "$name" -- install -m 600 /dev/stdin /etc/gh-runner/token
      incus exec "$name" -- chown "${GEN_RUNNER_USER}:${group}" /etc/gh-runner/token
    else
      # A PAT left over from an earlier run would keep the refresh path alive
      # after the operator stopped providing one.
      incus exec "$name" -- rm -f /etc/gh-runner/token
    fi
    log "$name: writing /etc/systemd/system/${SERVICE_NAME}"
    incus exec "$name" -- tee "/etc/systemd/system/${SERVICE_NAME}" >/dev/null <<UNIT_EOF
[Unit]
Description=GitHub Actions self-hosted runner (ephemeral)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${RUNNER_DIR}
User=${GEN_RUNNER_USER}
Group=${group}
EnvironmentFile=-/etc/runner-env.sh
ExecStart=${RUNNER_DIR}/run-ephemeral.sh
Restart=always
RestartSec=10
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
UNIT_EOF
    incus exec "$name" -- systemctl daemon-reload
    incus exec "$name" -- systemctl reset-failed "$SERVICE_NAME" || true
    # enable then restart: restart starts a stopped unit, and reloads the labels
    # and scope that were just written into a unit that is already running.
    incus exec "$name" -- systemctl enable "$SERVICE_NAME"
    incus exec "$name" -- systemctl restart "$SERVICE_NAME"
  done
  cat >&2 <<'EOF'
[setup] --ephemeral caveat: the runner deregisters after one job, so every
[setup] restart needs a fresh token. run-ephemeral.sh mints one from the API
[setup] only when a PAT is at /etc/gh-runner/token (export GH_RUNNER_PAT=...
[setup] before register); without a PAT only the first job runs.
EOF
}

cmd_status() {
  load_vars
  require_incus
  incus list
  collect_existing_containers
  if (( ${#EXISTING[@]} == 0 )); then
    log "none of ${CONTAINERS[*]} exist; next: ./setup.sh create"
    return 0
  fi
  local name state
  for name in "${EXISTING[@]}"; do
    state="$(incus exec "$name" -- systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    printf '%s: %s = %s\n' "$name" "$SERVICE_NAME" "${state:-unknown}"
  done
}

cmd_logs() {
  load_vars
  require_incus
  local name="${1:-${CONTAINERS[0]}}"
  container_exists "$name" \
    || die "container $name does not exist; next: ./setup.sh status"
  require_owned_container "$name"
  incus exec "$name" -- journalctl -u "$SERVICE_NAME" -n 50 --no-pager
}

cmd_destroy() {
  load_vars
  require_incus
  # Before any deletion: a foreign profile means these containers are not the
  # kit's to remove either.
  require_owned_profile
  local assume_yes=0 reply="" name
  if (( $# > 0 )); then
    case "${1:-}" in
      --yes | -y) assume_yes=1 ;;
      *) die "unknown destroy option '${1:-}'; next: ./setup.sh destroy [--yes]" ;;
    esac
  fi
  collect_existing_containers
  if (( assume_yes == 0 )); then
    if (( ${#EXISTING[@]} == 0 )) && ! incus profile show "$INCUS_PROFILE" >/dev/null 2>&1; then
      log "no containers and no profile $INCUS_PROFILE: nothing to delete"
      return 0
    fi
    log "this deletes ${EXISTING[*]:-nothing} and the profile $INCUS_PROFILE"
    read -r -p "Continue? [y/N] " reply || die "no confirmation on stdin; next: ./setup.sh destroy --yes"
    [[ "$reply" =~ ^[Yy]$ ]] || { log "aborted"; return 0; }
  fi
  for name in "${EXISTING[@]}"; do
    log "deleting $name"
    incus delete --force "$name"
  done
  if incus profile show "$INCUS_PROFILE" >/dev/null 2>&1; then
    log "deleting profile $INCUS_PROFILE"
    incus profile delete "$INCUS_PROFILE"
  fi
}

cmd_help() {
  cat <<'EOF'
Usage: ./setup.sh <command> [args]

  render <profile|--check>       Render cloud-init/user-data.yaml and
                                 ansible/vars/generated.yml from a profile
  create                         Create the Incus profile and launch containers
  prepare                        Converge the containers with Ansible (idempotent)
  runner                         Install the runner binaries (no registration)
  register <owner/repo> [token]  Register ephemeral runners for a repository
  register --org <org> [token]   Register ephemeral runners for an organisation
  status                         Show containers and gh-runner.service state
  logs [container]               Last 50 journal lines of gh-runner
  destroy [--yes]                Delete the containers and the profile
  help                           Print this text

Two provisioning paths, both runnable on their own:
  cloud-init/user-data.yaml      applied by Incus once, at container creation
  ansible/prepare.yml            re-runnable; repairs a container that exists

Order: ./setup.sh render requirements/<profile>.yml
  && ./setup.sh create
  && ./setup.sh prepare
  && ./setup.sh runner
  && ./setup.sh register owner/repo <token>

Env overrides:
  KIT_PYTHON      interpreter for the renderer (default: python3, falls back
                  to /usr/bin/python3 when it has no PyYAML)
  CONTAINER_COUNT containers to create (default: 2)
  CONTAINER_PREFIX  container name prefix (default: gen_name from the profile)
  CONTAINER_CPU   limits.cpu per container (default: 4)
  CONTAINER_MEM   limits.memory per container (default: 6GiB)
  INCUS_PROFILE   profile name (default: gen_name from the profile)
  GH_RUNNER_TOKEN registration token, consumed once per container (~1h life)
  GH_RUNNER_PAT   PAT stored in the container so every restart can re-register
  RUNNER_LABELS   runner labels (default: self-hosted,linux,incus)
EOF
}

main() {
  local sub="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    help | -h | --help)
      cmd_help
      return 0
      ;;
    render | create | prepare | runner | register | status | logs | destroy)
      "cmd_${sub}" "$@"
      ;;
    *)
      cmd_help
      die "unknown command '${sub}'; next: ./setup.sh help"
      ;;
  esac
}

main "$@"
