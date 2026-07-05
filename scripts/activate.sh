#!/usr/bin/env bash
# Explicit first-run activation/check path for hermes-backup after local secrets exist.
# Safe by default: no restic init, Telegram send, backup/check, or timer enablement
# runs unless the operator passes the matching explicit flag.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/activate.sh [options]

Explicit first-run setup verification after ./install.sh has created local config.
Default mode checks packages/config only, then prints the operator activation sequence.

Options:
  --config-env PATH       Local chmod-600 env file (default: $HERMES_BACKUP_ENV or ~/.config/hermes-backup/hermes-backup.env)
  --init-restic           If the configured repository is not initialized, run `restic init` before backup/check.
  --telegram-test         Send one raw Telegram Bot API setup-test message using local credentials.
  --first-backup          Run scripts/backup.sh once after repository verification/init.
  --first-check           Run scripts/restic-check.sh once after the first backup step.
  --enable-timers         Enable backup/check/restore-drill user timers only after --first-backup and --first-check succeed in this run.
  --backup-root PATH      Test-only/live-fixture root passed to scripts/backup.sh --root.
  --manifest-dir PATH     Test-only manifest directory passed to scripts/backup.sh --manifest-dir.
  --staging-parent PATH   Test-only staging parent passed to scripts/backup.sh --staging-parent.
  --dry-run               Validate local preflight/config and print requested steps without network/restic/curl/systemctl side effects.
  -h, --help              Show this help.

This command never prints B2 keys, restic passwords, Telegram credentials,
repository URLs, file contents, or backup archives.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

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

config_env_default() {
  if [[ -n "${HERMES_BACKUP_ENV:-}" ]]; then
    printf '%s\n' "$HERMES_BACKUP_ENV"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf '%s/hermes-backup/hermes-backup.env\n' "$XDG_CONFIG_HOME"
  else
    [[ -n "${HOME:-}" ]] || fail "HOME must be set"
    printf '%s/.config/hermes-backup/hermes-backup.env\n' "$HOME"
  fi
}

redact_output_file() {
  local path=$1
  hb_redact_file "$path"
}

run_restic() {
  local -a restic_env=(
    "PATH=$PATH"
    "B2_ACCOUNT_ID=$B2_ACCOUNT_ID"
    "B2_ACCOUNT_KEY=$B2_ACCOUNT_KEY"
    "RESTIC_REPOSITORY=$RESTIC_REPOSITORY"
    "RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE"
  )
  [[ -n "${HOME:-}" ]] && restic_env+=("HOME=$HOME")
  # Test-only controls for fake fixtures; absent in normal operation.
  [[ -n "${FAKE_RESTIC_LOG:-}" ]] && restic_env+=("FAKE_RESTIC_LOG=$FAKE_RESTIC_LOG")
  [[ -n "${FAKE_RESTIC_REPO_STATE:-}" ]] && restic_env+=("FAKE_RESTIC_REPO_STATE=$FAKE_RESTIC_REPO_STATE")
  [[ -n "${FAKE_RESTIC_WRONG_PASSWORD:-}" ]] && restic_env+=("FAKE_RESTIC_WRONG_PASSWORD=$FAKE_RESTIC_WRONG_PASSWORD")
  [[ -n "${FAKE_RESTIC_SNAPSHOTS_FAIL:-}" ]] && restic_env+=("FAKE_RESTIC_SNAPSHOTS_FAIL=$FAKE_RESTIC_SNAPSHOTS_FAIL")
  [[ -n "${FAKE_RESTIC_INIT_FAIL:-}" ]] && restic_env+=("FAKE_RESTIC_INIT_FAIL=$FAKE_RESTIC_INIT_FAIL")
  [[ -n "${FAKE_RESTIC_BACKUP_FAIL:-}" ]] && restic_env+=("FAKE_RESTIC_BACKUP_FAIL=$FAKE_RESTIC_BACKUP_FAIL")
  [[ -n "${FAKE_RESTIC_FORGET_FAIL:-}" ]] && restic_env+=("FAKE_RESTIC_FORGET_FAIL=$FAKE_RESTIC_FORGET_FAIL")
  [[ -n "${FAKE_RESTIC_CHECK_FAIL:-}" ]] && restic_env+=("FAKE_RESTIC_CHECK_FAIL=$FAKE_RESTIC_CHECK_FAIL")
  env -i "${restic_env[@]}" restic "$@"
}

looks_uninitialized() {
  local output_file=$1
  grep -Eqi 'not initialized|repository.*(does not exist|not found)|config file.*not.*(exist|found)|Is there a repository' "$output_file"
}

