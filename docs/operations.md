# Operations details

Use this page when you need the deeper behavior behind the README quick start. The README stays the setup-oriented entry point; this file holds the longer staging, backup, check, timer, and drill notes.

Safety baseline:

- No committed docs or examples should contain live B2 keys, restic passwords, Telegram tokens, raw backup archives, restored secret files, or repository URLs containing secrets.
- Runtime commands print paths/status and redacted diagnostics, not secret values or file contents.
- Restore writes to a safe inspection directory by default. Live replacement requires the separate explicit promote command documented in `docs/recovery-runbook.md`.

## Scope manifests and staging

The staging scope is versioned under `config/manifests/`:

- `include.paths` is the source of truth for live paths backup staging may consider.
- `exclude.patterns` is the source of truth for forbidden or rebuildable classes that must never enter staging.

Run the offline inventory dry-run before staging/restic work:

```bash
scripts/inventory-dry-run.sh
```

The dry-run prints path/count/status output only. It does not print file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives. It exits non-zero if an included tree cannot be inventoried safely. Configured forbidden classes are summarized as staging omissions, including:

- Honcho data/configuration.
- Git clones and worktrees.
- Dependency folders and package-manager stores.
- Caches, build outputs, virtual environments, and `node_modules`.
- Explicit model-download/cache roots and media-library roots.
- Proxmox paths.
- Runtime staging/logs, restic repositories, and raw backup archive files.

Create a SQLite-safe staging snapshot with:

```bash
scripts/stage.sh --keep
```

`stage.sh` consumes the same manifests, preserves the live relative path structure under a unique directory in `~/.local/state/hermes-backup/staging/`, and copies non-SQLite payloads with `rsync`.

For SQLite candidates, it:

1. Snapshot-copies the database main file plus any `-wal`, `-shm`, or `-journal` sidecars into a private temporary directory.
2. Retries if the live snapshot state changes mid-copy.
3. Runs `sqlite3 .backup` from that private snapshot.
4. Verifies the staged database with `PRAGMA integrity_check`.

WAL-mode sources log `status=wal-snapshot-backed-up`; clean sources log `status=clean-snapshot-backed-up`.

By default, successful transient staging is removed. `--keep` preserves it for a downstream backup command or investigation. The command writes `staging-metadata.json` with manifest paths/checksums, source roots, skipped paths, SQLite snapshot status, and counts, but never file contents or secret values.

## Backup and retention

Run after local config is created:

```bash
scripts/backup.sh
```

`backup.sh`:

- Validates the local chmod-600 env file and restic password file.
- Takes the shared non-blocking runtime lock.
- Runs `stage.sh --keep`.
- Points `restic backup` only at the staging root.
- Tags snapshots with stable `hermes-vm-backup`.
- Runs retention/prune only after a successful backup.
- Appends a redacted daily local log under `HERMES_BACKUP_LOG_DIR`, defaulting to `~/.local/state/hermes-backup/logs/`.
- Keeps successful runs quiet in Telegram.
- Sends one compact raw Telegram Bot API alert when staging, backup, prune, or lock acquisition fails and local Telegram config is available.

Retention policy:

```text
restic forget --tag hermes-vm-backup --group-by host,tags --keep-daily 7 --keep-weekly 8 --keep-monthly 12 --keep-yearly 2 --prune
```

The stable tag/grouping keeps retention meaningful even though staging paths rotate every run.

Output is status, lock file, staging root, and snapshot id when available. It must not print B2 keys, restic passwords, Telegram credentials, file contents, or backup archives.

## Restic repository check

Run after local config is created:

```bash
scripts/restic-check.sh
```

`restic-check.sh`:

- Validates the same local chmod-600 env file and restic password file.
- Takes the shared non-blocking runtime lock.
- Runs `restic check` only when no backup/check/drill job is already running.
- Appends a redacted local log through the same log directory interface.
- Keeps successful checks and lock-contention skips quiet in Telegram.
- Sends one compact raw Telegram Bot API alert when `restic check` fails and local Telegram config is available.

Exit code summary:

- `0`: check passed or was cleanly skipped because the shared runtime lock was held.
- `64`: local config is missing or unsafe.
- `127`: `restic` is unavailable.
- Any other non-zero exit: propagated `restic check` failure.

Failure output is redacted for B2 keys, restic password-file paths, repository URLs, Telegram credentials, file contents, backup archives, Authorization-like values, and credential-looking strings.

## User systemd timers

`./install.sh` renders the versioned templates in `systemd/user/` into the user's systemd unit directory, defaulting to `~/.config/systemd/user/`, then runs `systemctl --user daemon-reload`.

Rendered services call only the approved repo commands:

- `hermes-backup-backup.service` -> `scripts/backup.sh`
- `hermes-backup-check.service` -> `scripts/restic-check.sh`
- `hermes-backup-restore-drill.service` -> `scripts/restore-drill.sh`

