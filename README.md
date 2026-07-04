# hermes-backup

`dannyfranca/hermes-backup` is Danny's opinionated disaster-recovery automation repo for the Hermes Ubuntu VM that runs as user `agent`.

This repository will version the scripts, config examples, systemd user unit templates, tests, and recovery docs needed to back up and restore Hermes VM state. It must never contain live secrets or backup archives.

## Scope

Included state, from the project PRD:

- `/home/agent/.hermes` — Hermes configuration, profiles, memories, Kanban state, gateway setup, and related local state.
- `/home/agent/shared` — generated reports and human-facing shared outputs.
- `/home/agent/shared-assets` — static shared assets served from the VM.
- `/home/agent/.config/systemd/user` — user service definitions.
- `/home/agent/.config/containers/systemd` — rootless Podman Quadlet definitions.

Excluded state:

- `/home/agent/git`, canonical clones, task worktrees, and other rebuildable repositories.
- Caches, build outputs, virtual environments, dependency folders, `node_modules`, model downloads, and media libraries.
- Honcho data/configuration.
- Proxmox-level backup automation.

## Hard rules for implementation

- Use Backblaze B2 through restic with client-side encryption.
- Keep B2 keys, restic passwords, Telegram bot credentials, and raw backup archives out of Git.
- Bootstrap must prompt locally for secrets and write only local chmod-600-style config/env files.
- Use user-level systemd timers for scheduling; do not use Hermes cron for backup/check/drill scheduling.
- Use raw Telegram Bot API alerts so notifications do not depend on the Hermes gateway.
- Restore defaults must write to a safe restore directory; live replacement requires an explicit promote step.

## Repository structure

```text
config/        Placeholder-only config examples and future include/exclude manifests.
docs/          Bootstrap and recovery documentation.
scripts/       User-facing offline/runtime checks and future VM commands.
systemd/user/  Inert source templates for user systemd services/timers.
tests/         Offline tests for repository contracts and safety checks.
```

Collocation baseline:

- Keep one user-facing command per file under `scripts/` when downstream tickets add executable behavior.
- Keep script-specific helper logic beside the owning script.
- Move shared shell helpers under `lib/hermes-backup/` only after at least two commands reuse them; avoid catch-all `helpers` or `utils` buckets.
- Keep tests and fixtures nearest to the behavior they verify.

## Stress-friendly bootstrap checklist

This foundation slice provides a safe one-command skeleton:

```bash
./install.sh
```

What it does now:

1. Runs `scripts/preflight.sh --check` before any secret prompt.
2. Creates local state/log/staging directories under `~/.local/state/hermes-backup/`, a safe restore directory at `~/restore/hermes-vm-backup/`, and local inert systemd template copies.
3. Runs `scripts/configure.sh` to prompt locally for B2, restic, and raw Telegram Bot API values.
4. Writes local-only config under `~/.config/hermes-backup/` with owner-only permissions.
5. Confirms backup execution is not implemented/active and no timers were enabled.

What is intentionally not active yet:

- No backup, check, restore, promote, or drill command is implemented or run.
- No restic repository is initialized.
- No B2, restic, or Telegram network validation is run.
- No user systemd service/timer is enabled or started.
- No Hermes cron scheduling is used.

Downstream tickets own real backup/check/drill behavior, raw Telegram alerts, first-run verification, and user systemd timer enablement.

## Current status

This foundation slice establishes repo structure, docs, ignore rules, placeholder config, inert systemd templates, safety tests, the offline preflight contract at `scripts/preflight.sh --check`, the local config/secret prompt writer at `scripts/configure.sh`, and the bootstrap skeleton at `./install.sh`. Backup, check, restore, promote, Telegram delivery, restic initialization, and live timer enablement remain downstream work.
