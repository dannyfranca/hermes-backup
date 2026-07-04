# Security policy

This repo is allowed to contain automation source, placeholder examples, inert templates, docs, and tests. It is not allowed to contain live credentials or generated backup material.

## Never commit

- Backblaze B2 key IDs or application keys.
- Restic repository passwords or password files.
- Telegram bot tokens, chat IDs, or credential dumps.
- Raw backup archives, restic cache data, restore outputs, staging snapshots, or local logs.
- Copied Hermes secrets, `.env` files, private keys, or local config files.

## Allowed examples

Committed examples must use obvious placeholder/example strings only, such as `PLACEHOLDER_B2_KEY_ID`, `PLACEHOLDER_B2_APPLICATION_KEY`, `PLACEHOLDER_TELEGRAM_BOT_TOKEN`, or `EXAMPLE_RESTIC_REPOSITORY`.

## Local secret storage

Future bootstrap work must prompt locally and store live values outside the repository with owner-only permissions. Danny's password manager is the recovery source for the B2 key, restic password, and Telegram alert credential.

## Restore safety

Default restore behavior must write into a safe restore directory and must not overwrite live Hermes state. Any live replacement requires a separate explicit promote command that backs up current state first.
