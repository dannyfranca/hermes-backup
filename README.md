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

Hermes profile dependency stores such as Go module caches under profile `home/go/pkg/mod` directories and pnpm stores under profile `home/.local/share/pnpm/store` directories are intentionally omitted as rebuildable state. The exclusions are path-specific so durable profile config and local state under `.hermes/profiles/*` still remain eligible for encrypted backup.

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

`restic-check.sh` validates the same local chmod-600 env file and restic password file, runs `restic check` against the configured repository, appends a redacted daily local log under `HERMES_BACKUP_LOG_DIR` (default `~/.local/state/hermes-backup/logs/`), keeps successful checks quiet in Telegram, and sends one compact raw Telegram Bot API alert when `restic check` fails and local Telegram config is available. Exit code `0` means the check passed, `64` means local config is missing or unsafe, `127` means `restic` is unavailable, and any other non-zero exit is the propagated `restic check` failure. Failure output is redacted for B2 keys, restic password-file paths, repository URLs, Telegram credentials, file contents, backup archives, Authorization-like values, and credential-looking strings. It does not implement restore, promote, or drill behavior.

## First-run activation after local secrets exist

`./install.sh` stays inert by default. After local config exists, run the explicit activation/check path from a local terminal:

```bash
./install.sh
scripts/activate.sh --init-restic --telegram-test --first-backup --first-check --enable-timers
systemctl --user list-timers --all 'hermes-backup-*'
```

`scripts/activate.sh` first runs the offline preflight and local chmod-600 config/password checks. It verifies the configured restic repository, runs `restic init` only when the repository looks uninitialized and `--init-restic` is passed, sends one raw Telegram Bot API setup-test message only with `--telegram-test`, runs one first backup only with `--first-backup`, runs one repository check only with `--first-check`, and enables the backup/check/restore-drill user timers only after `--first-backup` and `--first-check` succeed in the same activation run. Timer enablement delegates to `./install.sh --enable-timers`, which uses `systemctl --user enable` without `--now`; no timer unit is started unexpectedly.

For a non-network preview, use `scripts/activate.sh --dry-run` with any planned flags. The command prints only paths/status and redacted diagnostics. It must not print B2 keys, restic passwords, Telegram credentials, repository URLs, file contents, or backup archives.

## User systemd backup/check/restore-drill timers

`./install.sh` renders the versioned templates in `systemd/user/` into the user's systemd unit directory, defaulting to `~/.config/systemd/user/`, then runs `systemctl --user daemon-reload`. The rendered services call only the approved repo commands:

- `hermes-backup-backup.service` -> `scripts/backup.sh`
- `hermes-backup-check.service` -> `scripts/restic-check.sh`
- `hermes-backup-restore-drill.service` -> `scripts/restore-drill.sh`

The timers are user-level systemd timers, not Hermes cron:

- `hermes-backup-backup.timer`: daily at about 03:30 with a 30 minute randomized delay.
- `hermes-backup-check.timer`: weekly on Sunday at about 08:30 with a 45 minute randomized delay.
- `hermes-backup-restore-drill.timer`: monthly on the first Sunday at about 10:30 with a 2 hour randomized delay.

Install is idempotent. It reuses an existing local `~/.config/hermes-backup/hermes-backup.env` plus `restic-password` when both are present with `0600` permissions, and it rewrites unit files from templates. By default it does not enable timers; after local verification, enable through the same install-time verification gate with:

```bash
./install.sh --enable-timers
systemctl --user list-timers --all 'hermes-backup-*'
systemctl --user status hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
```

The gate runs `systemctl --user enable` without `--now` so install does not immediately start persistent timers or dispatch missed backup/check/drill runs. For first setup, prefer the activation sequence above so timer enablement happens only after the first backup and check pass. If Danny wants timers active immediately in the current user manager session, he can start the timer units manually after accepting any systemd catch-up behavior.

The installer never runs backup, check, restore, promote, drill, restic init, B2/Telegram network validation, or Hermes cron scheduling. The restore-drill timer points only at the already-reviewed safe drill command and never at `restore.sh` or `promote.sh` directly.

## Recovery runbook and disaster checklist

