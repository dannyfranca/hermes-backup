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
systemd/user/  Inert source templates for user systemd services/timers.
tests/         Offline tests for repository contracts and safety checks.
```

Collocation baseline:

- Keep one user-facing command per file under `scripts/` when downstream tickets add executable behavior.
- Keep script-specific helper logic beside the owning script.
- Move shared shell helpers under `lib/hermes-backup/` only after at least two commands reuse them; avoid catch-all `helpers` or `utils` buckets.
- Keep tests and fixtures nearest to the behavior they verify.

## Current status

This foundation ticket only establishes repo structure, docs, ignore rules, placeholder config, inert systemd templates, and safety tests. Backup, check, restore, promote, bootstrap, Telegram, and live secret collection behavior are downstream work.
