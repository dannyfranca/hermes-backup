# Recovery runbook and disaster checklist

This is the panic-mode runbook for rebuilding Danny's Hermes VM from the `dannyfranca/hermes-backup` repository and an encrypted restic backup in Backblaze B2.

Keep this rule in mind throughout recovery:

> `scripts/restore.sh` restores into a safe inspection directory. It must not overwrite live Hermes state. `scripts/promote.sh` is the separate, explicit, dangerous live replacement step.

## 0. Panic-mode checklist

Use this when the VM is broken and you need the shortest safe path.

1. Get base access to a fresh Ubuntu VM as user `agent`.
2. Install minimum tools if they are missing: `git`, `restic`, `sqlite3`, `rsync`, `curl`, and user-level `systemd`.
3. Clone the recovery repo:

   ```bash
   git clone https://github.com/dannyfranca/hermes-backup.git ~/hermes-backup
   cd ~/hermes-backup
   ```

4. Open Danny's password manager and find the entries listed in `docs/password-manager-checklist.md`.
5. Run the offline preflight before entering secrets:

   ```bash
   scripts/preflight.sh --check
   ```

6. Run bootstrap locally and enter secrets only into the local terminal prompts:

   ```bash
   ./install.sh
   ```

7. Run the explicit activation/check path for repository health before restore. This sends one raw Telegram setup-test and runs a repository check without taking a fresh replacement-VM backup that could become the `latest` snapshot:

   ```bash
   scripts/activate.sh --telegram-test --first-check
   ```

8. Restore the latest backup into the safe, non-live restore directory:

   ```bash
   scripts/restore.sh
   ```

9. Inspect the restore output and run the verification checklist below. Do not promote until the safe restore looks right.
10. Dry-run the live promote and quiesce plan:

    ```bash
    scripts/promote.sh --dry-run "$HOME/restore/hermes-vm-backup/latest"
    ```

11. Read the `quiesce ...` lines. If any non-reviewed Hermes service/process is active or a probe is unavailable, stop/account for it manually or proceed only with the explicit quiesce acknowledgement described in Section 6.
12. If the dry-run and quiesce plan are correct, run the explicit promote command:

    ```bash
    scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE "$HOME/restore/hermes-vm-backup/latest"
    ```

13. Enable the approved backup/check/restore-drill user timers after restore/promote verification, or after Section 10 credential rotation if compromise is suspected. The activation gate requires a successful first backup/check in the same run before timer enablement and creates enabled symlinks without `--now`; start the timer units manually only if current-session scheduling is desired and systemd catch-up behavior is acceptable:

    ```bash
    scripts/activate.sh --first-backup --first-check --enable-timers
    systemctl --user start hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
    systemctl --user status hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
    systemctl --user list-timers --all 'hermes-backup-*'
    ```

13. If recovery followed a suspected compromise, rotate credentials before trusting the restored VM.

## 1. What this backup is expected to contain

Included state:

- `/home/agent/.hermes` — Hermes config, profiles, memory/state, Kanban DBs, gateway setup, and profile data.
- `/home/agent/shared` — generated reports and human-facing shared outputs.
- `/home/agent/shared-assets` — static shared assets served from the VM.
- `/home/agent/.config/systemd/user` — user service definitions.
- `/home/agent/.config/containers/systemd` — rootless Podman Quadlet definitions.

Excluded state:

- `/home/agent/git`, canonical clones, worktrees, and other rebuildable repositories.
- Caches, build outputs, virtualenvs, dependency folders, `node_modules`, media libraries, and model downloads.
- Honcho data/configuration.
- Proxmox-level VM backup automation.

The backup engine is restic with client-side encryption stored in Backblaze B2. Scheduling uses user systemd timers. Alerts and restore-drill reports use the raw Telegram Bot API from local config; they must not depend on the Hermes gateway.

## 2. Recovery prerequisites

Before relying on the runbook, make sure Danny's password manager contains:

- Backblaze B2 key ID for the dedicated backup bucket/application key.
- Backblaze B2 application key for the dedicated backup bucket/application key.
- Restic repository location.
- Restic repository password.
- Telegram bot token for raw Bot API backup alerts.
- Telegram chat ID for backup failure and restore-drill reports.

