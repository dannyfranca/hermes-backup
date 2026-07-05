#!/usr/bin/env bash
# Safe non-live restic restore flow for hermes-backup.
# Restores a selected snapshot, or latest, into a safe inspection directory and
# verifies expected Hermes/shared/systemd paths without promoting to live state.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/restore.sh [--config-env PATH] [--snapshot SNAPSHOT_ID|latest] [--restore-root PATH] [--target PATH] [--host HOST] [--manifest-dir PATH]

Runs the safe restore flow:
  1. Validate and load the local hermes-backup env file.
  2. Refuse restore targets that equal, contain, or are inside configured live include paths.
  3. Run restic restore for the selected snapshot into a non-live inspection directory.
  4. Print a concise verification summary for expected Hermes/shared/systemd paths.

Default target:
  $HOME/restore/hermes-vm-backup/latest-<UTC timestamp>

Latest host scope:
  When --snapshot latest is selected, restore.sh filters restic by tag
  hermes-vm-backup and by host. The host defaults to
  HERMES_BACKUP_RESTORE_HOST from local config, or this machine's hostname.
  Use --host HOST when restoring a snapshot produced by a different VM name.

This command never promotes restored files into live Hermes state. Live replacement
belongs to a later explicit promote command. It prints only paths/status counts;
it never prints B2 keys, restic passwords, Telegram credentials, file contents, or
restic repository data.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
RESTORE_MARKER_NAME=".hermes-backup-restore.json"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_ENV=""
SNAPSHOT="latest"
RESTORE_ROOT=""
RESTORE_TARGET=""
RESTORE_HOST=""
HOST_EXPLICIT=0
MANIFEST_DIR="$REPO_ROOT/config/manifests"
TARGET_EXPLICIT=0
RESTORE_ROOT_EXPLICIT=0

config_env_default() {
  [[ -n "${HERMES_BACKUP_ENV:-}" ]] && { printf '%s\n' "$HERMES_BACKUP_ENV"; return; }
  [[ -n "${XDG_CONFIG_HOME:-}" ]] && { printf '%s/hermes-backup/hermes-backup.env\n' "$XDG_CONFIG_HOME"; return; }
  [[ -n "${HOME:-}" ]] && { printf '%s/.config/hermes-backup/hermes-backup.env\n' "$HOME"; return; }
  fail "HOME must be set"
}

restore_root_default() {
  [[ -n "${HOME:-}" ]] || fail "HOME must be set"
  printf '%s/restore/hermes-vm-backup\n' "$HOME"
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
    --restore-root)
      [[ $# -ge 2 ]] || fail "--restore-root requires a path"
      RESTORE_ROOT=$2
      RESTORE_ROOT_EXPLICIT=1
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || fail "--target requires a path"
      RESTORE_TARGET=$2
      TARGET_EXPLICIT=1
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || fail "--host requires a value"
      RESTORE_HOST=$2
      HOST_EXPLICIT=1
      shift 2
      ;;
    --manifest-dir)
      [[ $# -ge 2 ]] || fail "--manifest-dir requires a path"
      MANIFEST_DIR=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "${HOME:-}" ]] || fail "HOME must be set"
[[ -n "$SNAPSHOT" ]] || fail "--snapshot must not be empty"
CONFIG_ENV=${CONFIG_ENV:-$(config_env_default)}

case "$CONFIG_ENV" in /*) ;; *) fail "--config-env must be an absolute path" ;; esac
case "$MANIFEST_DIR" in /*) ;; *) fail "--manifest-dir must be an absolute path" ;; esac

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

normalize_path() {
  realpath -m -- "$1"
}

is_same_or_descendant() {
  local candidate=$1 parent=$2
  [[ "$candidate" == "$parent" || "$candidate" == "$parent"/* ]]
}

relative_without_leading_slash() {
  local live_path=$1
  printf '%s\n' "${live_path#/}"
}

validate_snapshot_selector() {
  local snapshot=$1
  [[ "$snapshot" == "latest" || "$snapshot" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "snapshot must be 'latest' or a single safe snapshot id"
  [[ "$snapshot" != "." && "$snapshot" != ".." ]] || fail "snapshot must be 'latest' or a single safe snapshot id"
}

validate_host_selector() {
  local host=$1
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "host filter must be a single safe hostname"
  [[ "$host" != "." && "$host" != ".." ]] || fail "host filter must be a single safe hostname"
}

latest_target_default() {
  local root=$1 timestamp candidate index
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  candidate="$root/latest-$timestamp"
  index=2
  while [[ -e "$candidate" ]]; do
    candidate="$root/latest-$timestamp-$index"
    index=$((index + 1))
  done
  printf '%s\n' "$candidate"
}

check_restore_target_safety() {
  local include_manifest=$1 target=$2 target_norm live_path live_norm
  target_norm="$(normalize_path "$target")"
  while IFS= read -r live_path; do
    case "$live_path" in /*) ;; *) fail "include manifest path must be absolute: $live_path" ;; esac
    live_norm="$(normalize_path "$live_path")"
    if is_same_or_descendant "$target_norm" "$live_norm" || is_same_or_descendant "$live_norm" "$target_norm"; then
      fail "refusing restore target overlapping live include path: target=$target_norm live_path=$live_norm"
    fi
  done < <(read_manifest_lines "$include_manifest")
}

run_restic() {
  (
    unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND
    export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    exec restic "$@"
  )
}

find_restored_source_prefix() {
  local raw_target=$1 include_manifest=$2 live_path rel candidate
  while IFS= read -r live_path; do
    rel="$(relative_without_leading_slash "$live_path")"
    if [[ -e "$raw_target/$rel" ]]; then
      printf '%s\n' "$raw_target"
      return 0
    fi
    candidate="$(find "$raw_target" -path "*/$rel" -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "${candidate%"/$rel"}"
      return 0
    fi
  done < <(read_manifest_lines "$include_manifest")
  return 1
}