verify_or_init_repository() {
  local output_file init_output
  output_file="$(mktemp -t hermes-backup-activate-restic-snapshots.XXXXXX)"
  set +e
  run_restic snapshots --json >"$output_file" 2>&1
  snapshots_rc=$?
  set -e
  if [[ "$snapshots_rc" -eq 0 ]]; then
    rm -f -- "$output_file"
    log "restic_repository=verified"
    return 0
  fi

  if [[ "$INIT_RESTIC" != "1" ]]; then
    printf 'restic_repository=unverified exit=%s\n' "$snapshots_rc" >&2
    redact_output_file "$output_file" | sed -n '1,8p' >&2
    rm -f -- "$output_file"
    fail "restic repository is not reachable/initialized; rerun with --init-restic only if this is the expected first setup"
  fi

  if ! looks_uninitialized "$output_file"; then
    printf 'restic_repository=unverified exit=%s\n' "$snapshots_rc" >&2
    redact_output_file "$output_file" | sed -n '1,8p' >&2
    rm -f -- "$output_file"
    fail "restic repository check failed for a reason other than missing initialization; refusing restic init"
  fi
  rm -f -- "$output_file"

  log "restic_repository=missing action=init"
  init_output="$(mktemp -t hermes-backup-activate-restic-init.XXXXXX)"
  set +e
  run_restic init >"$init_output" 2>&1
  init_rc=$?
  set -e
  if [[ "$init_rc" -ne 0 ]]; then
    printf 'restic_init=failed exit=%s\n' "$init_rc" >&2
    redact_output_file "$init_output" | sed -n '1,8p' >&2
    rm -f -- "$init_output"
    fail "restic init failed"
  fi
  rm -f -- "$init_output"
  log "restic_init=ok"

  output_file="$(mktemp -t hermes-backup-activate-restic-snapshots.XXXXXX)"
  set +e
  run_restic snapshots --json >"$output_file" 2>&1
  snapshots_rc=$?
  set -e
  if [[ "$snapshots_rc" -ne 0 ]]; then
    printf 'restic_repository=unverified-after-init exit=%s\n' "$snapshots_rc" >&2
    redact_output_file "$output_file" | sed -n '1,8p' >&2
    rm -f -- "$output_file"
    fail "restic repository could not be verified after init"
  fi
  rm -f -- "$output_file"
  log "restic_repository=verified-after-init"
}

send_telegram_test() {
  local message
  hb_setup_logging || fail "local log directory could not be prepared"
  message="Hermes backup setup test
command: activate
time: $(hb_timestamp_utc)
host: $(hostname 2>/dev/null || printf 'unknown')
summary: raw Telegram Bot API setup-test from local hermes-backup credentials"
  if hb_send_raw_telegram_text "activate" "$message" "telegram_test"; then
    log "telegram_test=sent transport=raw-telegram-api"
  else
    fail "raw Telegram test failed; check local redacted log for telegram_test=failed"
  fi
}

run_first_backup() {
  local -a args=(--config-env "$CONFIG_ENV")
  [[ -n "$BACKUP_ROOT" ]] && args+=(--root "$BACKUP_ROOT")
  [[ -n "$MANIFEST_DIR" ]] && args+=(--manifest-dir "$MANIFEST_DIR")
  [[ -n "$STAGING_PARENT" ]] && args+=(--staging-parent "$STAGING_PARENT")
  log "first_backup=begin"
  "$SCRIPT_DIR/backup.sh" "${args[@]}"
  log "first_backup=ok"
}

run_first_check() {
  log "first_check=begin"
  "$SCRIPT_DIR/restic-check.sh" --config-env "$CONFIG_ENV"
  log "first_check=ok"
}

enable_timers_after_verification() {
  local config_dir
  config_dir="$(cd -- "$(dirname -- "$CONFIG_ENV")" && pwd -P)"
  log "timer_enablement=begin mode=enable-without-now"
  "$REPO_ROOT/install.sh" --config-dir "$config_dir" --enable-timers
  log "timer_enablement=ok enabled_without_now=true"
}

