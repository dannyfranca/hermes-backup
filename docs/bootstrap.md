# Bootstrap baseline

This document defines the bootstrap contract for future implementation tickets. The current foundation slice does not install packages, collect secrets, enable timers, or run backup/restore behavior.

## Future bootstrap goals

A downstream `bootstrap` command should:

1. Verify or install required local tools: `restic`, `sqlite3`, `rsync`, and `curl`.
2. Prompt Danny locally for Backblaze B2, restic, and Telegram alert settings.
3. Write local config/env files outside the repository with owner-only permissions.
4. Install user systemd service/timer units from inert repo templates.
5. Initialize or verify the restic repository.
6. Run first-use verification before enabling timers.

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

Those paths are examples of where local state may live; this ticket does not create them.

## Scheduling contract

Backup, check, and restore-drill scheduling must use user-level systemd timers. Do not use Hermes cron for this project because backups must keep running when Hermes itself is unhealthy.

Systemd files in `systemd/user/` are source templates only until a downstream installer writes concrete local units.

## Downstream behavior not implemented here

- No backup/check/restore/promote/drill commands.
- No package installation.
- No live B2, restic, or Telegram prompts.
- No timer enablement.
- No restic repository initialization.