materialize_restored_layout() {
  local raw_target=$1 final_target=$2 include_manifest=$3 source_prefix
  source_prefix="$(find_restored_source_prefix "$raw_target" "$include_manifest" || true)"
  [[ -n "$source_prefix" ]] || fail "restic restore completed but no expected include-root layout was found"
  if [[ -e "$final_target/home" ]]; then
    fail "refusing to overwrite existing restored home layout: $final_target/home"
  fi
  if [[ -d "$source_prefix/home" ]]; then
    mv -- "$source_prefix/home" "$final_target/home"
  else
    fail "restic restore did not contain the expected home/ layout under: $source_prefix"
  fi
  rm -rf -- "$raw_target"
  if [[ "$source_prefix" == "$raw_target" ]]; then
    log "layout=flattened source_prefix=.restic-restore-raw"
  else
    log "layout=flattened source_prefix=${source_prefix#"$raw_target"/}"
  fi
}

write_restore_marker() {
  local target=$1 snapshot=$2 marker_tmp marker
  marker="$target/$RESTORE_MARKER_NAME"
  marker_tmp="$marker.tmp.$$"
  cat >"$marker_tmp" <<EOF
{"tool":"restore.sh","mode":"non-live-inspection-only","snapshot":"$snapshot","promote":"false","schema_version":1}
EOF
  chmod 600 "$marker_tmp" 2>/dev/null || true
  mv -- "$marker_tmp" "$marker"
}

INCLUDE_MANIFEST="$MANIFEST_DIR/include.paths"
EXCLUDE_MANIFEST="$MANIFEST_DIR/exclude.patterns"
validate_snapshot_selector "$SNAPSHOT"
[[ -f "$INCLUDE_MANIFEST" ]] || fail "include manifest not found: $INCLUDE_MANIFEST"
[[ -f "$EXCLUDE_MANIFEST" ]] || fail "exclude manifest not found: $EXCLUDE_MANIFEST"
[[ -n "$(read_manifest_lines "$INCLUDE_MANIFEST")" ]] || fail "include manifest is empty: $INCLUDE_MANIFEST"
validate_secret_file "local env file" "$CONFIG_ENV"

loaded_env="$(env -i CONFIG_ENV_PATH="$CONFIG_ENV" bash <<'BASH_LOAD_ENV'
{ set +x; } 2>/dev/null || true
exec {xtrace_fd}>/dev/null
BASH_XTRACEFD=$xtrace_fd
source "$CONFIG_ENV_PATH" >/dev/null 2>&1 || exit 10
{ set +x; } 2>/dev/null || true
unset BASH_XTRACEFD
exec {xtrace_fd}>&-
for name in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE HERMES_BACKUP_RESTORE_DIR HERMES_BACKUP_RESTORE_HOST; do
  printf '%s=%q\n' "$name" "${!name-}"
done
BASH_LOAD_ENV
)" || fail "local env file could not be loaded: $CONFIG_ENV"
eval "$loaded_env"
unset loaded_env