Do not paste these values into chat, GitHub, issues, PRs, shared docs, or committed files. `./install.sh` and `scripts/configure.sh` prompt locally and write only local files under `~/.config/hermes-backup/` with owner-only permissions.

## 3. Fresh VM bootstrap

Run these from a local shell on the replacement VM.

1. Clone the target repo and enter it:

   ```bash
   git clone https://github.com/dannyfranca/hermes-backup.git ~/hermes-backup
   cd ~/hermes-backup
   ```

2. Run the runtime preflight. This must not call B2, Telegram, restic repositories, Hermes cron, or `systemctl --user enable/start`:

   ```bash
   scripts/preflight.sh --check
   ```

   Optional developer verification: if Python and pytest are available on the replacement VM, `scripts/check.sh` runs the full offline repo harness before recovery. Do not let missing pytest block an emergency restore when `scripts/preflight.sh --check` passes.

3. Run bootstrap and answer local prompts from the password manager:

   ```bash
   ./install.sh
   ```

   Bootstrap creates or reuses:

   ```text
   ~/.config/hermes-backup/hermes-backup.env
   ~/.config/hermes-backup/restic-password
   ~/.config/systemd/user/hermes-backup-backup.service
   ~/.config/systemd/user/hermes-backup-backup.timer
   ~/.config/systemd/user/hermes-backup-check.service
   ~/.config/systemd/user/hermes-backup-check.timer
   ~/.config/systemd/user/hermes-backup-restore-drill.service
   ~/.config/systemd/user/hermes-backup-restore-drill.timer
   ~/.local/state/hermes-backup/logs/
   ~/.local/state/hermes-backup/staging/
   ~/restore/hermes-vm-backup/
   ```

4. Do not enable timers until the repository check, safe restore, and operator verification pass. For recovery verification before restore, use a check-only activation path so the replacement VM does not create a new backup before `restore.sh latest`:

   ```bash
   scripts/activate.sh --telegram-test --first-check
   ```

   When ready after verification, enable only the approved user timers through the activation gate:

   ```bash
   scripts/activate.sh --first-backup --first-check --enable-timers
   systemctl --user list-timers --all 'hermes-backup-*'
   ```

Timer enablement uses `systemctl --user enable` without `--now`, so it does not immediately run backup, check, or restore-drill jobs.

## 4. Safe restore workflow

Normal restore is inspection-only and non-live.

1. Confirm local config is present and safe:

   ```bash
   scripts/restic-check.sh
   ```

2. Restore latest into the default safe target:

   ```bash
   scripts/restore.sh
   ```

   Default target:

   ```text
   ~/restore/hermes-vm-backup/latest
   ```

3. Or restore a specific snapshot into a separate safe target:

   ```bash
   scripts/restore.sh --snapshot SNAPSHOT_ID
   ```

4. Never pass a live include path as `--target`. `restore.sh` refuses targets that equal, contain, or sit inside configured live include roots, but the operator should still treat live paths as forbidden restore targets.

`restore.sh` writes a non-secret `.hermes-backup-restore.json` marker in the restored tree. `promote.sh` requires that marker later.

## 5. Safe restore verification checklist

Run these checks against the restored directory before any promote command.

Set the restored directory once:

```bash
RESTORE_DIR="$HOME/restore/hermes-vm-backup/latest"
```

Expected path checks:

```bash
test -d "$RESTORE_DIR/home/agent/.hermes"
test -d "$RESTORE_DIR/home/agent/shared"
test -d "$RESTORE_DIR/home/agent/shared-assets"
test -d "$RESTORE_DIR/home/agent/.config/systemd/user"
test -d "$RESTORE_DIR/home/agent/.config/containers/systemd"
test -f "$RESTORE_DIR/.hermes-backup-restore.json"
```

Important SQLite integrity checks:

```bash
find "$RESTORE_DIR/home/agent/.hermes" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db3' \) -print0 \
  | while IFS= read -r -d '' db; do
      echo "checking $db"
      sqlite3 "$db" 'PRAGMA integrity_check;'
    done
```

Review the output. Every SQLite database should report `ok`. If an expected path is missing or a database is not healthy, stop and inspect another snapshot instead of promoting.

Spot-check that excluded rebuildable state was not restored. These checks are not a full exclude audit; they catch the highest-risk rebuildable top-level trees before promote:

