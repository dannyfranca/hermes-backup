#!/usr/bin/env bash
# This script handles live credentials; keep shell tracing disabled even when
# invoked as `bash -x` so supplied values are not echoed to stderr.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/configure.sh [--config-dir PATH] [--non-interactive]

Prompts locally for hermes-backup credentials and writes local config files
outside the repo with owner-only permissions. Values are never printed.

Options:
  --config-dir PATH    Override config directory (default: $XDG_CONFIG_HOME/hermes-backup or ~/.config/hermes-backup)
  --non-interactive    Read required values from environment variables for tests/automation
  -h, --help           Show this help

Required non-interactive environment variables:
  B2_ACCOUNT_ID
  B2_ACCOUNT_KEY
  RESTIC_REPOSITORY
  RESTIC_PASSWORD
  TELEGRAM_BOT_TOKEN
  TELEGRAM_CHAT_ID
USAGE
}

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

config_dir_default() {
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf '%s/hermes-backup\n' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config/hermes-backup\n' "$HOME"
  fi
}

state_dir_default() {
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/hermes-backup\n' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/hermes-backup\n' "$HOME"
  fi
}

shell_escape_single() {
  # Emit a single-quoted shell string without exposing it anywhere except the target file.
  local value=$1
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

require_nonempty() {
  local name=$1
  local value=$2
  if [[ -z "$value" ]]; then
    fail "$name is required and cannot be empty"
  fi
}

read_required() {
  local var_name=$1
  local prompt=$2
  local silent=${3:-false}
  local value=""

  if [[ "$NON_INTERACTIVE" == "1" ]]; then
    value=${!var_name:-}
  else
    if [[ "$silent" == "true" ]]; then
      printf '%s: ' "$prompt" >&2
      IFS= read -r -s value
      printf '\n' >&2
    else
      printf '%s: ' "$prompt" >&2
      IFS= read -r value
    fi
  fi

  require_nonempty "$var_name" "$value"
  printf '%s' "$value"
}

atomic_write_0600() {
  local target=$1
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  chmod 600 "$tmp"
  cat > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
  chmod 600 "$target"
}

validate_output_file() {
  local label=$1
  local path=$2

  if [[ -L "$path" ]]; then
    fail "$label must not be a symlink: $path"
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    fail "$label exists but is not a regular file: $path"
  fi
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_DIR="$(config_dir_default)"
NON_INTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir)
      [[ $# -ge 2 ]] || fail "--config-dir requires a path"
      CONFIG_DIR=$2
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

if [[ -z "${HOME:-}" ]]; then
  fail "HOME must be set"
fi

case "$CONFIG_DIR" in
  "") fail "config directory cannot be empty" ;;
  /*) ;;
  *) fail "config directory must be an absolute path outside the repository" ;;
esac

case "$CONFIG_DIR" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    fail "refusing to write local secret config inside the repository: $CONFIG_DIR"
    ;;
esac

EXISTING_CONFIG_ANCESTOR=$CONFIG_DIR
while [[ ! -e "$EXISTING_CONFIG_ANCESTOR" ]]; do
  parent="$(dirname -- "$EXISTING_CONFIG_ANCESTOR")"
  [[ "$parent" != "$EXISTING_CONFIG_ANCESTOR" ]] || fail "could not resolve config directory parent"
  EXISTING_CONFIG_ANCESTOR=$parent
done
EXISTING_CONFIG_ANCESTOR_REAL="$(cd -- "$EXISTING_CONFIG_ANCESTOR" && pwd -P)" || fail "config directory parent is not a directory"
case "$EXISTING_CONFIG_ANCESTOR_REAL" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    fail "refusing to write local secret config inside the repository: $CONFIG_DIR"
    ;;
esac

umask 077
CONFIG_DIR="$(mkdir -p "$CONFIG_DIR" && cd -- "$CONFIG_DIR" && pwd -P)"
case "$CONFIG_DIR" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    fail "refusing to write local secret config inside the repository: $CONFIG_DIR"
    ;;
esac

chmod 700 "$CONFIG_DIR"

ENV_FILE="$CONFIG_DIR/hermes-backup.env"
RESTIC_PASSWORD_FILE="$CONFIG_DIR/restic-password"
validate_output_file "local env file" "$ENV_FILE"
validate_output_file "local restic password file" "$RESTIC_PASSWORD_FILE"

log "Writing hermes-backup local config under: $CONFIG_DIR"
log "Prompts are local-only. Secret values will not be printed."

B2_ACCOUNT_ID_VALUE="$(read_required B2_ACCOUNT_ID "Backblaze B2 key ID" true)"
B2_ACCOUNT_KEY_VALUE="$(read_required B2_ACCOUNT_KEY "Backblaze B2 application key" true)"
RESTIC_REPOSITORY_VALUE="$(read_required RESTIC_REPOSITORY "Restic repository (for example b2:bucket:path)" true)"
RESTIC_PASSWORD_VALUE="$(read_required RESTIC_PASSWORD "Restic repository password" true)"
TELEGRAM_BOT_TOKEN_VALUE="$(read_required TELEGRAM_BOT_TOKEN "Telegram bot token" true)"
TELEGRAM_CHAT_ID_VALUE="$(read_required TELEGRAM_CHAT_ID "Telegram chat ID" true)"

atomic_write_0600 "$RESTIC_PASSWORD_FILE" <<EOF_PASSWORD
$RESTIC_PASSWORD_VALUE
EOF_PASSWORD

STATE_DIR="$(state_dir_default)"
atomic_write_0600 "$ENV_FILE" <<EOF_ENV
# Generated by hermes-backup scripts/configure.sh.
# Local-only secret material. Do not commit or paste this file.
B2_ACCOUNT_ID=$(shell_escape_single "$B2_ACCOUNT_ID_VALUE")
B2_ACCOUNT_KEY=$(shell_escape_single "$B2_ACCOUNT_KEY_VALUE")
RESTIC_REPOSITORY=$(shell_escape_single "$RESTIC_REPOSITORY_VALUE")
RESTIC_PASSWORD_FILE=$(shell_escape_single "$RESTIC_PASSWORD_FILE")
TELEGRAM_BOT_TOKEN=$(shell_escape_single "$TELEGRAM_BOT_TOKEN_VALUE")
TELEGRAM_CHAT_ID=$(shell_escape_single "$TELEGRAM_CHAT_ID_VALUE")
HERMES_BACKUP_CONFIG_DIR=$(shell_escape_single "$CONFIG_DIR")
HERMES_BACKUP_LOG_DIR=$(shell_escape_single "$STATE_DIR/logs")
HERMES_BACKUP_STAGING_DIR=$(shell_escape_single "$STATE_DIR/staging")
HERMES_BACKUP_RESTORE_DIR=$(shell_escape_single "$HOME/restore/hermes-vm-backup")
EOF_ENV

log "Created local env file: $ENV_FILE (mode 600)"
log "Created local restic password file: $RESTIC_PASSWORD_FILE (mode 600)"
log "Store the B2 key ID, B2 application key, restic repository, restic password, Telegram bot token, and Telegram chat ID in Danny's password manager."
log "No network validation, restic initialization, backup, or systemd timer enablement was run."
