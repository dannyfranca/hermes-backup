#!/usr/bin/env bash
# Safe foundation bootstrap skeleton only: no restic init, network calls, or timer enablement.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--config-dir PATH] [--non-interactive]
Runs preflight, local path setup, local-only config prompts, and inert template copies.
No backup/check/restore, restic init, network validation, systemd enable/start, or Hermes cron scheduling is run.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

config_dir_default() {
  [[ -n "${XDG_CONFIG_HOME:-}" ]] && { printf '%s/hermes-backup\n' "$XDG_CONFIG_HOME"; return; }
  [[ -n "${HOME:-}" ]] && { printf '%s/.config/hermes-backup\n' "$HOME"; return; }
  fail "HOME must be set"
}

state_dir_default() {
  [[ -n "${XDG_STATE_HOME:-}" ]] && { printf '%s/hermes-backup\n' "$XDG_STATE_HOME"; return; }
  [[ -n "${HOME:-}" ]] && { printf '%s/.local/state/hermes-backup\n' "$HOME"; return; }
  fail "HOME must be set"
}

absolute_path_required() {
  local label=$1 value=$2
  case "$value" in "") fail "$label cannot be empty" ;; /*) ;; *) fail "$label must be an absolute path" ;; esac
}

validate_creatable_dir() {
  local label=$1 path=$2 ancestor=$2 parent mode
  absolute_path_required "$label" "$path"
  [[ -L "$path" ]] && fail "$label must not be a symlink: $path"
  [[ -e "$path" && ! -d "$path" ]] && fail "$label exists but is not a directory: $path"
  while [[ ! -e "$ancestor" ]]; do
    parent="$(dirname -- "$ancestor")"
    [[ "$parent" != "$ancestor" ]] || fail "could not resolve parent for $label: $path"
    ancestor=$parent
  done
  [[ -d "$ancestor" ]] || fail "$label parent is not a directory: $ancestor"
  [[ -w "$ancestor" && -x "$ancestor" ]] || fail "$label parent is not writable: $ancestor"
  if [[ -d "$path" ]]; then
    mode="$(stat -c '%a' "$path")" || fail "could not inspect $label permissions: $path"
    [[ "$mode" == "700" ]] || fail "$label already exists with mode $mode; set it to 700 or move it aside before bootstrap: $path"
  fi
}

validate_new_file() {
  local label=$1 path=$2
  absolute_path_required "$label" "$path"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "$label already exists; move it aside before rerunning bootstrap: $path"
}

ensure_private_dir() {
  local label=$1 path=$2
  validate_creatable_dir "$label" "$path"
  [[ -d "$path" ]] && return
  mkdir -p "$path"
  chmod 700 "$path"
}

reject_repo_contained_path() {
  local label=$1 path=$2 ancestor=$2 parent ancestor_real
  case "$path" in "$SCRIPT_DIR"|"$SCRIPT_DIR"/*) fail "refusing $label inside the repository: $path" ;; esac
  while [[ ! -e "$ancestor" ]]; do
    parent="$(dirname -- "$ancestor")"
    [[ "$parent" != "$ancestor" ]] || fail "could not resolve parent for $label: $path"
    ancestor=$parent
  done
  ancestor_real="$(cd -- "$ancestor" && pwd -P)" || fail "$label parent is not a directory: $ancestor"
  case "$ancestor_real" in "$SCRIPT_DIR"|"$SCRIPT_DIR"/*) fail "refusing $label inside the repository: $path" ;; esac
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_DIR="$(config_dir_default)"
NON_INTERACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir) [[ $# -ge 2 ]] || fail "--config-dir requires a path"; CONFIG_DIR=$2; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ -n "${HOME:-}" ]] || fail "HOME must be set"
absolute_path_required "config directory" "$CONFIG_DIR"
reject_repo_contained_path "config directory" "$CONFIG_DIR"

STATE_DIR="$(state_dir_default)"
LOG_DIR="$STATE_DIR/logs"
STAGING_DIR="$STATE_DIR/staging"
RESTORE_DIR="$HOME/restore/hermes-vm-backup"
TEMPLATE_DIR="$CONFIG_DIR/systemd-templates"

log "Hermes backup bootstrap skeleton"
log "Step 1/4: running offline preflight before any secret prompts."
"$SCRIPT_DIR/scripts/preflight.sh" --check

for spec in \
  "config directory|$CONFIG_DIR" \
  "local state directory|$STATE_DIR" \
  "local log directory|$LOG_DIR" \
  "local staging directory|$STAGING_DIR" \
  "safe restore directory|$RESTORE_DIR" \
  "inert systemd template directory|$TEMPLATE_DIR"; do
  validate_creatable_dir "${spec%%|*}" "${spec#*|}"
done
validate_new_file "local env file" "$CONFIG_DIR/hermes-backup.env"
validate_new_file "local restic password file" "$CONFIG_DIR/restic-password"

log "Step 2/4: creating local directories and copying inert systemd templates."
umask 077
for spec in \
  "config directory|$CONFIG_DIR" \
  "local state directory|$STATE_DIR" \
  "local log directory|$LOG_DIR" \
  "local staging directory|$STAGING_DIR" \
  "safe restore directory|$RESTORE_DIR" \
  "inert systemd template directory|$TEMPLATE_DIR"; do
  ensure_private_dir "${spec%%|*}" "${spec#*|}"
done
for template in "$SCRIPT_DIR"/systemd/user/*; do
  [[ -f "$template" ]] || continue
  dest="$TEMPLATE_DIR/$(basename -- "$template").template"
  [[ -e "$dest" && ( ! -f "$dest" || -L "$dest" ) ]] && fail "refusing unsafe inert systemd template destination: $dest"
  cp "$template" "$dest"
  chmod 600 "$dest"
done

log "Step 3/4: writing local-only config files. Secret values are never printed."
CONFIGURE_ARGS=(--config-dir "$CONFIG_DIR")
[[ "$NON_INTERACTIVE" == "1" ]] && CONFIGURE_ARGS+=(--non-interactive)
"$SCRIPT_DIR/scripts/configure.sh" "${CONFIGURE_ARGS[@]}"

log "Step 4/4: confirming bootstrap skeleton remains inert."
log "Bootstrap skeleton complete."
log "Created local config dir: $CONFIG_DIR"
log "Created local log dir: $LOG_DIR"
log "Created local staging dir: $STAGING_DIR"
log "Created safe restore dir: $RESTORE_DIR"
log "Copied inert systemd templates to: $TEMPLATE_DIR"
log "Backup execution is NOT implemented or active in this foundation slice."
log "No restic init, B2/Telegram network validation, systemd enable, systemd start, or Hermes cron scheduling was run."
log "Downstream tickets own backup/check/drill commands, raw Telegram alerts, and user systemd timer enablement."
