#!/usr/bin/env bash
# Monthly safe restore drill and raw Telegram report for hermes-backup.
# Restores to a drill-only safe directory, verifies expected paths and SQLite DBs,
# writes local logs, and sends a compact report via raw Telegram Bot API.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/restore-drill.sh [--config-env PATH] [--snapshot SNAPSHOT_ID|latest] [--drill-root PATH] [--manifest-dir PATH] [--restore-command PATH] [--keep-artifacts]

Runs a safe monthly restore drill: load local chmod-600 config, restore with
scripts/restore.sh into a drill-only safe directory, verify configured include
roots and restored SQLite databases, write a redacted local drill log, and send
a compact raw Telegram Bot API PASS/FAIL report.

Default drill root: $XDG_STATE_HOME/hermes-backup/drills, or
$HOME/.local/state/hermes-backup/drills

This command never invokes promote.sh or writes to live Hermes/shared/systemd
paths. It never prints B2 keys, restic passwords, Telegram tokens, file contents,
backup archives, or repository URLs.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../lib/hermes-backup/log-alert.sh
source "$REPO_ROOT/lib/hermes-backup/log-alert.sh"
CONFIG_ENV="${HERMES_BACKUP_ENV:-}"
SNAPSHOT="latest"
DRILL_ROOT=""
MANIFEST_DIR="$REPO_ROOT/config/manifests"
RESTORE_COMMAND="$REPO_ROOT/scripts/restore.sh"
KEEP_ARTIFACTS=0
config_env_default() {
  [[ -n "${XDG_CONFIG_HOME:-}" ]] && { printf '%s/hermes-backup/hermes-backup.env\n' "$XDG_CONFIG_HOME"; return; }
  [[ -n "${HOME:-}" ]] && { printf '%s/.config/hermes-backup/hermes-backup.env\n' "$HOME"; return; }
  fail "HOME must be set"
}
drill_root_default() {
  if [[ -n "${HERMES_BACKUP_DRILL_DIR:-}" ]]; then
    printf '%s\n' "$HERMES_BACKUP_DRILL_DIR"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/hermes-backup/drills\n' "$XDG_STATE_HOME"
  else
    [[ -n "${HOME:-}" ]] || fail "HOME must be set"
    printf '%s/.local/state/hermes-backup/drills\n' "$HOME"
  fi
}
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

