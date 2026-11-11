#!/usr/bin/env bash
# Install, register, and run one GitHub Actions self-hosted runner on this host.
# The runner lives under ~/.local/share/gh-runner and runs as a systemd --user
# unit, so it needs no root and no Incus container.
set -euo pipefail

readonly DEFAULT_VERSION="2.338.2"
readonly UNIT_NAME="gh-runner-local.service"

RUNNER_DIR="${GH_RUNNER_DIR:-$HOME/.local/share/gh-runner}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./local-runner/setup.sh <command> [args]

Commands:
  install [--force]
      Download and unpack actions/runner into ~/.local/share/gh-runner and
      write the systemd --user unit. Does not start anything.

  register OWNER/REPO [--token TOKEN] [--labels CSV] [--name NAME]
      Configure the runner and start the unit. Without --token, uses
      `gh api` to mint a registration token (gh must be authenticated).

  start | stop
      Start or stop the systemd --user unit.

  status
      Unit state plus the configured runner name and URL.

  logs [LINES]
      Last journal lines for the unit (default 80).

  unregister OWNER/REPO
      Remove this runner from GitHub and delete its local configuration.

  uninstall [--purge]
      Disable and remove the unit. --purge also deletes ~/.local/share/gh-runner.

Environment:
  GH_RUNNER_DIR   install directory (default ~/.local/share/gh-runner)
EOF
}

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

check_runtime_deps() {
  local libs=""
  if command -v ldconfig >/dev/null 2>&1; then
    libs="$(ldconfig -p 2>/dev/null || true)"
  fi
  if [[ -n $libs && $libs != *libicu* ]]; then
    info "warning: libicu not found; install it with: sudo apt-get install -y libicu-dev"
  fi
  command -v git >/dev/null 2>&1 || info "warning: git not found; actions/checkout steps will fail"
}

sha_for_arch() {
  case "$1" in
    x64) printf '%s\n' "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40" ;;
    arm64) printf '%s\n' "670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945" ;;
    *) die "no pinned checksum for architecture: $1" ;;
  esac
}

write_unit() {
  mkdir -p "$UNIT_DIR"
  cat >"$UNIT_DIR/$UNIT_NAME" <<EOF
[Unit]
Description=GitHub Actions self-hosted runner (local)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$RUNNER_DIR
ExecStart=$RUNNER_DIR/run.sh
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=120

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
}

cmd_install() {
  local force=0
  while (($#)); do
    case "$1" in
      --force) force=1; shift ;;
      -h | --help) usage; return 0 ;;
      *) die "unknown install option: $1" ;;
    esac
  done
  require curl tar sha256sum
  [[ $RUNNER_DIR != *" "* ]] || die "GH_RUNNER_DIR must not contain spaces: $RUNNER_DIR"

  if [[ -f $RUNNER_DIR/config.sh ]] && ((force == 0)); then
    info "runner already unpacked at $RUNNER_DIR (use --force to reinstall)"
  else
    local arch asset url tmp expected actual
    arch="$(detect_arch)"
    asset="actions-runner-linux-${arch}-${DEFAULT_VERSION}.tar.gz"
    url="https://github.com/actions/runner/releases/download/v${DEFAULT_VERSION}/${asset}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    info "downloading $url"
    curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$asset" "$url"

    expected="$(sha_for_arch "$arch")"
    actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    [[ $actual == "$expected" ]] || die "checksum mismatch for $asset: expected $expected, got $actual"
    info "checksum ok: $actual"

    mkdir -p "$RUNNER_DIR"
    tar -xzf "$tmp/$asset" -C "$RUNNER_DIR"
    rm -rf "$tmp"
    trap - EXIT
  fi

  check_runtime_deps
  write_unit

  info ""
  info "runner installed at $RUNNER_DIR"
  info "unit written to $UNIT_DIR/$UNIT_NAME"
  info "next: $0 register OWNER/REPO"
}