for required in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE; do
  require_env "$required"
done
validate_secret_file "local restic password file" "$RESTIC_PASSWORD_FILE"
unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND
export -n B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE HERMES_BACKUP_RESTORE_DIR HERMES_BACKUP_RESTORE_HOST 2>/dev/null || true

if [[ "$SNAPSHOT" == "latest" ]]; then
  if [[ "$HOST_EXPLICIT" -eq 1 ]]; then
    [[ -n "$RESTORE_HOST" ]] || fail "--host must not be empty"
  else
    RESTORE_HOST=${HERMES_BACKUP_RESTORE_HOST:-$(hostname)}
  fi
  validate_host_selector "$RESTORE_HOST"
fi

if [[ "$RESTORE_ROOT_EXPLICIT" -eq 0 ]]; then
  RESTORE_ROOT=${HERMES_BACKUP_RESTORE_DIR:-$(restore_root_default)}
fi
case "$RESTORE_ROOT" in /*) ;; *) fail "--restore-root/HERMES_BACKUP_RESTORE_DIR must be an absolute path" ;; esac
if [[ "$TARGET_EXPLICIT" -eq 0 ]]; then
  if [[ "$SNAPSHOT" == "latest" ]]; then
    RESTORE_TARGET="$(latest_target_default "$RESTORE_ROOT")"
  else
    RESTORE_TARGET="$RESTORE_ROOT/$SNAPSHOT"
  fi
fi
case "$RESTORE_TARGET" in /*) ;; *) fail "--target must be an absolute path" ;; esac

command -v restic >/dev/null 2>&1 || fail "restic is required for restore"
check_restore_target_safety "$INCLUDE_MANIFEST" "$RESTORE_TARGET"

if [[ -d "$RESTORE_TARGET" && -n "$(find "$RESTORE_TARGET" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "restore target already exists and is not empty: $RESTORE_TARGET"
fi
mkdir -p -- "$RESTORE_TARGET"
chmod 700 "$RESTORE_TARGET" 2>/dev/null || true
RESTORE_TARGET="$(cd -- "$RESTORE_TARGET" && pwd -P)"
RAW_RESTORE_TARGET="$RESTORE_TARGET/.restic-restore-raw"

log "Hermes backup safe restore"
log "snapshot=$SNAPSHOT"
if [[ "$SNAPSHOT" == "latest" ]]; then
  log "host_filter=$RESTORE_HOST"
fi
log "restore_target=$RESTORE_TARGET"
log "manifest_dir=$MANIFEST_DIR"
log "mode=non-live-inspection-only promote=false"

mkdir -p -- "$RAW_RESTORE_TARGET"
RESTIC_RESTORE_ARGS=(restore "$SNAPSHOT")
if [[ "$SNAPSHOT" == "latest" ]]; then
  RESTIC_RESTORE_ARGS+=(--tag hermes-vm-backup --host "$RESTORE_HOST")
fi
RESTIC_RESTORE_ARGS+=(--target "$RAW_RESTORE_TARGET")
restore_output="$(mktemp -t hermes-backup-restic-restore.XXXXXX)"
if ! run_restic "${RESTIC_RESTORE_ARGS[@]}" >"$restore_output" 2>&1; then
  rm -f -- "$restore_output"
  rm -rf -- "$RAW_RESTORE_TARGET"
  fail "restic restore failed"
fi
rm -f -- "$restore_output"
materialize_restored_layout "$RAW_RESTORE_TARGET" "$RESTORE_TARGET" "$INCLUDE_MANIFEST"
write_restore_marker "$RESTORE_TARGET" "$SNAPSHOT"
log "restore=ok"

present=0
missing=0
while IFS= read -r live_path; do
  restored_path="$RESTORE_TARGET/$(relative_without_leading_slash "$live_path")"
  if [[ -e "$restored_path" ]]; then
    log "verify path=$live_path status=present restored_path=$restored_path"
    present=$((present + 1))
  else
    log "verify path=$live_path status=missing restored_path=$restored_path"
    missing=$((missing + 1))
  fi
done < <(read_manifest_lines "$INCLUDE_MANIFEST")

if [[ "$missing" -eq 0 ]]; then
  log "verification=ok present=$present missing=$missing"
else
  log "verification=warnings present=$present missing=$missing"
fi
log "No live Hermes/shared/systemd paths were promoted or overwritten."
log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