strip_comment() {
  local line=$1
  line=${line%%#*}
  line="${line#"${line%%[!$' \t']*}"}"
  line="${line%"${line##*[!$' \t']}"}"
  printf '%s' "$line"
}

read_manifest_lines() {
  local file=$1 line cleaned
  while IFS= read -r line || [[ -n "$line" ]]; do
    cleaned="$(strip_comment "$line")"
    [[ -n "$cleaned" ]] || continue
    printf '%s\n' "$cleaned"
  done <"$file"
}

normalize_path() { realpath -m -- "$1"; }
is_same_or_descendant() {
  [[ "$2" == "/" && "$1" == /* ]] || [[ "$1" == "$2" || "$1" == "$2"/* ]]
}
check_drill_root_safety() {
  local root_norm live_path live_norm
  root_norm="$(normalize_path "$1")"
  while IFS= read -r live_path; do
    case "$live_path" in /*) live_norm="$(normalize_path "$live_path")" ;; *) fail "include manifest path must be absolute: $live_path" ;; esac
    if is_same_or_descendant "$root_norm" "$live_norm" || is_same_or_descendant "$live_norm" "$root_norm"; then
      fail "refusing drill root overlapping live include path: drill_root=$root_norm live_path=$live_norm"
    fi
  done < <(read_manifest_lines "$MANIFEST_DIR/include.paths")
}

relative_without_leading_slash() {
  local live_path=$1
  printf '%s\n' "${live_path#/}"
}

is_sqlite_candidate_name() {
  local lower=${1,,}
  case "$lower" in *.db|*.sqlite|*.sqlite3|*.db3) return 0 ;; *) return 1 ;; esac
}

validate_snapshot_selector() {
  local snapshot=$1
  [[ "$snapshot" == "latest" || "$snapshot" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "snapshot must be 'latest' or a single safe snapshot id"
  [[ "$snapshot" != "." && "$snapshot" != ".." ]] || fail "snapshot must be 'latest' or a single safe snapshot id"
}

safe_id_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

make_drill_target() {
  local safe_snapshot timestamp target root_norm target_norm
  safe_snapshot="$(safe_id_component "$SNAPSHOT")"
  timestamp="$(safe_id_component "${HERMES_BACKUP_DRILL_ID:-$(date -u '+%Y%m%dT%H%M%SZ')}")"
  target="$DRILL_ROOT/$timestamp-$safe_snapshot"
  case "$target" in /*) ;; *) fail "computed drill target must be absolute" ;; esac
  root_norm="$(normalize_path "$DRILL_ROOT")"; target_norm="$(normalize_path "$target")"
  is_same_or_descendant "$target_norm" "$root_norm" || fail "computed drill target escaped drill root"
  check_drill_root_safety "$target_norm"
  if [[ -e "$target_norm" ]]; then
    fail "drill target already exists: $target_norm"
  fi
  mkdir -p -- "$target_norm"
  chmod 700 -- "$target_norm" 2>/dev/null || true
  printf '%s\n' "$target_norm"
}

record_failure() {
  local summary=$1 details_file=${2:-} exit_code=${3:-1}
  HERMES_BACKUP_FAILURE_RECORDED=1
  hb_log_event "drill" "failure" "$exit_code" "$summary" "$details_file" || true
  if hb_send_drill_report "FAIL" "$summary" "$details_file"; then
    log "drill_report=sent transport=raw-telegram-api"
  else
    log "drill_report=failed-or-skipped transport=raw-telegram-api"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-env)
      [[ $# -ge 2 ]] || fail "--config-env requires a path"
      CONFIG_ENV=$2
      shift 2
      ;;
    --snapshot)
      [[ $# -ge 2 ]] || fail "--snapshot requires a value"
      SNAPSHOT=$2
      shift 2
      ;;
    --drill-root)
      [[ $# -ge 2 ]] || fail "--drill-root requires a path"
      DRILL_ROOT=$2
      shift 2
      ;;
    --manifest-dir)
      [[ $# -ge 2 ]] || fail "--manifest-dir requires a path"
      MANIFEST_DIR=$2
      shift 2
      ;;
    --restore-command)
      [[ $# -ge 2 ]] || fail "--restore-command requires a path"
      RESTORE_COMMAND=$2
      shift 2
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

validate_snapshot_selector "$SNAPSHOT"
CONFIG_ENV=${CONFIG_ENV:-$(config_env_default)}
case "$CONFIG_ENV" in /*) ;; *) fail "--config-env must be an absolute path" ;; esac
case "$MANIFEST_DIR" in /*) ;; *) fail "--manifest-dir must be an absolute path" ;; esac
case "$RESTORE_COMMAND" in /*) ;; *) fail "--restore-command must be an absolute path" ;; esac
[[ -f "$RESTORE_COMMAND" ]] || fail "restore command not found: $RESTORE_COMMAND"
[[ -f "$MANIFEST_DIR/include.paths" ]] || fail "include manifest not found: $MANIFEST_DIR/include.paths"
validate_secret_file "local env file" "$CONFIG_ENV"

loaded_env="$(env -i CONFIG_ENV_PATH="$CONFIG_ENV" bash <<'BASH_LOAD_ENV'
{ set +x; } 2>/dev/null || true
exec {xtrace_fd}>/dev/null
BASH_XTRACEFD=$xtrace_fd
source "$CONFIG_ENV_PATH" >/dev/null 2>&1 || exit 10
{ set +x; } 2>/dev/null || true
unset BASH_XTRACEFD
exec {xtrace_fd}>&-
for name in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID HERMES_BACKUP_LOG_DIR HERMES_BACKUP_DRILL_DIR; do
  printf '%s=%q\n' "$name" "${!name-}"
done
BASH_LOAD_ENV
)" || fail "local env file could not be loaded: $CONFIG_ENV"
eval "$loaded_env"
unset loaded_env
export -n B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID HERMES_BACKUP_LOG_DIR HERMES_BACKUP_DRILL_DIR 2>/dev/null || true
if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
  validate_secret_file "local restic password file" "$RESTIC_PASSWORD_FILE"
  RESTIC_PASSWORD_VALUE="$(cat -- "$RESTIC_PASSWORD_FILE" 2>/dev/null || true)"
  export -n RESTIC_PASSWORD_VALUE 2>/dev/null || true
fi

DRILL_ROOT=${DRILL_ROOT:-$(drill_root_default)}
case "$DRILL_ROOT" in /*) ;; *) fail "--drill-root/HERMES_BACKUP_DRILL_DIR must be an absolute path" ;; esac
check_drill_root_safety "$DRILL_ROOT"
log_dir_candidate="$(hb_log_dir_default)" || fail "local log directory could not be resolved"
check_drill_root_safety "$log_dir_candidate"
mkdir -p -- "$DRILL_ROOT"
chmod 700 -- "$DRILL_ROOT" 2>/dev/null || true
hb_setup_logging || fail "local log directory could not be prepared"

drill_target="$(make_drill_target)"
restore_output="$(mktemp -t hermes-backup-drill-restore.XXXXXX)"
verify_output="$(mktemp -t hermes-backup-drill-verify.XXXXXX)"
cleanup() {
  rm -f -- "$restore_output" "$verify_output"
  if [[ "${KEEP_ARTIFACTS:-0}" -eq 0 && -n "${drill_target:-}" ]]; then
    rm -rf -- "$drill_target"
  fi
}
trap cleanup EXIT

log "Hermes backup restore drill"
log "snapshot=$SNAPSHOT"
log "drill_target=$drill_target"
log "mode=temporary-safe-restore promote=false keep_artifacts=$KEEP_ARTIFACTS"

set +e
"$RESTORE_COMMAND" --config-env "$CONFIG_ENV" --snapshot "$SNAPSHOT" --target "$drill_target" --manifest-dir "$MANIFEST_DIR" >"$restore_output" 2>&1
restore_rc=$?
set -e
if [[ "$restore_rc" -ne 0 ]]; then
  summary="restore failed snapshot=$SNAPSHOT target=$drill_target"
  printf 'restore=failed exit=%s\n' "$restore_rc" >&2
  record_failure "$summary" "$restore_output" "$restore_rc"
  exit "$restore_rc"
fi

present=0
missing=0
while IFS= read -r live_path; do
  case "$live_path" in /*) ;; *) fail "include manifest path must be absolute: $live_path" ;; esac
  restored_path="$drill_target/$(relative_without_leading_slash "$live_path")"
  if [[ -e "$restored_path" ]]; then
    printf 'verify path=%s status=present\n' "$live_path" >>"$verify_output"
    present=$((present + 1))
  else
    printf 'verify path=%s status=missing\n' "$live_path" >>"$verify_output"
    missing=$((missing + 1))
  fi
done < <(read_manifest_lines "$MANIFEST_DIR/include.paths")

sqlite_checked=0
sqlite_failed=0
while IFS= read -r -d '' sqlite_db; do
  is_sqlite_candidate_name "$sqlite_db" || continue
  sqlite_checked=$((sqlite_checked + 1))
  if ! command -v sqlite3 >/dev/null 2>&1; then
    printf 'sqlite path=%s status=failed reason=sqlite3-missing\n' "${sqlite_db#"$drill_target/"}" >>"$verify_output"
    sqlite_failed=$((sqlite_failed + 1))
    continue
  fi
  if [[ "$(sqlite3 "$sqlite_db" 'PRAGMA integrity_check;' 2>/dev/null || true)" == "ok" ]]; then
    printf 'sqlite path=%s status=ok\n' "${sqlite_db#"$drill_target/"}" >>"$verify_output"
  else
    printf 'sqlite path=%s status=failed reason=integrity-check\n' "${sqlite_db#"$drill_target/"}" >>"$verify_output"
    sqlite_failed=$((sqlite_failed + 1))
  fi
done < <(find "$drill_target" -type f -print0 2>/dev/null)

if [[ "$missing" -ne 0 || "$sqlite_failed" -ne 0 ]]; then
  summary="verification failed snapshot=$SNAPSHOT target=$drill_target present=$present missing=$missing sqlite_checked=$sqlite_checked sqlite_failed=$sqlite_failed"
  cat "$verify_output"
  log "drill=failed present=$present missing=$missing sqlite_checked=$sqlite_checked sqlite_failed=$sqlite_failed"
  record_failure "$summary" "$verify_output"
  exit 1
fi

summary="verification passed snapshot=$SNAPSHOT target=$drill_target present=$present missing=$missing sqlite_checked=$sqlite_checked sqlite_failed=$sqlite_failed"
cat "$verify_output"
hb_log_event "drill" "success" "0" "$summary" "$verify_output" || true
if hb_send_drill_report "PASS" "$summary" "$verify_output"; then
  log "drill_report=sent transport=raw-telegram-api"
else
  log "drill_report=failed-or-skipped transport=raw-telegram-api"
fi
log "drill=ok present=$present missing=$missing sqlite_checked=$sqlite_checked sqlite_failed=$sqlite_failed"
log "artifacts_retained=$KEEP_ARTIFACTS drill_target=$drill_target"
log "No live Hermes/shared/systemd paths were promoted or overwritten."
log "No B2 keys, restic passwords, Telegram tokens, repository URLs, file contents, or backup archives were printed."