Timer cadence:

- `hermes-backup-backup.timer`: daily at about 03:30 with a 30 minute randomized delay.
- `hermes-backup-check.timer`: weekly on Sunday at about 08:30 with a 45 minute randomized delay.
- `hermes-backup-restore-drill.timer`: monthly on the first Sunday at about 10:30 with a 2 hour randomized delay.

Enable timers through the first-run activation gate:

```bash
scripts/activate.sh --init-restic --telegram-test --first-backup --first-check --enable-timers
systemctl --user list-timers --all 'hermes-backup-*'
```

Activation delegates timer enablement to `./install.sh --enable-timers`, which uses `systemctl --user enable` without `--now`. It does not immediately start backup, check, or restore-drill jobs.

If Danny wants timers active immediately in the current user-manager session, start the timer units manually after accepting systemd catch-up behavior:

```bash
systemctl --user start hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
```

When `Persistent=true` catch-up or manual starts make jobs collide, the shared lock keeps behavior predictable:

- Backup lock contention is a failure with one raw Telegram alert because a missed backup is actionable.
- Check contention is a clean skip recorded in the local log.
- Restore-drill contention sends a `SKIP` drill report so the operator sees the monthly drill did not run.

There is no delayed retry, dynamic scheduling, least-busy heuristic, or Hermes cron handoff.

## Monthly safe restore drill

Run a drill manually with:

```bash
scripts/restore-drill.sh
```

`restore-drill.sh`:

- Uses the safe restore command to restore `latest` into a temporary drill-only directory under `HERMES_BACKUP_DRILL_DIR`, `XDG_STATE_HOME/hermes-backup/drills`, or `~/.local/state/hermes-backup/drills`.
- Takes the shared runtime lock so monthly drill restores do not overlap backup/prune/check operations.
- Verifies every configured include root exists in the restored tree.
- Runs `sqlite3 PRAGMA integrity_check` for restored `*.db` files.
- Writes a redacted local drill log through `HERMES_BACKUP_LOG_DIR`.
- Sends a compact raw Telegram Bot API report through local `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` config.

The report begins with `Hermes backup restore drill`, includes `status: PASS`, `status: FAIL`, or `status: SKIP`, and summarizes snapshot, safe drill target or skip reason, include-root counts, and SQLite counts.

By default drill artifacts are deleted after the report. Pass `--keep-artifacts` only when Danny wants to inspect the restored drill directory manually. Delete retained artifacts promptly because they can contain restored secrets.

The drill command never invokes `promote.sh`, never writes to live Hermes/shared/systemd/Quadlet paths, never uses Hermes gateway or Hermes cron, and never prints B2 keys, restic passwords, Telegram tokens, repository URLs, file contents, or backup archives.

## Safe restore and promote summary

Use `docs/recovery-runbook.md` for the full recovery path.

Short version:

```bash
scripts/restore.sh
RESTORE_DIR="<paste restore_target path printed by scripts/restore.sh>"
scripts/promote.sh --dry-run "$RESTORE_DIR"
scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE "$RESTORE_DIR"
```

Important constraints:

- `restore.sh` restores into a fresh safe inspection directory by default, such as `~/restore/hermes-vm-backup/latest-20260705T143000Z`.
- `restore.sh` refuses destinations that equal, sit inside, or parent-overlap configured live include paths.
- Selecting `latest` filters restic snapshots by stable `hermes-vm-backup` tag plus host.
- Use `--host <source-host>` when the replacement VM hostname differs from the host that created the backup.
- `promote.sh` requires the non-secret `.hermes-backup-restore.json` marker written by `restore.sh`.
- `promote.sh` is intentionally separate from install, restore, timers, check, backup, and drill paths.
- Confirmed promote requires operator review of the quiesce plan and the explicit `PROMOTE-HERMES-RESTORE` confirmation token.

## Current implementation status

The current repository includes:

- Offline preflight: `scripts/preflight.sh --check`.
- Local config/secret prompt writer: `scripts/configure.sh`.
- Bootstrap/systemd installer: `./install.sh`.
- SQLite-safe staging: `scripts/stage.sh`.
- Manual restic backup/retention: `scripts/backup.sh`.
- Manual restic repository health check: `scripts/restic-check.sh`.
- Explicit first-run activation/check command: `scripts/activate.sh`.
- Shared redacted local log/raw Telegram helpers: `lib/hermes-backup/log-alert.sh`.
- Manual non-live restore: `scripts/restore.sh`.
- Manual explicit live promote: `scripts/promote.sh`.
- Manual safe monthly restore drill: `scripts/restore-drill.sh`.
- User systemd backup/check/restore-drill templates under `systemd/user/`.

Current-session timer starts and broader end-to-end safety harness work remain operator-controlled/manual.
