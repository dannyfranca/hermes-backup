#!/usr/bin/env bash
# Restic backup and retention/prune flow for hermes-backup.
# Loads local secret env from chmod-600 config, stages first, backs up only the
# staging root, and runs retention pruning only after a successful backup.
{ set +x; } 2>/dev/null || true
set -euo pipefail
HERMES_BACKUP_ALERTS_ENABLED=0
HERMES_BACKUP_FAILURE_RECORDED=0

usage() {
  cat <<'USAGE'
Usage: scripts/backup.sh [--config-env PATH] [--root PATH] [--manifest-dir PATH] [--staging-parent PATH] [--keep-staging]

Runs the backup flow:
  1. Validate and load the local hermes-backup env file.
  2. Run scripts/stage.sh --keep to create a SQLite-safe staging snapshot.
  3. Run restic backup with a stable `hermes-vm-backup` tag against the staging root only.
  4. Run restic forget --prune grouped by host+tag with retention: 7 daily, 8 weekly, 12 monthly, 2 yearly.

The command prints only paths/status/snapshot ids. It never prints B2 keys,
restic passwords, Telegram credentials, file contents, or restic repository data.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() {
  if [[ "${HERMES_BACKUP_ALERTS_ENABLED:-0}" == "1" && "${HERMES_BACKUP_FAILURE_RECORDED:-0}" != "1" ]] && declare -F hb_log_and_alert_failure >/dev/null 2>&1; then
    hb_log_and_alert_failure "backup" "1" "$*" || true
  fi
  printf 'error: %s\n' "$*" >&2
  exit 1
}

SCRIPT_SOURCE=${BASH_SOURCE[0]}
case "$SCRIPT_SOURCE" in */*) SCRIPT_SOURCE=${SCRIPT_SOURCE%/*} ;; *) SCRIPT_SOURCE=. ;; esac
SCRIPT_DIR="$(cd -- "$SCRIPT_SOURCE" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../lib/hermes-backup/log-alert.sh
source "$REPO_ROOT/lib/hermes-backup/log-alert.sh"
# shellcheck source=../lib/hermes-backup/runtime-lock.sh
source "$REPO_ROOT/lib/hermes-backup/runtime-lock.sh"
CONFIG_ENV="${HERMES_BACKUP_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/hermes-backup/hermes-backup.env}"
ROOT_PREFIX=""
MANIFEST_DIR=""
STAGING_PARENT=""
KEEP_STAGING=0
STAGING_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-env)
      [[ $# -ge 2 ]] || fail "--config-env requires a path"
      CONFIG_ENV=$2
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || fail "--root requires a path"
      ROOT_PREFIX=$2
      shift 2
      ;;
    --manifest-dir)
      [[ $# -ge 2 ]] || fail "--manifest-dir requires a path"
      MANIFEST_DIR=$2
      shift 2
      ;;
    --staging-parent)
      [[ $# -ge 2 ]] || fail "--staging-parent requires a path"
      STAGING_PARENT=$2
      shift 2
      ;;
    --keep-staging)
      KEEP_STAGING=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

mode_octal() {
  local path=$1
  stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Lp' -- "$path"
}

mode_is_0600_file() {
  local path=$1 mode
  mode="$(mode_octal "$path")"
  [[ "$mode" == "600" ]]
}

validate_secret_file() {
  local label=$1 path=$2
  [[ -n "$path" ]] || fail "$label path is required"
  case "$path" in /*) ;; *) fail "$label path must be absolute" ;; esac
  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
  [[ -f "$path" ]] || fail "$label not found or not a regular file: $path"
  mode_is_0600_file "$path" || fail "$label permissions are unsafe; run chmod 600 '$path'"
}

require_env() {
  local name=$1 value
  value=${!name:-}
  [[ -n "$value" ]] || fail "$name is required in local config env"
}

cleanup() {
  local rc=$?
  if [[ "$KEEP_STAGING" -eq 0 && -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    remove_staging_root "$STAGING_ROOT"
    if [[ "$rc" -eq 0 ]]; then
      log "cleanup=removed staging_root=$STAGING_ROOT"
    else
      log "cleanup=removed-after-failure staging_root=$STAGING_ROOT" >&2
    fi
  elif [[ "$KEEP_STAGING" -eq 1 && -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    log "cleanup=kept staging_root=$STAGING_ROOT"
  fi
}
trap cleanup EXIT

remove_staging_root() {
  local path=$1
  [[ -n "$path" && -d "$path" ]] || return 0
  case "$path" in /*/stage-*) ;; *) fail "refusing to clean path that does not look like a staging root: $path" ;; esac
  case "$path" in
    /|/home|/home/agent|/home/agent/.hermes|/home/agent/shared|/home/agent/shared-assets|/home/agent/.config|/home/agent/.config/systemd/user|/home/agent/.config/containers/systemd)
      fail "refusing to clean live source root: $path"
      ;;
  esac
  rm -rf -- "$path"
}