```bash
test ! -e "$RESTORE_DIR/home/agent/git"
test ! -e "$RESTORE_DIR/home/agent/.cache"
```

## 6. Explicit live promote workflow

Promote only after the safe restore has been inspected and Hermes activity is quiesced.

1. Dry-run the promote and quiesce plan:

   ```bash
   scripts/promote.sh --dry-run "$RESTORE_DIR"
   ```

2. Read the planned live replacements, pre-promotion backup path, and `quiesce ...` lines. The dry-run is non-mutating: it must not stop services, copy files, or create the pre-promotion backup directory.
3. Stop or account for active Hermes activity before the confirmed promote:
   - `hermes-gateway.service` and `hermes-dashboard.service` are the reviewed service allowlist that `promote.sh` may stop automatically in confirmed mode.
   - Any other active `hermes*.service`, Hermes gateway/dashboard/Kanban process, or unavailable service/process probe requires operator review. Stop it manually when appropriate.
   - Do not broadly `kill`, `pkill`, or stop unrelated user processes just because they contain nearby project paths.
4. Run the explicit confirmed command only when the plan is expected:

   ```bash
   scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE "$RESTORE_DIR"
   ```

   If the script still reports active or unverified Hermes services/processes after reviewed services are stopped, either stop them manually and rerun, or proceed only after explicitly acknowledging the quiesce risk:

   ```bash
   scripts/promote.sh --yes --confirm PROMOTE-HERMES-RESTORE --quiesce-ack PROMOTE-HERMES-QUIESCE "$RESTORE_DIR"
   ```

5. Keep the printed pre-promotion backup path. It is the rollback point for the previous live state.

Promote may stop only the reviewed service allowlist, replace configured live include roots, reload user systemd state, and print a post-promote checklist. It must not run from install, restore, timers, backup, check, or drill paths.

## 7. Post-promote verification checklist

After promote, verify the VM is usable before declaring recovery done.

1. Reload user systemd state:

   ```bash
   systemctl --user daemon-reload
   ```

2. Enable the approved backup/check/restore-drill user timers after restore/promote verification, or after Section 10 credential rotation if compromise is suspected. `--enable-timers` creates enabled symlinks without `--now`; start the timer units manually only if current-session scheduling is desired and systemd catch-up behavior is acceptable, then inspect restored user units and backup timers:

   ```bash
   scripts/activate.sh --first-backup --first-check --enable-timers
   systemctl --user start hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
   systemctl --user list-unit-files | grep '^hermes' || true
   systemctl --user status hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
   systemctl --user list-timers --all 'hermes-backup-*'
   ```

3. Run backup repo checks from the clone:

   ```bash
   scripts/check.sh
   scripts/restic-check.sh
   ```

4. Verify Hermes-critical paths exist in live state:

   ```bash
   test -d /home/agent/.hermes
   test -d /home/agent/shared
   test -d /home/agent/shared-assets
   test -d /home/agent/.config/systemd/user
   test -d /home/agent/.config/containers/systemd
   ```

5. Run SQLite integrity checks against restored Hermes databases if the VM is quiet enough to inspect them safely:

   ```bash
   find /home/agent/.hermes -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db3' \) -print0 \
     | while IFS= read -r -d '' db; do
         echo "checking $db"
         sqlite3 "$db" 'PRAGMA integrity_check;'
       done
   ```

6. Run a safe restore drill with default cleanup, confirm the raw Telegram report arrives, and check output/logs for `drill_report=sent transport=raw-telegram-api`:

   ```bash
   scripts/restore-drill.sh
   ```

   Use `--keep-artifacts` only when manual inspection is necessary, and delete the retained drill directory immediately after inspection because it can contain restored secrets.

7. Check local logs under `~/.local/state/hermes-backup/logs/` for backup/check/drill status. Logs must be redacted and must not contain secret values.

## 8. Monthly restore drill interpretation

The monthly drill timer runs the safe drill command through user systemd:

```text
hermes-backup-restore-drill.timer -> hermes-backup-restore-drill.service -> scripts/restore-drill.sh
```

