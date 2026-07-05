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
config/        Placeholder-only config examples and include/exclude manifests.
docs/          Bootstrap and recovery documentation.
scripts/       User-facing offline/runtime checks and future VM commands.
systemd/user/  Inert source templates for user systemd services/timers.
tests/         Offline tests for repository contracts and safety checks.
```

## Backup scope manifests, dry-run inventory, and SQLite-safe staging

The staging scope is versioned under `config/manifests/`:

- `include.paths` is the source of truth for live paths backup staging may consider.
- `exclude.patterns` is the source of truth for forbidden classes that must never enter staging.

Run the offline inventory dry-run before staging/restic work:

```bash
scripts/inventory-dry-run.sh
```

The command prints only path/count/status output. It does not print file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives. It exits non-zero if an included tree contains a forbidden class such as Honcho, Git/worktrees, dependency folders, caches/build outputs, model/media paths, Proxmox paths, runtime staging/logs, restic repositories, or raw backup archive files.

Create a SQLite-safe staging snapshot with `scripts/stage.sh --keep`.

`stage.sh` consumes the same manifests, preserves the live relative path structure under a unique directory in `~/.local/state/hermes-backup/staging/`, copies non-SQLite payloads with `rsync`, and stages SQLite candidates with `sqlite3 .backup` followed by `PRAGMA integrity_check`. To keep live paths read/copy-only, it refuses WAL-mode SQLite sources before opening them because a read-only SQLite connection can create or modify source-side `-wal`/`-shm` files; those databases require a later quiesce/snapshot strategy. By default, successful transient staging is removed; `--keep` preserves it for a downstream backup command or investigation. The command writes `staging-metadata.json` with manifest paths/checksums, source roots, skipped paths, and counts, but never file contents or secret values.

Run the restic backup and retention flow after local config is created:

```bash
scripts/backup.sh
```

`backup.sh` validates the local chmod-600 env file and restic password file, runs `stage.sh --keep`, points `restic backup` only at the staging root, tags snapshots with stable `hermes-vm-backup`, and runs `restic forget --tag hermes-vm-backup --group-by host,tags --keep-daily 7 --keep-weekly 8 --keep-monthly 12 --keep-yearly 2 --prune` only after a successful backup. The stable tag/grouping keeps retention meaningful even though staging paths rotate every run. It appends a redacted daily local log under `HERMES_BACKUP_LOG_DIR` (default `~/.local/state/hermes-backup/logs/`), keeps successful runs quiet in Telegram, and sends one compact raw Telegram Bot API alert when staging, backup, or prune fails and local Telegram config is available. It prints status, the staging root, and the snapshot id when available; it does not print B2 keys, restic passwords, Telegram credentials, file contents, or backup archives. It is intentionally limited to backup plus retention/prune/log/alert behavior; timers, promote, and drill behavior remain downstream tickets.

Run a repository health check after local config is created:

```bash
scripts/restic-check.sh
```

`restic-check.sh` validates the same local chmod-600 env file and restic password file, runs `restic check` against the configured repository, appends a redacted daily local log under `HERMES_BACKUP_LOG_DIR` (default `~/.local/state/hermes-backup/logs/`), keeps successful checks quiet in Telegram, and sends one compact raw Telegram Bot API alert when `restic check` fails and local Telegram config is available. Exit code `0` means the check passed, `64` means local config is missing or unsafe, `127` means `restic` is unavailable, and any other non-zero exit is the propagated `restic check` failure. Failure output is redacted for B2 keys, restic password-file paths, repository URLs, Telegram credentials, file contents, backup archives, Authorization-like values, and credential-looking strings. It does not implement systemd timers, restore, promote, or drill behavior.

## Safe restore command

Restore the latest restic snapshot into the default non-live inspection directory:

```bash
scripts/restore.sh
```

By default the restore target is `~/restore/hermes-vm-backup/latest`. If local config sets `HERMES_BACKUP_RESTORE_DIR`, that directory becomes the default restore root; `HERMES_BACKUP_ENV` is honored the same way as `backup.sh`. Pass `--snapshot <snapshot-id>` to restore into `<restore-root>/<snapshot-id>`, or pass `--target <absolute-path>` for a custom inspection directory. `restore.sh` refuses destinations that equal, sit inside, or parent-overlap configured live include paths such as `/home/agent/.hermes`, `/home/agent/shared`, `/home/agent/shared-assets`, `/home/agent/.config/systemd/user`, and `/home/agent/.config/containers/systemd`.

The command loads the already-created local restic/B2 config, runs `restic restore` for the stable `hermes-vm-backup` tag when selecting `latest`, flattens the staged backup layout into the inspection directory, writes a non-secret `.hermes-backup-restore.json` provenance marker for the later explicit promote command, then prints a compact verification summary for the expected include roots. It does not promote restored files, overwrite live Hermes/shared/systemd/Quadlet paths, print secret values, or implement the later drill workflow.

## Explicit live promote command

After inspecting a safe restore directory, promote it with an explicit guarded command:

```bash
scripts/promote.sh --dry-run ~/restore/hermes-vm-backup/latest
scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE ~/restore/hermes-vm-backup/latest
```

`promote.sh` is intentionally separate from `restore.sh`; install, restore, timers, and future drill paths must not call it automatically. The command requires an absolute restore directory with the non-secret `.hermes-backup-restore.json` marker written by `restore.sh`, requires the expected restored include roots, refuses restore paths that overlap configured live include paths, and refuses symlinked restore/live path components. Dry-run mode prints the planned backup/promote actions without changing live paths. Confirmed mode optionally stops active known user services with `systemctl --user`, creates a unique local pre-promotion backup under `~/.local/state/hermes-backup/pre-promotion-backups/<timestamp>.<suffix>/`, replaces the configured live include roots from the inspected restore output, reloads user systemd state, and prints a checklist for Hermes profiles, shared outputs, shared-assets, systemd user units, and Quadlets. It prints paths/status only; it never prints B2 keys, restic passwords, Telegram credentials, file contents, or backup archives.

Collocation baseline:

- Keep one user-facing command per file under `scripts/` when downstream tickets add executable behavior.
- Keep script-specific helper logic beside the owning script.
- Move shared shell helpers under `lib/hermes-backup/` only after at least two commands reuse them; avoid catch-all `helpers` or `utils` buckets.
- Keep tests and fixtures nearest to the behavior they verify.

## Required offline verification

Every foundation-bootstrap PR must include this command as reviewer evidence:

```bash
scripts/check.sh
```

The harness is offline-only. It runs shell syntax checks, pytest coverage for preflight/config/install safety, and a Git ignored-file guard. It must not call B2, restic repositories, Telegram, Hermes cron, or `systemctl --user enable/start`.

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
5. Leaves backup execution manual for this slice and does not enable timers.

What is intentionally not active yet:

- `install.sh` does not run backup, check, restore, promote, or drill commands.
- `scripts/restore.sh` is available as a manual, safe, non-live restore command; install does not run it.
- `scripts/promote.sh` is available only as a manual explicit live promote command; install, restore, check, timers, and drill paths do not run it automatically.
- No restic repository is initialized by install.
- No B2, restic, or Telegram network validation is run by install.
- No user systemd service/timer is enabled or started.
- No Hermes cron scheduling is used.

Downstream tickets own drill behavior, first-run verification, and user systemd timer enablement.

## Current status

This foundation, backup, safe-restore, check, promote, and alert slice establishes repo structure, docs, ignore rules, placeholder config, inert systemd templates, safety tests, the offline preflight contract at `scripts/preflight.sh --check`, the local config/secret prompt writer at `scripts/configure.sh`, the bootstrap skeleton at `./install.sh`, SQLite-safe staging at `scripts/stage.sh`, the manual restic backup/retention command at `scripts/backup.sh`, the manual restic repository health check at `scripts/restic-check.sh`, shared redacted local log/raw Telegram failure alert helpers under `lib/hermes-backup/log-alert.sh`, the manual non-live restore command at `scripts/restore.sh`, and the manual explicit live promote command at `scripts/promote.sh`. Restic initialization, live timer enablement, and restore drills remain downstream work.
