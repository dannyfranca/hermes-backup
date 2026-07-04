#!/usr/bin/env bash
# Offline dependency and runtime preflight for Danny's Hermes VM backup repo.
# This script must stay side-effect-safe: no package installs, no network calls,
# no secret prompts, and no environment dumps.

set -u

STATUS=0

usage() {
  printf 'Usage: scripts/preflight.sh --check\n'
  printf '\n'
  printf 'Runs offline checks for local runtime dependencies and writable config paths.\n'
}

ok() {
  printf 'OK: %s\n' "$1"
}

missing() {
  printf 'MISSING: %s\n' "$1"
  STATUS=1
}

fail() {
  printf 'FAIL: %s\n' "$1"
  STATUS=1
}

check_bash_runtime() {
  if [[ -z "${BASH_VERSION:-}" ]]; then
    fail 'script is not running under Bash'
    return
  fi

  if (( BASH_VERSINFO[0] < 4 )); then
    fail 'Bash 4 or newer is required'
    return
  fi

  ok 'Bash runtime is available'
}

check_required_commands() {
  local command_name
  local commands=(restic sqlite3 rsync curl systemctl)

  for command_name in "${commands[@]}"; do
    if command -v "$command_name" >/dev/null 2>&1; then
      ok "command available: $command_name"
    else
      missing "required command not found: $command_name"
    fi
  done
}

check_systemd_user() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  if systemctl --user list-unit-files --no-pager >/dev/null 2>&1; then
    ok 'systemctl --user available'
  else
    fail 'systemctl --user is not available'
  fi
}

check_owner_user() {
  local expected_user="${HERMES_BACKUP_EXPECTED_USER:-agent}"
  local expected_euid="${HERMES_BACKUP_EXPECTED_EUID:-}"
  local id_bin="/usr/bin/id"
  local current_user
  local current_euid

  if [[ ! -x "$id_bin" ]]; then
    fail 'cannot verify current user because /usr/bin/id is unavailable'
    return
  fi

  current_user="$($id_bin -un 2>/dev/null || true)"
  current_euid="$($id_bin -u 2>/dev/null || true)"

  if [[ -z "$current_user" || -z "$current_euid" ]]; then
    fail 'cannot verify current user'
    return
  fi

  if [[ "$current_user" != "$expected_user" ]]; then
    fail 'current user does not match expected Hermes VM owner'
    return
  fi

  if [[ -n "$expected_euid" && "$current_euid" != "$expected_euid" ]]; then
    fail 'current user id does not match expected Hermes VM owner'
    return
  fi

  ok 'current user matches expected Hermes VM owner'
}

check_home_contract() {
  local home_value="${HOME:-}"
  local expected_home="${HERMES_BACKUP_EXPECTED_HOME:-/home/agent}"

  if [[ -z "$home_value" ]]; then
    fail 'HOME is not set'
    return
  fi

  if [[ "$home_value" != /* ]]; then
    fail 'HOME must be an absolute path'
    return
  fi

  if [[ "$home_value" != "$expected_home" ]]; then
    fail 'HOME does not match the expected Hermes VM user path; set HERMES_BACKUP_EXPECTED_HOME only for fixture-driven tests'
    return
  fi

  ok 'HOME matches expected Hermes VM user path'
}

check_config_parent() {
  local home_value="${HOME:-}"
  local config_home="${XDG_CONFIG_HOME:-}"
  local parent

  if [[ -z "$home_value" ]]; then
    fail 'cannot resolve user config directory because HOME is not set'
    return
  fi

  if [[ -z "$config_home" ]]; then
    config_home="$home_value/.config"
  fi

  if [[ "$config_home" != /* ]]; then
    fail 'user config directory must be an absolute path'
    return
  fi

  if [[ -e "$config_home" && ! -d "$config_home" ]]; then
    fail 'user config directory path exists but is not a directory'
    return
  fi

  if [[ -d "$config_home" ]]; then
    parent="$config_home"
  else
    parent="${config_home%/*}"
  fi

  if [[ -z "$parent" ]]; then
    fail 'user config directory parent is not writable'
    return
  fi

  if [[ -d "$parent" && -w "$parent" && -x "$parent" ]]; then
    ok 'user config directory parent is writable'
  else
    fail 'user config directory parent is not writable'
  fi
}

run_check() {
  printf 'Hermes backup preflight (offline)\n'
  printf 'No secrets are read, printed, or prompted. No network or package-manager actions are run.\n'

  check_bash_runtime
  check_required_commands
  check_systemd_user
  check_owner_user
  check_home_contract
  check_config_parent

  if (( STATUS == 0 )); then
    printf 'Preflight passed.\n'
  else
    printf 'Preflight failed. Install missing tools locally and fix failed runtime checks, then rerun scripts/preflight.sh --check.\n'
  fi

  return "$STATUS"
}

main() {
  if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return 0
  fi

  if [[ "${1:-}" != "--check" || $# -ne 1 ]]; then
    usage
    return 2
  fi

  run_check
}

main "$@"
