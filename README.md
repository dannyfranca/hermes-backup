# hermes-backup

ADHD-friendly disaster-recovery automation for Danny's Hermes Ubuntu VM.

Use this repo to set up encrypted restic backups to Backblaze B2, user systemd backup/check/drill timers, raw Telegram failure/drill alerts, and safe restore/promote workflows.

## Read this first

- Do not put B2 keys, restic passwords, Telegram tokens, raw backup archives, or restored secret files in Git, chat, issues, PRs, or docs.
- `./install.sh` is safe/inert: it prompts locally, writes local config, renders units, and reloads user systemd. It does not run backups, restores, checks, drills, restic init, Telegram tests, B2 calls, or timer starts.
- You are not protected until a first backup, first check, and restore drill have passed.
- Restore is safe by default: `scripts/restore.sh` writes to an inspection directory. Live replacement requires the separate explicit `scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE ...` command.

## Quick Start: get it running safely

Run from a local shell on the Hermes VM as user `agent`.

### 1. Clone and enter the repo

```bash
git clone https://github.com/dannyfranca/hermes-backup.git ~/hermes-backup
cd ~/hermes-backup
```

### 2. Check local prerequisites

```bash
scripts/preflight.sh --check
```

Required local tools:

- `restic`
- `sqlite3`
- `rsync`
- `curl`
- user-level `systemd` via `systemctl --user`

### 3. Prepare secrets in the password manager

Open Danny's password manager before setup. You need:

- Backblaze B2 key ID and application key for the backup bucket.
- Restic repository location, such as `b2:bucket-name:path`.
- Restic repository password.
- Telegram bot token and chat ID for raw Bot API alerts.

See `docs/password-manager-checklist.md` for the recovery escrow checklist.

### 4. Install local config and user units

```bash
./install.sh
```

What this does:

- Runs the offline preflight before any secret prompt.
- Prompts locally for B2/restic/Telegram values if local config does not exist.
- Writes local-only files under `~/.config/hermes-backup/` with owner-only permissions.
- Renders backup/check/restore-drill user systemd units into `~/.config/systemd/user/`.
- Runs `systemctl --user daemon-reload`.
- Leaves timers disabled by default.

### 5. Activate only after local config exists

Recommended full first-run path:

```bash
scripts/activate.sh --init-restic --telegram-test --first-backup --first-check --enable-timers
systemctl --user list-timers --all 'hermes-backup-*'
```

This is the first point that may initialize restic, send a Telegram setup test, run a backup, run a repository check, or enable timer symlinks. Timer enablement uses `systemctl --user enable` without `--now`, so it does not immediately dispatch jobs.

For a side-effect preview:

```bash
scripts/activate.sh --dry-run --init-restic --telegram-test --first-backup --first-check --enable-timers
```

### 6. Verify before trusting it

```bash
scripts/check.sh
scripts/restic-check.sh
scripts/restore-drill.sh
systemctl --user status hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
```

Use `scripts/restore-drill.sh --keep-artifacts` only when you need manual inspection, then delete retained drill output because it can contain restored secrets.

## Common commands

| Need | Command | Safe default |
| --- | --- | --- |
| Offline repo/test harness | `scripts/check.sh` | No B2/restic repo/Telegram/timer side effects. |
| Local runtime prerequisite check | `scripts/preflight.sh --check` | No secret reads or network calls. |
| Write/reuse local config | `./install.sh` | Prompts locally; timers disabled. |
| Preview first-run activation | `scripts/activate.sh --dry-run ...` | Prints redacted plan/status only. |
| First backup/check/timer gate | `scripts/activate.sh --init-restic --telegram-test --first-backup --first-check --enable-timers` | Operator-controlled; enables timers only after first backup/check success. |
| Manual backup + retention | `scripts/backup.sh` | Uses staging; success quiet in Telegram. |
| Repository health check | `scripts/restic-check.sh` | Sends one raw Telegram alert only on check failure when configured. |
| Safe restore for inspection | `scripts/restore.sh` | Restores to `~/restore/hermes-vm-backup/latest-<timestamp>`. |
| Monthly drill now | `scripts/restore-drill.sh` | Restores to a drill directory, verifies, reports, cleans up by default. |
| Promote inspected restore | `scripts/promote.sh --dry-run "$RESTORE_DIR"` then confirmed promote | Never automatic; requires explicit confirmation token. |

