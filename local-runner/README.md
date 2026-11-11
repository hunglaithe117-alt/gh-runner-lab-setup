# local-runner — one self-hosted runner on this computer

Install the official `actions/runner` on the host, register it against one
repository, and run it with a **systemd `--user`** unit. No Incus, no Docker, no
root. Use this to test workflows before moving them into the Incus containers
described in the parent `README.md`.

```
~/.local/share/gh-runner/                  runner binaries
~/.config/systemd/user/gh-runner-local.service
```

The runner is **persistent** (not `--ephemeral`): it stays registered and accepts
jobs until you stop it. Ephemeral runners need a fresh token per job; the Incus
containers in `template/` are where that pattern belongs.

## Prerequisites

- Linux x64 or arm64, `bash`, `curl`, `tar`, `sha256sum`, `git`, `python3`.
- `libicu` (`sudo apt-get install -y libicu-dev` if missing).
- `gh` authenticated (`gh auth status`) for automatic token minting.
- Admin rights on the repository's runners.

## Quick start

```bash
./local-runner/setup.sh install
./local-runner/setup.sh register OWNER/REPO
./local-runner/setup.sh status
```

`register` mints a registration token with `gh api` unless you pass `--token`.
It adds the `local` label on top of the default `self-hosted, linux, <arch>`
labels, which is what `.github/workflows/self-hosted-smoke.yml` targets.

## Commands

| Command | Effect |
| --- | --- |
| `install [--force]` | Download, verify, and unpack the pinned runner; write/refresh the unit. |
| `register OWNER/REPO [--token T] [--labels CSV] [--name N]` | Configure and start. Fails when a `.runner` file already exists. |
| `start` / `stop` | Start or stop the unit. |
| `status` | Unit state, runner name, server URL, work folder. |
| `logs [LINES]` | `journalctl --user -u gh-runner-local`, default 80 lines. |
| `unregister OWNER/REPO` | Mint a removal token, `config.sh remove`, stop the unit. |
| `uninstall [--purge]` | Disable/remove the unit; `--purge` deletes the runner directory. |

`GH_RUNNER_DIR` overrides the install directory (must not contain spaces).

## Optional: keep it running after logout

A `--user` unit stops when your session ends unless lingering is enabled:

```bash
sudo loginctl enable-linger "$USER"
```

## Security notes

- Jobs run as **your** user with your files and credentials. Register only a
  repository whose workflows you control; use GitHub-hosted runners for
  untrusted forks.
- A registration token is passed to `config.sh --token` and is briefly visible
  in the process list. The script never logs it and unsets it afterwards, but do
  not run it on a shared machine.
- Never commit an exported token or a PAT; the runner state lives outside the
  repo.

## Difference from the Incus kit

| | `local-runner/` | `template/` (Incus) |
| --- | --- | --- |
| Isolation | none, host user | system container per repo |
| Runner mode | persistent | ephemeral, one job per registration |
| Needs root | no | Incus admin group only |
| Purpose | smoke-test workflows on this machine | disposable, repeatable CI capacity |