The drill restores only into a drill directory under `HERMES_BACKUP_DRILL_DIR`, `XDG_STATE_HOME/hermes-backup/drills`, or `~/.local/state/hermes-backup/drills`. It verifies configured include roots, runs SQLite integrity checks for restored `*.db` files, writes a redacted local log, and sends a compact raw Telegram Bot API report.

Expected report shape:

```text
Hermes backup restore drill
status: PASS or FAIL
time: <UTC timestamp>
host: <hostname>
summary: verification passed snapshot=<id-or-latest> target=<safe-drill-path> present=<count> missing=0 sqlite_checked=<count> sqlite_failed=0
details:
verify path=<include-root> status=present
```

A `PASS` means the latest configured backup restored into a safe directory and basic integrity checks passed. It does not mean live promote was run. A `FAIL` means Danny should inspect logs and run a manual safe restore before trusting the backup.

## 9. Verification plan for normal operations

Use this after setup and periodically after changes.

- Bootstrap/config safety: `scripts/check.sh` and `scripts/preflight.sh --check` pass.
- Backup path: `scripts/backup.sh` creates a tagged restic snapshot and keeps success quiet in Telegram.
- Check path: `scripts/restic-check.sh` exits `0` for a healthy repository and sends one raw Telegram failure alert on simulated failure when local Telegram config exists.
- Safe restore path: `scripts/restore.sh` restores into `~/restore/hermes-vm-backup/latest` or a snapshot-specific safe directory and prints expected include-root status.
- Promote path: `scripts/promote.sh --dry-run <restore-dir>` is reviewed before any `--yes --confirm PROMOTE-HERMES-RESTORE` run.
- Activation/timer path: `scripts/activate.sh --init-restic --telegram-test --first-backup --first-check --enable-timers` is the full first-run setup sequence after `./install.sh`; timer enablement requires first backup/check verification and uses `systemctl --user enable` without `--now`. After a new user-manager activation or an explicit `systemctl --user start hermes-backup-*.timer`, `systemctl --user list-timers --all 'hermes-backup-*'` shows current-session schedules.
- Drill path: `scripts/restore-drill.sh` verifies a safe drill restore, does not invoke promote, and raw Telegram delivery is proven by the message arriving or by `drill_report=sent transport=raw-telegram-api` in output/logs. Use `--keep-artifacts` only for manual inspection and delete retained artifacts promptly.
- Logs: `~/.local/state/hermes-backup/logs/` contains redacted local logs with no B2 keys, restic passwords, Telegram tokens, repository URLs, file contents, or backup archives.
- SQLite: restored `*.db`, `*.sqlite`, `*.sqlite3`, and `*.db3` files report `ok` from `PRAGMA integrity_check`.

## 10. Credential rotation after suspected compromise

If the old VM may have been compromised, assume credentials inside the encrypted backup may also be compromised after restore.

Rotate at minimum:

- Backblaze B2 application key used by restic.
- Restic repository password/key material. If practical, create a new restic repository with a new password and take a fresh backup after rotating provider secrets; otherwise document the residual risk that old copied repository objects remain decryptable with the old restic password.
- Telegram bot token used for raw Bot API alerts.
- GitHub, model provider, gateway, SSH, Tailscale, and other provider credentials found in restored Hermes config.
- Any local `.env` or service credentials restored under `/home/agent/.hermes`, `/home/agent/shared`, user systemd units, or Quadlets.

After rotation:

1. Update local config through local prompts or manual local edits only; do not paste secrets into chat or GitHub.
2. Run `scripts/restic-check.sh`.
3. Run one manual `scripts/backup.sh` after accepting that the new credentials are active.
4. Run `scripts/restore-drill.sh` and confirm the raw Telegram report arrives. Use `--keep-artifacts` only when manual inspection is necessary, and delete the retained drill directory immediately after inspection because it can contain restored secrets.
5. Update the password manager entries so future recovery does not depend on the old VM.

## 11. Stop conditions

Stop and get help before promote if any of these happen:

- You do not have the restic password or cannot open the Backblaze B2 repository.
- `scripts/restore.sh` cannot produce a safe restore directory.
- The safe restore directory is missing expected Hermes/shared/systemd/Quadlet roots.
- Any critical SQLite database fails integrity checks.
- `scripts/promote.sh --dry-run` plans to touch paths outside the configured include roots.
- You are not sure whether the old VM was compromised and credentials have not been rotated.