Use `docs/recovery-runbook.md` when rebuilding a fresh VM or validating disaster-recovery readiness. It contains the panic-mode checklist, password-manager prerequisites, safe restore steps, explicit promote procedure, monthly restore-drill interpretation, verification plan, and post-compromise credential-rotation checklist.

The shortest safe recovery path is:

1. Clone `dannyfranca/hermes-backup` onto the replacement VM.
2. Run `scripts/preflight.sh --check` and `./install.sh` from a local terminal.
3. Enter B2/restic/Telegram values only into local prompts from Danny's password manager.
4. Run `scripts/activate.sh --telegram-test --first-check` to prove alert delivery and repository health before restore without taking a replacement-VM backup over the snapshot selection path.
5. Run `scripts/restore.sh` and inspect the safe restore directory.
6. Dry-run `scripts/promote.sh --dry-run <restore-dir>` and review both the promote plan and `quiesce ...` lines.
7. Run `scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE <restore-dir>` only after the restore has been verified and Hermes activity is quiesced or explicitly acknowledged.
8. Run `scripts/activate.sh --first-backup --first-check --enable-timers` after restore/promote verification, or after credential rotation if compromise is suspected. Start timer units manually only if current-session scheduling is desired and systemd catch-up behavior is acceptable, then verify user systemd timers, key restored paths, SQLite integrity, local logs, and raw Telegram drill reporting.

## Safe restore command

Restore the latest restic snapshot into the default non-live inspection directory:

```bash
scripts/restore.sh
```

By default each `latest` restore target is a fresh timestamped directory such as `~/restore/hermes-vm-backup/latest-20260705T143000Z`; this makes repeated restore drills practical without manually deleting the previous inspection tree. If local config sets `HERMES_BACKUP_RESTORE_DIR`, that directory becomes the default restore root; `HERMES_BACKUP_ENV` is honored the same way as `backup.sh`. Pass `--snapshot <snapshot-id>` to restore into `<restore-root>/<snapshot-id>`, or pass `--target <absolute-path>` for a custom inspection directory. `restore.sh` refuses destinations that equal, sit inside, or parent-overlap configured live include paths such as `/home/agent/.hermes`, `/home/agent/shared`, `/home/agent/shared-assets`, `/home/agent/.config/systemd/user`, and `/home/agent/.config/containers/systemd`.

When selecting `latest`, the command filters restic snapshots by both the stable `hermes-vm-backup` tag and a host filter. The host defaults to `HERMES_BACKUP_RESTORE_HOST` from local config when present, otherwise the current machine hostname; prefer the one-off `--host <source-host>` option if the replacement VM hostname differs from the host that created the backup. If `HERMES_BACKUP_RESTORE_HOST` is temporarily set in local config for recovery, remove it before enabling timers or relying on future restore drills so new drills target the replacement VM's own backups.

The command loads the already-created local restic/B2 config, runs `restic restore` for the stable `hermes-vm-backup` tag when selecting `latest`, flattens the staged backup layout into the inspection directory, writes a non-secret `.hermes-backup-restore.json` provenance marker for the later explicit promote command, then prints a compact verification summary for the expected include roots. It does not promote restored files, overwrite live Hermes/shared/systemd/Quadlet paths, or print secret values.

## Monthly safe restore drill

`restore-drill.sh` uses the safe restore command to restore `latest` into a temporary drill-only directory under `HERMES_BACKUP_DRILL_DIR`, `XDG_STATE_HOME/hermes-backup/drills`, or `~/.local/state/hermes-backup/drills`. It then verifies every configured include root exists in the restored tree, runs `sqlite3 PRAGMA integrity_check` for restored `*.db` files, writes a redacted local drill log through the same `HERMES_BACKUP_LOG_DIR` interface as backup/check, and sends a compact raw Telegram Bot API report through the same local `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` config model. The report begins with `Hermes backup restore drill`, includes `status: PASS` or `status: FAIL`, and summarizes snapshot, safe drill target, include-root counts, and SQLite counts.

By default drill artifacts are deleted after the report; pass `--keep-artifacts` when Danny wants to inspect the restored drill directory manually. The command never invokes `promote.sh`, never writes to live Hermes/shared/systemd/Quadlet paths, never uses Hermes gateway or Hermes cron, and never prints B2 keys, restic passwords, Telegram tokens, repository URLs, file contents, or backup archives. Monthly scheduling is installed through the user systemd timer documented above, not through Hermes cron.