## What gets backed up

Included live roots:

- `/home/agent/.hermes` — Hermes configuration, profiles, memories, Kanban state, gateway setup, and related local state.
- `/home/agent/shared` — generated reports and human-facing shared outputs.
- `/home/agent/shared-assets` — static shared assets served from the VM.
- `/home/agent/.config/systemd/user` — user service definitions.
- `/home/agent/.config/containers/systemd` — rootless Podman Quadlet definitions.

Excluded/rebuildable state:

- `/home/agent/git`, canonical clones, task worktrees, and other rebuildable repositories.
- Caches, build outputs, virtual environments, dependency folders, `node_modules`, model downloads, and media libraries.
- Honcho data/configuration.
- Proxmox-level backup automation.

The manifest sources are `config/manifests/include.paths` and `config/manifests/exclude.patterns`. See `docs/operations.md#scope-manifests-and-staging` for staging details.

## Scheduling and alerts

- Scheduling uses user systemd timers, not Hermes cron.
- Alerts and drill reports use the raw Telegram Bot API from local config, not the Hermes gateway.
- Backup/check/drill jobs share one simple non-blocking runtime lock.
- Recommended first setup enables timer units through the explicit activation gate after first backup/check verification; `./install.sh --enable-timers` remains a direct enable-only gate for operators who intentionally choose it.

See `docs/operations.md#user-systemd-timers` for timer names, cadence, and lock behavior.

## Recovery pointer

When the VM is broken, start with `docs/recovery-runbook.md`.

Shortest safe recovery shape:

1. Clone this repo on the replacement VM.
2. Run `scripts/preflight.sh --check` and `./install.sh` locally.
3. Enter B2/restic/Telegram values only into local prompts from the password manager.
4. Run `scripts/activate.sh --telegram-test --first-check` before restore.
5. Run `scripts/restore.sh` and inspect the safe restore directory.
6. Dry-run `scripts/promote.sh --dry-run "$RESTORE_DIR"`.
7. Confirm live promote only after inspection and quiesce review.
8. After restore/promote or credential rotation, run `scripts/activate.sh --first-backup --first-check --enable-timers`.

## Deeper docs

- `docs/bootstrap.md` — install/config/activation contract and local secret handling.
- `docs/operations.md` — staging, backup, restic check, timers, restore drill, and runtime lock behavior.
- `docs/recovery-runbook.md` — panic-mode disaster recovery, safe restore, explicit promote, and post-compromise rotation.
- `docs/password-manager-checklist.md` — recovery secrets Danny must keep outside the VM.

## Repository structure

```text
config/        Placeholder-only config examples and include/exclude manifests.
docs/          Bootstrap, operations, recovery, and password-manager docs.
lib/           Shared shell helpers used by multiple commands.
scripts/       User-facing offline/runtime commands.
systemd/user/  Inert source templates for user systemd services/timers.
tests/         Offline tests for repository contracts and safety checks.
```

## Developer verification

Every foundation-bootstrap PR should include this offline-only harness as evidence:

```bash
scripts/check.sh
```

The harness runs shell syntax checks, pytest coverage for safety behavior, and ignored-file guards. It must not call B2, restic repositories, Telegram, Hermes cron, or `systemctl --user enable/start`.

Collocation baseline:

- Keep one user-facing command per file under `scripts/`.
- Keep script-specific helper logic beside the owning script.
- Move shared shell helpers under `lib/hermes-backup/` only after at least two commands reuse them.
- Keep tests and fixtures nearest to the behavior they verify.
