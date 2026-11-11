# Push this repo to GitHub and run it locally first

This repository is already initialized as a git repo on branch `main`. Nothing
is committed and no remote exists yet; those steps are yours to run.

```text
gh-runner-lab/
├── README.md, SETUP.md       lab overview and explanation (Vietnamese)
├── lab.sh, ansible/, cloud-init/   Incus lab
├── template/                 copy-and-adapt Incus runner kit
├── local-runner/             host-native runner kit (no Incus)
└── .github/workflows/self-hosted-smoke.yml
```

## 1. Commit and create the repository

```bash
cd ~/personal/gh-runner-lab
git add -A
git status                       # review before committing
git commit -m "Initial commit: Incus runner lab and runner kits"
```

```bash
# Option A: gh creates the repo, adds origin, and pushes
gh repo create gh-runner-lab --private --source=. --remote=origin --push

# Option B: create the repo in the web UI, then
git remote add origin git@github.com:OWNER/gh-runner-lab.git
git push -u origin main
```

## 2. Start a runner on this computer

No Incus, no root, no Docker: one persistent runner as a systemd `--user` unit.

```bash
./local-runner/setup.sh install
./local-runner/setup.sh register OWNER/gh-runner-lab
./local-runner/setup.sh status
```

`register` needs `gh auth status` to be clean, or pass `--token`. Reference:
[`local-runner/README.md`](local-runner/README.md).

## 3. Prove it works

```bash
gh workflow run self-hosted-smoke.yml
gh run watch
```

If the job stays queued, the runner is offline or its labels do not match
`[self-hosted, linux, local]`:

```bash
./local-runner/setup.sh logs 120
gh api /repos/OWNER/gh-runner-lab/actions/runners \
  -q '.runners[] | {name, status, labels: [.labels[].name]}'
```

## 4. Move to the Incus path (optional)

Stop the local runner first so the repository has one registration:

```bash
./local-runner/setup.sh unregister OWNER/gh-runner-lab
```

Then follow [`template/README.md`](template/README.md) (`render`, `create`,
`prepare`, `runner`, `register`).

## 5. Before pushing

`git status --ignored --short` should show caches, generated artifacts, and
secrets as ignored. Never commit a registration token or PAT. Check for obvious
secrets:

```bash
git grep -nE '(ghp_|github_pat_|sk-[A-Za-z0-9]{20,})' -- . || echo "no obvious secrets"
```