SCRIPT_SOURCE=${BASH_SOURCE[0]}
case "$SCRIPT_SOURCE" in */*) SCRIPT_SOURCE=${SCRIPT_SOURCE%/*} ;; *) SCRIPT_SOURCE=. ;; esac
SCRIPT_DIR="$(cd -- "$SCRIPT_SOURCE" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../lib/hermes-backup/log-alert.sh
source "$REPO_ROOT/lib/hermes-backup/log-alert.sh"

CONFIG_ENV="$(config_env_default)"
INIT_RESTIC=0
TELEGRAM_TEST=0
FIRST_BACKUP=0
FIRST_CHECK=0
ENABLE_TIMERS=0
DRY_RUN=0
BACKUP_ROOT=""
MANIFEST_DIR=""
STAGING_PARENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-env) [[ $# -ge 2 ]] || fail "--config-env requires a path"; CONFIG_ENV=$2; shift 2 ;;
    --init-restic) INIT_RESTIC=1; shift ;;
    --telegram-test) TELEGRAM_TEST=1; shift ;;
    --first-backup) FIRST_BACKUP=1; shift ;;
    --first-check) FIRST_CHECK=1; shift ;;
    --enable-timers) ENABLE_TIMERS=1; shift ;;
    --backup-root) [[ $# -ge 2 ]] || fail "--backup-root requires a path"; BACKUP_ROOT=$2; shift 2 ;;
    --manifest-dir) [[ $# -ge 2 ]] || fail "--manifest-dir requires a path"; MANIFEST_DIR=$2; shift 2 ;;
    --staging-parent) [[ $# -ge 2 ]] || fail "--staging-parent requires a path"; STAGING_PARENT=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

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
for name in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID HERMES_BACKUP_LOG_DIR HERMES_BACKUP_STAGING_DIR; do
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
if ! RESTIC_PASSWORD_VALUE="$(/usr/bin/cat -- "$RESTIC_PASSWORD_FILE" 2>/dev/null)"; then
  fail "local restic password file could not be read"
fi
if [[ "$TELEGRAM_TEST" == "1" ]]; then
  require_env TELEGRAM_BOT_TOKEN
  require_env TELEGRAM_CHAT_ID
fi
if [[ "$ENABLE_TIMERS" == "1" && ( "$FIRST_BACKUP" != "1" || "$FIRST_CHECK" != "1" ) ]]; then
  fail "--enable-timers requires --first-backup and --first-check to pass in the same activation run"
fi
if [[ "$ENABLE_TIMERS" == "1" && "$(basename -- "$CONFIG_ENV")" != "hermes-backup.env" ]]; then
  fail "--enable-timers requires --config-env to point at a hermes-backup.env file so scheduled timers use the same verified config"
fi
for path_spec in "backup root|$BACKUP_ROOT" "manifest directory|$MANIFEST_DIR" "staging parent|$STAGING_PARENT"; do
  value=${path_spec#*|}
  [[ -z "$value" ]] && continue
  case "$value" in /*) ;; *) fail "${path_spec%%|*} must be an absolute path" ;; esac
done

log "Hermes backup first-run activation/check"
log "config_env=$CONFIG_ENV"
log "Step 1/6: offline package/runtime preflight."
"$SCRIPT_DIR/preflight.sh" --check
log "Step 2/6: local secret config and restic password-file checks passed."
RESTIC_REQUIRED=0
if [[ "$INIT_RESTIC" == "1" || "$FIRST_BACKUP" == "1" || "$FIRST_CHECK" == "1" || "$ENABLE_TIMERS" == "1" ]]; then
  RESTIC_REQUIRED=1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "dry_run=1 no restic init, Telegram send, backup/check, or timer enablement was run."
  log "requested_init_restic=$INIT_RESTIC requested_telegram_test=$TELEGRAM_TEST requested_first_backup=$FIRST_BACKUP requested_first_check=$FIRST_CHECK requested_enable_timers=$ENABLE_TIMERS"
  exit 0
fi

log "Step 3/6: verifying configured restic repository."
if [[ "$RESTIC_REQUIRED" == "1" ]]; then
  verify_or_init_repository
else
  log "restic_repository=skipped reason=no-restic-dependent-flag"
fi

log "Step 4/6: optional raw Telegram setup test."
if [[ "$TELEGRAM_TEST" == "1" ]]; then
  send_telegram_test
else
  log "telegram_test=skipped reason=flag-not-set"
fi

log "Step 5/6: optional first backup and repository check."
if [[ "$FIRST_BACKUP" == "1" ]]; then
  run_first_backup
else
  log "first_backup=skipped reason=flag-not-set"
fi
if [[ "$FIRST_CHECK" == "1" ]]; then
  run_first_check
else
  log "first_check=skipped reason=flag-not-set"
fi

log "Step 6/6: timer enablement gate."
if [[ "$ENABLE_TIMERS" == "1" ]]; then
  enable_timers_after_verification
else
  log "timer_enablement=skipped reason=flag-not-set"
fi

log "Activation/check complete. No secret values were printed."
log "Ready-to-run full first setup after ./install.sh, from a local terminal:"
log "  scripts/activate.sh --init-restic --telegram-test --first-backup --first-check --enable-timers"
log "Timer enablement uses systemctl --user enable without --now; no timer units are started by this command."