## Explicit live promote command

After inspecting a safe restore directory, promote it with an explicit guarded command:

```bash
RESTORE_DIR="<paste restore_target path printed by scripts/restore.sh>"
scripts/promote.sh --dry-run "$RESTORE_DIR"
scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE "$RESTORE_DIR"
```

`promote.sh` is intentionally separate from `restore.sh`; install, restore, timers, and future drill paths must not call it automatically. The command requires an absolute restore directory with the non-secret `.hermes-backup-restore.json` marker written by `restore.sh`, requires the expected restored include roots, refuses restore paths that overlap configured live include paths, and refuses symlinked restore/live path components. Dry-run mode prints the planned backup/promote actions plus a non-mutating Hermes quiesce plan. Confirmed mode may stop only the reviewed user-service allowlist (`hermes-gateway.service` and `hermes-dashboard.service`), requires manual review or `--quiesce-ack PROMOTE-HERMES-QUIESCE` for other active Hermes-like services/processes or unavailable probes, creates a unique local pre-promotion backup under `~/.local/state/hermes-backup/pre-promotion-backups/<timestamp>.<suffix>/`, replaces the configured live include roots from the inspected restore output, reloads user systemd state, and prints a checklist for Hermes profiles, shared outputs, shared-assets, systemd user units, and Quadlets. It prints paths/status only; it never prints B2 keys, restic passwords, Telegram credentials, file contents, or backup archives.

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

This foundation slice provides a safe install skeleton:

```bash
./install.sh
```

What it does now:

1. Runs `scripts/preflight.sh --check` before any secret prompt.
2. Creates local state/log/staging directories under `~/.local/state/hermes-backup/`, a safe restore directory at `~/restore/hermes-vm-backup/`, and the user systemd unit directory.
3. Runs `scripts/configure.sh` to prompt locally for B2, restic, and raw Telegram Bot API values when local config does not already exist.
4. Writes or reuses local-only config under `~/.config/hermes-backup/` with owner-only permissions.
5. Renders backup/check/restore-drill systemd user units into `~/.config/systemd/user/` and runs `systemctl --user daemon-reload`.
6. Leaves timers disabled by default; `./install.sh --enable-timers` enables only the approved backup/check/restore-drill timers after local scheduler verification.

What is intentionally not active yet:

- `install.sh` does not run backup, check, restore, promote, or drill commands.
- `scripts/restore.sh` is available as a manual, safe, non-live restore command; install does not run it.
- `scripts/promote.sh` is available only as a manual explicit live promote command; install, restore, check, timers, and drill paths do not run it automatically.
- No restic repository is initialized by install.
- No B2, restic, or Telegram network validation is run by install.
- No Hermes cron scheduling is used.
- No timer units are started by install; `--enable-timers` only enables user timer symlinks for the next user-manager activation.

First-run repository verification now lives in `scripts/activate.sh`. Current-session timer starts remain intentionally manual because systemd catch-up behavior should be accepted by the operator at the terminal.

## Current status

This foundation, backup, safe-restore, check, promote, alert, drill-reporting, scheduler, and first-run activation slice establishes repo structure, docs, ignore rules, placeholder config, backup/check/restore-drill systemd user templates, safety tests, the offline preflight contract at `scripts/preflight.sh --check`, the local config/secret prompt writer at `scripts/configure.sh`, the bootstrap/systemd installer at `./install.sh`, SQLite-safe staging at `scripts/stage.sh`, the manual restic backup/retention command at `scripts/backup.sh`, the manual restic repository health check at `scripts/restic-check.sh`, the explicit first-run activation/check command at `scripts/activate.sh`, shared redacted local log/raw Telegram helpers under `lib/hermes-backup/log-alert.sh`, the manual non-live restore command at `scripts/restore.sh`, the manual explicit live promote command at `scripts/promote.sh`, and the manual safe monthly restore drill command at `scripts/restore-drill.sh`. Current-session timer start and broader end-to-end safety harness work remain downstream/manual.
