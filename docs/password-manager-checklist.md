# Password-manager checklist

Store these values in Danny's password manager before relying on the backup system for disaster recovery. Do not paste them into chat, GitHub, issues, PRs, shared docs, or committed files.

## Required recovery secrets

- Backblaze B2 key ID for the dedicated backup bucket/application key.
- Backblaze B2 application key for the dedicated backup bucket/application key.
- Restic repository location, for example `b2:bucket-name:path`.
- Restic repository password.
- Telegram bot token used for raw Bot API backup alerts.
- Telegram chat ID used for backup failure and restore-drill alerts.

## Local files created by `scripts/configure.sh`

By default the config writer creates these local-only files outside the repo:

```text
~/.config/hermes-backup/hermes-backup.env
~/.config/hermes-backup/restic-password
```

Both files are written with owner-only `0600` permissions, and the config directory is restricted to `0700`. These files are inputs for later backup/check/drill scripts; they are not recovery escrow. The password manager is the source of truth if the VM is lost.

## Rotation note

After restoring from a suspected compromise, rotate the Backblaze B2 application key, Telegram bot token, and any other provider credentials included in the encrypted Hermes backup.
