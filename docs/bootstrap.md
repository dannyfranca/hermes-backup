# Bootstrap baseline

This document defines the bootstrap contract for the foundation implementation tickets. The current slice adds the safe one-command install skeleton, local config/secret prompt writer, and offline preflight composition. It does not install packages, enable timers, initialize restic, call B2/Telegram, or run backup/restore behavior.

## One-command install skeleton

Run the bootstrap skeleton from a local terminal on the VM:

```bash
./install.sh
```

The skeleton runs in this order:

1. `scripts/preflight.sh --check` before any secret prompt.
2. Local state/log/staging, safe restore, and inert systemd template setup.
3. `scripts/configure.sh` only after preflight and local path setup pass.
4. Final inert-scope confirmation; no backup/check/restore/timer action is run.

Default local paths:

```text
~/.config/hermes-backup/hermes-backup.env
~/.config/hermes-backup/restic-password
~/.config/hermes-backup/systemd-templates/
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

## Future bootstrap goals

Downstream tickets should extend this skeleton only after the backing behavior exists:

1. Install missing required local tools when explicitly approved.
2. Convert inert templates into concrete user systemd service/timer units.
3. Initialize or verify the restic repository.
4. Run first-use backup/check/Telegram verification.
5. Enable user systemd timers only after first-use verification passes.

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

Systemd files in `systemd/user/` are source templates only until a downstream installer writes concrete local units.

## Downstream behavior not implemented here

- No backup/check/restore/promote/drill commands.
- No package installation.
- No network validation against B2, restic, or Telegram.
- No timer enablement.
- No restic repository initialization.
