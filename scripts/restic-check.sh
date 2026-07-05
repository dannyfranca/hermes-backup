#!/usr/bin/env bash
# Restic repository health check flow for hermes-backup.
# Loads local secret env from chmod-600 config, runs `restic check`, preserves
# restic failure status codes, and redacts configured secret/repository values.
{ set +x; } 2>/dev/null || true
set -euo pipefail
shopt -u extglob 2>/dev/null || true

usage() {
  cat <<'USAGE'
Usage: scripts/restic-check.sh [--config-env PATH]

Runs the repository check flow:
  1. Validate and load the local hermes-backup env file.
  2. Validate the local restic password file.
  3. Run `restic check` against the configured repository.

Exit semantics:
  0    restic check succeeded
  64   local config/env/password file is missing or unsafe
  127  restic is not installed or not on PATH
  N    restic check failed; the restic exit code is propagated

The command prints compact redacted status. It never prints B2 keys, restic
passwords, Telegram credentials, repository URLs, file contents, or backup
archives.
USAGE
}

log() { printf '%s\n' "$*"; }
fail_config() { printf 'error: %s\n' "$*" >&2; exit 64; }
fail_dependency() { printf 'error: %s\n' "$*" >&2; exit 127; }

CONFIG_ENV="${HERMES_BACKUP_ENV:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-env)
      [[ $# -ge 2 ]] || fail_config "--config-env requires a path"
      CONFIG_ENV=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail_config "unknown argument: $1" ;;
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
  [[ -n "$path" ]] || fail_config "$label path is required"
  case "$path" in /*) ;; *) fail_config "$label path must be absolute" ;; esac
  [[ ! -L "$path" ]] || fail_config "$label must not be a symlink: $path"
  [[ -f "$path" ]] || fail_config "$label not found or not a regular file: $path"
  mode_is_0600_file "$path" || fail_config "$label permissions are unsafe; run chmod 600 '$path'"
}

validate_restic_password_file() {
  local path=$1 redacted='[redacted:RESTIC_PASSWORD_FILE]'
  [[ -n "$path" ]] || fail_config "local restic password file path is required"
  case "$path" in /*) ;; *) fail_config "local restic password file path must be absolute" ;; esac
  [[ ! -L "$path" ]] || fail_config "local restic password file must not be a symlink: $redacted"
  [[ -f "$path" ]] || fail_config "local restic password file not found or not a regular file: $redacted"
  mode_is_0600_file "$path" || fail_config "local restic password file permissions are unsafe; run chmod 600 $redacted"
}

require_env() {
  local name=$1 value
  value=${!name:-}
  [[ -n "$value" ]] || fail_config "$name is required in local config env"
}

run_restic() {
  local -a restic_env=(
    "PATH=$PATH"
    "B2_ACCOUNT_ID=$B2_ACCOUNT_ID"
    "B2_ACCOUNT_KEY=$B2_ACCOUNT_KEY"
    "RESTIC_REPOSITORY=$RESTIC_REPOSITORY"
    "RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE"
  )
  if [[ -n "${HOME:-}" ]]; then
    restic_env+=("HOME=$HOME")
  fi
  # Test-only controls for fake-restic fixtures; absent in normal operation.
  if [[ -n "${FAKE_RESTIC_LOG:-}" ]]; then
    restic_env+=("FAKE_RESTIC_LOG=$FAKE_RESTIC_LOG")
  fi
  if [[ -n "${FAKE_RESTIC_CHECK_FAIL:-}" ]]; then
    restic_env+=("FAKE_RESTIC_CHECK_FAIL=$FAKE_RESTIC_CHECK_FAIL")
  fi
  if [[ -n "${FAKE_RESTIC_STDERR_SECRET:-}" ]]; then
    restic_env+=("FAKE_RESTIC_STDERR_SECRET=$FAKE_RESTIC_STDERR_SECRET")
  fi
  env -i "${restic_env[@]}" restic "$@"
}

escape_glob_pattern() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\*/\\*}
  value=${value//\?/\\?}
  value=${value//\[/\\[}
  value=${value//\]/\\]}
  printf '%s' "$value"
}

redact_line() {
  local line=$1 pattern tmp_name tmp_value
  local -a names=() values=()

  if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
    names+=(RESTIC_PASSWORD_FILE); values+=("$RESTIC_PASSWORD_FILE")
  fi
  if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
    names+=(RESTIC_REPOSITORY); values+=("$RESTIC_REPOSITORY")
  fi
  if [[ -n "${B2_ACCOUNT_KEY:-}" ]]; then
    names+=(B2_ACCOUNT_KEY); values+=("$B2_ACCOUNT_KEY")
  fi
  if [[ -n "${B2_ACCOUNT_ID:-}" ]]; then
    names+=(B2_ACCOUNT_ID); values+=("$B2_ACCOUNT_ID")
  fi
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    names+=(TELEGRAM_BOT_TOKEN); values+=("$TELEGRAM_BOT_TOKEN")
  fi
  if [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    names+=(TELEGRAM_CHAT_ID); values+=("$TELEGRAM_CHAT_ID")
  fi

  local i j
  for ((i = 0; i < ${#values[@]}; i++)); do
    for ((j = i + 1; j < ${#values[@]}; j++)); do
      if (( ${#values[j]} > ${#values[i]} )); then
        tmp_value=${values[i]}; values[i]=${values[j]}; values[j]=$tmp_value
        tmp_name=${names[i]}; names[i]=${names[j]}; names[j]=$tmp_name
      fi
    done
  done

  for ((i = 0; i < ${#values[@]}; i++)); do
    pattern="$(escape_glob_pattern "${values[i]}")"
    line=${line//$pattern/[redacted:${names[i]}]}
  done
  printf '%s\n' "$line"
}

redact_file() {
  local output_file=$1 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    redact_line "$line"
  done <"$output_file"
}

if [[ -z "$CONFIG_ENV" ]]; then
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    CONFIG_ENV="$XDG_CONFIG_HOME/hermes-backup/hermes-backup.env"
  else
    [[ -n "${HOME:-}" ]] || fail_config "HOME must be set"
    CONFIG_ENV="$HOME/.config/hermes-backup/hermes-backup.env"
  fi
fi
case "$CONFIG_ENV" in /*) ;; *) fail_config "--config-env must be an absolute path" ;; esac
validate_secret_file "local env file" "$CONFIG_ENV"

loaded_env="$(/usr/bin/env -i CONFIG_ENV_PATH="$CONFIG_ENV" /usr/bin/bash <<'BASH_LOAD_ENV'
{ set +x; } 2>/dev/null || true
exec {xtrace_fd}>/dev/null
BASH_XTRACEFD=$xtrace_fd
source "$CONFIG_ENV_PATH" >/dev/null 2>&1 || exit 10
{ set +x; } 2>/dev/null || true
unset BASH_XTRACEFD
exec {xtrace_fd}>&-
for name in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
  printf '%s=%q\n' "$name" "${!name-}"
done
BASH_LOAD_ENV
)" || fail_config "local env file could not be loaded: $CONFIG_ENV"
eval "$loaded_env"
unset loaded_env

for required in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE; do
  require_env "$required"
done
validate_restic_password_file "$RESTIC_PASSWORD_FILE"
unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND
export -n B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE 2>/dev/null || true

command -v restic >/dev/null 2>&1 || fail_dependency "restic is required for check"

log "Hermes backup restic check"
log "config_env=$CONFIG_ENV"
log "check_command=restic check"

check_output="$(mktemp -t hermes-backup-restic-check.XXXXXX)"
set +e
run_restic check >"$check_output" 2>&1
check_rc=$?
set -e

if [[ "$check_rc" -ne 0 ]]; then
  printf 'check=failed exit=%s repository=configured\n' "$check_rc" >&2
  printf 'restic_output=begin\n' >&2
  redact_file "$check_output" >&2
  printf 'restic_output=end\n' >&2
  rm -f -- "$check_output"
  exit "$check_rc"
fi

rm -f -- "$check_output"
log "check=ok repository=configured"
log "No B2 keys, restic passwords, Telegram tokens, repository URLs, file contents, or backup archives were printed."
