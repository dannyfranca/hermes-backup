#!/usr/bin/env bash
# Shared non-blocking runtime lock for repository-touching hermes-backup jobs.

hb_state_dir_default() {
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/hermes-backup\n' "$XDG_STATE_HOME"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s/.local/state/hermes-backup\n' "$HOME"
  elif [[ -n "${HERMES_BACKUP_LOG_DIR:-}" ]]; then
    /usr/bin/dirname -- "$HERMES_BACKUP_LOG_DIR"
  elif [[ -n "${HERMES_BACKUP_DRILL_DIR:-}" ]]; then
    /usr/bin/dirname -- "$HERMES_BACKUP_DRILL_DIR"
  else
    return 1
  fi
}

hb_runtime_lock_file_default() {
  if [[ -n "${HERMES_BACKUP_LOCK_FILE:-}" ]]; then
    printf '%s\n' "$HERMES_BACKUP_LOCK_FILE"
    return 0
  fi
  local state_dir
  state_dir="$(hb_state_dir_default)" || return 1
  printf '%s/run.lock\n' "$state_dir"
}

hb_acquire_runtime_lock() {
  local command_name=${1:-job} lock_file lock_dir old_umask flock_rc
  lock_file="$(hb_runtime_lock_file_default)" || return 2
  case "$lock_file" in
    "") return 2 ;;
    /*) ;;
    *) printf 'error: HERMES_BACKUP_LOCK_FILE must be an absolute path\n' >&2; return 2 ;;
  esac
  if [[ -L "$lock_file" || -d "$lock_file" ]]; then
    printf 'error: runtime lock path must be a regular file, not a symlink or directory: %s\n' "$lock_file" >&2
    return 2
  fi
  if [[ -e "$lock_file" && ! -f "$lock_file" ]]; then
    printf 'error: runtime lock path must be a regular file: %s\n' "$lock_file" >&2
    return 2
  fi

  lock_dir="$(/usr/bin/dirname -- "$lock_file")"
  old_umask=$(umask)
  umask 077
  if ! /usr/bin/mkdir -p -- "$lock_dir"; then
    umask "$old_umask"
    return 2
  fi
  if [[ ! -e "$lock_file" ]]; then
    if ! (set -C; : >"$lock_file") 2>/dev/null; then
      if [[ -L "$lock_file" || ! -f "$lock_file" ]]; then
        umask "$old_umask"
        return 2
      fi
    fi
  fi
  if [[ -L "$lock_file" || ! -f "$lock_file" ]]; then
    umask "$old_umask"
    return 2
  fi
  /usr/bin/chmod 600 -- "$lock_file" 2>/dev/null || true
  umask "$old_umask"

  if ! exec {HERMES_BACKUP_RUNTIME_LOCK_FD}>>"$lock_file"; then
    return 2
  fi
  /usr/bin/flock -n -E 75 "$HERMES_BACKUP_RUNTIME_LOCK_FD"
  flock_rc=$?
  if [[ "$flock_rc" -ne 0 ]]; then
    exec {HERMES_BACKUP_RUNTIME_LOCK_FD}>&-
    HERMES_BACKUP_RUNTIME_LOCK_FILE="$lock_file"
    export HERMES_BACKUP_RUNTIME_LOCK_FILE
    if [[ "$flock_rc" -eq 75 ]]; then
      return 1
    fi
    return 2
  fi

  HERMES_BACKUP_RUNTIME_LOCK_FILE="$lock_file"
  export HERMES_BACKUP_RUNTIME_LOCK_FILE HERMES_BACKUP_RUNTIME_LOCK_FD
  hb_append_log_line "runtime_lock=acquired command=$command_name lock_file=$lock_file" 2>/dev/null || true
  return 0
}

hb_runtime_lock_busy_summary() {
  local command_name=${1:-job} lock_file
  lock_file="${HERMES_BACKUP_RUNTIME_LOCK_FILE:-$(hb_runtime_lock_file_default 2>/dev/null || printf 'unavailable')}"
  printf 'runtime lock busy; another hermes-backup job is running command=%s lock_file=%s' "$command_name" "$lock_file"
}
