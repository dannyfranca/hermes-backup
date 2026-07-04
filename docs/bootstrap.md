# Bootstrap baseline

This document defines the bootstrap contract for the foundation implementation tickets. The current slice adds only the local config/secret prompt writer; it does not install packages, enable timers, initialize restic, or run backup/restore behavior.

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

A downstream `bootstrap` command should:

1. Verify or install required local tools: `restic`, `sqlite3`, `rsync`, and `curl`.
2. Call or reuse this config writer instead of reimplementing secret collection.
3. Install user systemd service/timer units from inert repo templates.
4. Initialize or verify the restic repository.
5. Run first-use verification before enabling timers.

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
