# Bootstrap baseline

This document defines the bootstrap contract for the foundation implementation tickets. The current scheduler path includes the safe one-command install skeleton, local config/secret prompt writer, offline preflight composition, and backup/check/restore-drill user systemd unit rendering. Timers are disabled by default; `./install.sh --enable-timers` enables the backup/check/restore-drill timer symlinks through the same verification gate, without `--now`. It does not install packages, initialize restic, call B2/Telegram, run backup/restore/drill behavior, or use Hermes cron.

## Required offline verification harness

Run this command before every foundation-bootstrap PR handoff:

```bash
scripts/check.sh
```

The harness verifies bootstrap/config safety without live secrets or live backup operations. It runs Bash syntax checks, pytest coverage for missing-tool and successful fixture preflight behavior, local config permission/write behavior, install orchestration, no secret/log leakage, no Hermes cron scheduling, and no user systemd timer enablement side effects. It also fails if a local-secret/runtime-output ignore rule accidentally matches a tracked file.

Future restore/drill tickets should extend the nearest owning test file or add a focused sibling test file instead of creating a separate harness.

## One-command install skeleton

Run the bootstrap skeleton from a local terminal on the VM:

```bash
./install.sh
```

The skeleton runs in this order:

1. `scripts/preflight.sh --check` before any secret prompt.
2. Local state/log/staging, safe restore, and systemd user unit directory setup.
3. `scripts/configure.sh` only when local config files do not already exist; otherwise reuse the existing chmod-600 local config.
4. Render backup/check/restore-drill unit files from `systemd/user/` into `~/.config/systemd/user/` and run `systemctl --user daemon-reload`.
5. Leave timers disabled by default, or enable only the approved user timers when `--enable-timers` is passed after local scheduler verification.

Default local paths:

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

The bootstrap output prints paths and next-step caveats only. It must not print B2 keys, restic passwords, Telegram bot tokens, or other secret values.

For tests or disposable automation only, `./install.sh` passes through non-interactive dummy values to `scripts/configure.sh`:

```bash
B2_ACCOUNT_ID=... \
B2_ACCOUNT_KEY=... \
RESTIC_REPOSITORY=... \
RESTIC_PASSWORD=... \
TELEGRAM_BOT_TOKEN=... \
TELEGRAM_CHAT_ID=... \
./install.sh --config-dir /absolute/test/config/dir --non-interactive
```

Use obvious dummy values in non-interactive mode. Do not pass real secrets through chat, CI logs, shell history, GitHub, or committed files.

## Local config writer

Run the config writer from a local terminal on the VM:

```bash
scripts/configure.sh
```

It prompts locally for:

1. Backblaze B2 key ID.
2. Backblaze B2 application key.
3. Restic repository, for example `b2:bucket-name:path`.
4. Restic repository password.
5. Telegram bot token for raw Bot API alerts.
6. Telegram chat ID for backup alerts.

The script writes local-only files outside the repository, defaulting to:

```text
~/.config/hermes-backup/hermes-backup.env
~/.config/hermes-backup/restic-password
```

The config directory is restricted to `0700`, and both generated files are restricted to `0600`. Secret prompts use silent input where appropriate, and the script prints file paths/status only, never populated secret values.

For tests or disposable automation only, the script also supports:

```bash
B2_ACCOUNT_ID=... \
B2_ACCOUNT_KEY=... \
RESTIC_REPOSITORY=... \
RESTIC_PASSWORD=... \
TELEGRAM_BOT_TOKEN=... \
TELEGRAM_CHAT_ID=... \
scripts/configure.sh --config-dir /absolute/test/config/dir --non-interactive
```

Use obvious dummy values in non-interactive mode. Do not pass real secrets through chat, CI logs, shell history, GitHub, or committed files.

## Remaining bootstrap goals

This scheduler path now renders concrete backup/check/restore-drill user systemd units and can enable those timer symlinks through `./install.sh --enable-timers`. Remaining bootstrap work should extend install only after the backing behavior exists:

1. Install missing required local tools when explicitly approved.
2. Initialize or verify the restic repository.
3. Run first-use backup/check/drill/Telegram verification.
4. Activate timer units in the current user manager session only after first-use verification and operator acceptance of systemd persistent catch-up behavior.

## Dependency preflight

Run the offline preflight before collecting secrets or installing/enabling timers:

```bash
scripts/preflight.sh --check
```

The preflight checks local runtime assumptions only. It does not install packages, prompt for secrets, read secret files, call Backblaze B2, call restic repositories, or send Telegram messages.

Required local tools:

- `restic`
- `sqlite3`
- `rsync`
- `curl`
- user-level `systemd` via `systemctl --user`

If a tool is missing, install it from Danny's local shell using the normal Ubuntu package path or the tool vendor's documented install path. Do not paste B2 keys, restic passwords, Telegram bot tokens, or other credentials into chat, issues, PRs, or committed files.

## Secret handling contract

- Never ask Danny to paste credentials into chat, PRs, issues, docs, or committed files.
- Keep committed examples placeholder-only, using values such as `PLACEHOLDER_B2_KEY_ID` or `EXAMPLE_RESTIC_REPOSITORY`.
- Write live secrets only on the VM, outside Git, with chmod-600-style permissions.
- Recovery-critical secrets must also live in Danny's password manager.

Expected local-only files for downstream work may include paths such as:

```text
~/.config/hermes-backup/hermes-backup.env
~/.config/hermes-backup/restic-password
```

Those paths are examples of where local state lives. They are generated locally by `scripts/configure.sh` and must remain outside Git.

## Scheduling contract

Backup, check, and restore-drill scheduling must use user-level systemd timers. Do not use Hermes cron for this project because backups must keep running when Hermes itself is unhealthy.

The installer renders and installs only the reviewed backup/check/restore-drill units:

```text
~/.config/systemd/user/hermes-backup-backup.service
~/.config/systemd/user/hermes-backup-backup.timer
~/.config/systemd/user/hermes-backup-check.service
~/.config/systemd/user/hermes-backup-check.timer
~/.config/systemd/user/hermes-backup-restore-drill.service
~/.config/systemd/user/hermes-backup-restore-drill.timer
```

Use these manual checks after install:

```bash
systemctl --user status hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer
systemctl --user list-timers --all 'hermes-backup-*'
systemctl --user status hermes-backup-backup.service hermes-backup-check.service hermes-backup-restore-drill.service
```

Timers are not enabled by default. `./install.sh --enable-timers` enables only the approved backup/check/restore-drill timer units through the same local unit/config verification gate. It intentionally uses `systemctl --user enable` without `--now`, so install does not start persistent timers or dispatch missed backup/check/drill runs. `--enable-timers` cannot be combined with `--systemd-user-dir`; custom unit dirs are for tests/staging renders only, so enablement always targets the default user manager path.

## Downstream behavior not implemented here

- No live promote commands.
- `install.sh` does not run backup/check/restore/promote/drill commands.
- No package installation.
- No network validation against B2, restic, or Telegram.
- No restic repository initialization.