cmd_register() {
  local repo="" token="" labels="local" name
  name="$(hostname -s)-local"
  while (($#)); do
    case "$1" in
      --token) token="${2:?--token needs a value}"; shift 2 ;;
      --labels) labels="${2:?--labels needs a value}"; shift 2 ;;
      --name) name="${2:?--name needs a value}"; shift 2 ;;
      -h | --help) usage; return 0 ;;
      -*) die "unknown register option: $1" ;;
      *)
        [[ -z $repo ]] || die "only one repository argument is accepted"
        repo="$1"
        shift
        ;;
    esac
  done

  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "usage: $0 register OWNER/REPO [--token TOKEN]"
  [[ -x $RUNNER_DIR/config.sh ]] || die "runner not installed; run: $0 install"
  [[ ! -f $RUNNER_DIR/.runner ]] \
    || die "runner already configured in $RUNNER_DIR; run unregister first"

  if [[ -z $token ]]; then
    command -v gh >/dev/null 2>&1 || die "gh not found; pass --token"
    token="$(gh api -X POST "/repos/$repo/actions/runners/registration-token" -q .token)"
    [[ -n $token ]] || die "could not mint a registration token for $repo"
  fi

  (
    cd "$RUNNER_DIR"
    ./config.sh --unattended \
      --url "https://github.com/$repo" \
      --token "$token" \
      --name "$name" \
      --labels "$labels" \
      --work "$RUNNER_DIR/_work" \
      --replace
  )
  unset token

  systemctl --user enable --now "$UNIT_NAME"
  info ""
  info "runner '$name' registered for $repo"
  info "watch it with: $0 logs"
}

cmd_start() {
  systemctl --user start "$UNIT_NAME"
  info "started $UNIT_NAME"
}

cmd_stop() {
  systemctl --user stop "$UNIT_NAME"
  info "stopped $UNIT_NAME"
}

cmd_status() {
  systemctl --user status "$UNIT_NAME" --no-pager 2>&1 || true
  [[ -f $RUNNER_DIR/.runner ]] || return 0
  info ""
  if command -v jq >/dev/null 2>&1; then
    jq -r '"name: \(.agentName)\nurl:  \(.gitHubUrl // .serverUrl)\nwork: \(.workFolder)"' \
      "$RUNNER_DIR/.runner"
  else
    python3 - "$RUNNER_DIR/.runner" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
print("name: %s" % data.get("agentName"))
print("url:  %s" % (data.get("gitHubUrl") or data.get("serverUrl")))
print("work: %s" % data.get("workFolder"))
PY
  fi
}

cmd_logs() {
  local lines="${1:-80}"
  journalctl --user -u "$UNIT_NAME" -n "$lines" --no-pager
}

cmd_unregister() {
  local repo="${1:-}" token
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "usage: $0 unregister OWNER/REPO"
  [[ -f $RUNNER_DIR/.runner ]] || die "runner is not configured in $RUNNER_DIR"
  command -v gh >/dev/null 2>&1 || die "gh is required to mint a removal token"

  systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
  token="$(gh api -X POST "/repos/$repo/actions/runners/remove-token" -q .token)"
  [[ -n $token ]] || die "could not mint a removal token for $repo"
  (
    cd "$RUNNER_DIR"
    ./config.sh remove --token "$token"
  )
  unset token
  info "runner configuration removed from this host"
}

cmd_uninstall() {
  local purge=0
  [[ ${1:-} == "--purge" ]] && purge=1

  systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT_NAME"
  systemctl --user daemon-reload

  if ((purge == 1)); then
    [[ -f $RUNNER_DIR/.runner ]] \
      && info "warning: the runner may still be registered on GitHub; run unregister first"
    rm -rf "$RUNNER_DIR"
    info "removed $RUNNER_DIR"
  else
    info "unit removed; runner files kept at $RUNNER_DIR"
    info "delete them with: $0 uninstall --purge"
  fi
}

main() {
  [[ $EUID -ne 0 ]] || die "run as your normal user, not root"
  local command="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$command" in
    install) cmd_install "$@" ;;
    register) cmd_register "$@" ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    logs) cmd_logs "$@" ;;
    unregister) cmd_unregister "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    "" | -h | --help | help) usage ;;
    *) die "unknown command: $command (try --help)" ;;
  esac
}

main "$@"