parse_staging_root_from_output() {
  local output_file=$1
  awk '
    /^staging_root=/ {sub(/^staging_root=/, ""); print; exit}
    /^cleanup=[^ ]* staging_root=/ {sub(/^cleanup=[^ ]* staging_root=/, ""); print; exit}
  ' "$output_file"
}

strip_comment() {
  local line=$1
  line=${line%%#*}
  line="${line#"${line%%[!$' \t']*}"}"
  line="${line%"${line##*[!$' \t']}"}"
  printf '%s' "$line"
}

is_under_configured_live_root() {
  local candidate=$1 manifest_dir include_manifest line live_path fixture_path
  manifest_dir=${MANIFEST_DIR:-$REPO_ROOT/config/manifests}
  include_manifest="$manifest_dir/include.paths"
  [[ -f "$include_manifest" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    live_path="$(strip_comment "$line")"
    [[ -n "$live_path" ]] || continue
    case "$candidate" in "$live_path"|"$live_path"/*) return 0 ;; esac
    if [[ -n "$ROOT_PREFIX" ]]; then
      fixture_path="$ROOT_PREFIX$live_path"
      case "$candidate" in "$fixture_path"|"$fixture_path"/*) return 0 ;; esac
    fi
  done <"$include_manifest"
  return 1
}

run_restic() {
  (
    unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND
    export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    exec restic "$@"
  )
}

[[ -n "${HOME:-}" ]] || fail "HOME must be set"
case "$CONFIG_ENV" in /*) ;; *) fail "--config-env must be an absolute path" ;; esac
validate_secret_file "local env file" "$CONFIG_ENV"

loaded_env="$(env -i CONFIG_ENV_PATH="$CONFIG_ENV" bash <<'BASH_LOAD_ENV'
{ set +x; } 2>/dev/null || true
exec {xtrace_fd}>/dev/null
BASH_XTRACEFD=$xtrace_fd
source "$CONFIG_ENV_PATH" >/dev/null 2>&1 || exit 10
{ set +x; } 2>/dev/null || true
unset BASH_XTRACEFD
exec {xtrace_fd}>&-
for name in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE HERMES_BACKUP_STAGING_DIR HERMES_BACKUP_LOG_DIR HERMES_BACKUP_LOCK_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
  printf '%s=%q\n' "$name" "${!name-}"
done
BASH_LOAD_ENV
)" || fail "local env file could not be loaded: $CONFIG_ENV"
eval "$loaded_env"
unset loaded_env
HERMES_BACKUP_ALERTS_ENABLED=1
hb_setup_logging || true

for required in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE; do
  require_env "$required"
done
validate_secret_file "local restic password file" "$RESTIC_PASSWORD_FILE"
hb_setup_logging || fail "local log directory could not be prepared"
if ! RESTIC_PASSWORD_VALUE="$(/usr/bin/cat -- "$RESTIC_PASSWORD_FILE" 2>/dev/null)"; then
  hb_log_and_alert_failure "backup" "1" "local restic password file could not be read"
  fail "local restic password file could not be read"
fi
unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND
export -n B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE HERMES_BACKUP_STAGING_DIR HERMES_BACKUP_LOG_DIR HERMES_BACKUP_LOCK_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID RESTIC_PASSWORD_VALUE 2>/dev/null || true
if [[ -z "$STAGING_PARENT" && -n "${HERMES_BACKUP_STAGING_DIR:-}" ]]; then
  STAGING_PARENT=$HERMES_BACKUP_STAGING_DIR
fi
if [[ -n "$ROOT_PREFIX" ]]; then
  case "$ROOT_PREFIX" in /*) ;; *) fail "--root must be an absolute path" ;; esac
  [[ -d "$ROOT_PREFIX" ]] || fail "--root must be an existing directory: $ROOT_PREFIX"
  ROOT_PREFIX="$(cd -- "$ROOT_PREFIX" && pwd -P)"
fi

if hb_acquire_runtime_lock "backup"; then
  log "runtime_lock=acquired lock_file=$HERMES_BACKUP_RUNTIME_LOCK_FILE policy=exclusive backup_contention=fail-alert check_contention=skip-report drill_contention=skip-report"
else
  lock_rc=$?
  if [[ "$lock_rc" -eq 1 ]]; then
    lock_summary="$(hb_runtime_lock_busy_summary "backup")"
    hb_log_and_alert_failure "backup" "75" "$lock_summary" || true
    printf 'error: %s\n' "$lock_summary" >&2
    exit 75
  fi
  hb_log_and_alert_failure "backup" "64" "runtime lock could not be prepared" || true
  fail "runtime lock could not be prepared"
fi

if ! command -v restic >/dev/null 2>&1; then
  hb_log_and_alert_failure "backup" "127" "restic is required for backup"
  fail "restic is required for backup"
fi

STAGE_ARGS=(--keep)
if [[ -n "$ROOT_PREFIX" ]]; then STAGE_ARGS+=(--root "$ROOT_PREFIX"); fi
if [[ -n "$MANIFEST_DIR" ]]; then STAGE_ARGS+=(--manifest-dir "$MANIFEST_DIR"); fi
if [[ -n "$STAGING_PARENT" ]]; then STAGE_ARGS+=(--staging-parent "$STAGING_PARENT"); fi

log "Hermes backup restic flow"
log "config_env=$CONFIG_ENV"
log "stage_command=scripts/stage.sh"
log "retention=keep-daily:7 keep-weekly:8 keep-monthly:12 keep-yearly:2 prune:true group-by:host,tags tag:hermes-vm-backup"

stage_output="$(mktemp -t hermes-backup-stage-output.XXXXXX)"
set +e
env -i PATH="$PATH" HOME="$HOME" bash "$SCRIPT_DIR/stage.sh" "${STAGE_ARGS[@]}" >"$stage_output" 2>&1
stage_rc=$?
set -e
if [[ "$stage_rc" -ne 0 ]]; then
  failed_staging_root="$(parse_staging_root_from_output "$stage_output")"
  sed -n '/^error:/p;/^cleanup=/p' "$stage_output" | while IFS= read -r line || [[ -n "$line" ]]; do hb_redact_line "$line"; done >&2 || true
  hb_log_and_alert_failure "backup" "$stage_rc" "staging failed; restic backup was not run" "$stage_output"
  if [[ -n "$failed_staging_root" && -d "$failed_staging_root" ]]; then
    if is_under_configured_live_root "$failed_staging_root"; then
      remove_staging_root "$failed_staging_root"
      log "cleanup=removed-unsafe-staging-root staging_root=$failed_staging_root" >&2
    elif [[ "$KEEP_STAGING" -eq 0 ]]; then
      remove_staging_root "$failed_staging_root"
      log "cleanup=removed-after-staging-failure staging_root=$failed_staging_root" >&2
    fi
  fi
  rm -f -- "$stage_output"
  exit "$stage_rc"
fi
candidate_staging_root="$(parse_staging_root_from_output "$stage_output")"
rm -f -- "$stage_output"
if [[ -z "$candidate_staging_root" || ! -d "$candidate_staging_root" ]]; then
  hb_log_and_alert_failure "backup" "1" "staging did not produce a usable staging root"
  fail "staging did not produce a usable staging root"
fi
case "$candidate_staging_root" in
  /*) ;;
  *)
    hb_log_and_alert_failure "backup" "1" "staging root is not absolute"
    fail "staging root is not absolute"
    ;;
esac
case "$candidate_staging_root" in
  /|/home|/home/agent|/home/agent/.hermes|/home/agent/shared|/home/agent/shared-assets|/home/agent/.config|/home/agent/.config/systemd/user|/home/agent/.config/containers/systemd)
    hb_log_and_alert_failure "backup" "1" "refusing to point restic at a live source root: $candidate_staging_root"
    fail "refusing to point restic at a live source root: $candidate_staging_root"
    ;;
esac
if is_under_configured_live_root "$candidate_staging_root"; then
  remove_staging_root "$candidate_staging_root"
  log "cleanup=removed-unsafe-staging-root staging_root=$candidate_staging_root" >&2
  hb_log_and_alert_failure "backup" "1" "refusing staging root inside configured live include root: $candidate_staging_root"
  fail "refusing staging root inside configured live include root: $candidate_staging_root"
fi
STAGING_ROOT=$candidate_staging_root

log "staging_root=$STAGING_ROOT"

backup_output="$(mktemp -t hermes-backup-restic-backup.XXXXXX)"
set +e
run_restic backup --json --tag hermes-vm-backup "$STAGING_ROOT" >"$backup_output" 2>&1
backup_rc=$?
set -e
if [[ "$backup_rc" -ne 0 ]]; then
  hb_log_and_alert_failure "backup" "$backup_rc" "restic backup failed; retention/prune was skipped" "$backup_output"
  rm -f -- "$backup_output"
  fail "restic backup failed; retention/prune was skipped"
fi
snapshot_id="$(sed -n 's/.*"snapshot_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$backup_output" | tail -n 1)"
rm -f -- "$backup_output"
if [[ -n "$snapshot_id" ]]; then
  log "backup=ok snapshot_id=$snapshot_id"
else
  log "backup=ok snapshot_id=unavailable"
fi

forget_output="$(mktemp -t hermes-backup-restic-forget.XXXXXX)"
set +e
run_restic forget --tag hermes-vm-backup --group-by host,tags --keep-daily 7 --keep-weekly 8 --keep-monthly 12 --keep-yearly 2 --prune >"$forget_output" 2>&1
forget_rc=$?
set -e
if [[ "$forget_rc" -ne 0 ]]; then
  hb_log_and_alert_failure "backup" "$forget_rc" "restic forget/prune failed after successful backup" "$forget_output"
  rm -f -- "$forget_output"
  fail "restic forget/prune failed after successful backup"
fi
rm -f -- "$forget_output"
log "retention=ok tag=hermes-vm-backup group-by=host,tags keep-daily=7 keep-weekly=8 keep-monthly=12 keep-yearly=2 prune=ok"
hb_log_success "backup" "backup=ok snapshot_id=${snapshot_id:-unavailable} retention=ok"
log "No B2 keys, restic passwords, Telegram tokens, file contents, or backup archives were printed."
