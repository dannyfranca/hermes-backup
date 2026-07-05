#!/usr/bin/env bash
# Bootstrap/install path for local config plus user systemd backup/check timers.
# Secrets remain in local chmod-600 config files; rendered unit files contain paths only.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--config-dir PATH] [--systemd-user-dir PATH] [--non-interactive] [--enable-timers]
Runs preflight, local path setup, local-only config prompts/reuse, and user systemd unit rendering.
By default it installs/reloads units but does not enable timers. Pass --enable-timers after local verification is ready.
No backup/check/restore, restic init, network validation, Telegram send, restore promote, drill, or Hermes cron scheduling is run.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

config_dir_default() {
  [[ -n "${XDG_CONFIG_HOME:-}" ]] && { printf '%s/hermes-backup\n' "$XDG_CONFIG_HOME"; return; }
  [[ -n "${HOME:-}" ]] && { printf '%s/.config/hermes-backup\n' "$HOME"; return; }
  fail "HOME must be set"
}

systemd_user_dir_default() {
  [[ -n "${XDG_CONFIG_HOME:-}" ]] && { printf '%s/systemd/user\n' "$XDG_CONFIG_HOME"; return; }
  [[ -n "${HOME:-}" ]] && { printf '%s/.config/systemd/user\n' "$HOME"; return; }
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

mode_octal() {
  local path=$1
  stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Lp' -- "$path"
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
    mode="$(mode_octal "$path")" || fail "could not inspect $label permissions: $path"
    [[ "$mode" == "700" ]] || fail "$label already exists with mode $mode; set it to 700 or move it aside before bootstrap: $path"
  fi
}

validate_systemd_user_dir() {
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
    mode="$(mode_octal "$path")" || fail "could not inspect $label permissions: $path"
    (( (8#$mode & 0022) == 0 )) || fail "$label is group/world writable with mode $mode; set it to 755/750/700 or move it aside before bootstrap: $path"
  fi
}

validate_private_file_if_present() {
  local label=$1 path=$2 mode
  absolute_path_required "$label" "$path"
  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
  [[ ! -e "$path" || -f "$path" ]] || fail "$label exists but is not a regular file: $path"
  if [[ -f "$path" ]]; then
    mode="$(mode_octal "$path")" || fail "could not inspect $label permissions: $path"
    [[ "$mode" == "600" ]] || fail "$label already exists with mode $mode; set it to 600 or move it aside before bootstrap: $path"
  fi
}

ensure_private_dir() {
  local label=$1 path=$2
  validate_creatable_dir "$label" "$path"
  [[ -d "$path" ]] && return
  mkdir -p "$path"
  chmod 700 "$path"
}

ensure_systemd_user_dir() {
  local path=$1
  validate_systemd_user_dir "systemd user unit directory" "$path"
  [[ -d "$path" ]] && return
  mkdir -p "$path"
  chmod 700 "$path"
}

quote_arg() {
  printf '%q' "$1"
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

atomic_write_public_file() {
  local target=$1 tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$target"
  chmod 644 "$target"
}

render_unit_template() {
  local template=$1 dest_dir=$2 basename content dest
  basename="$(basename -- "$template")"
  dest="$dest_dir/$basename"
  [[ -e "$dest" && ( ! -f "$dest" || -L "$dest" ) ]] && fail "refusing unsafe systemd unit destination: $dest"
  content="$(<"$template")"
  content="${content//EXAMPLE_LOCAL_CONFIG_DIR/$CONFIG_DIR}"
  content="${content//EXAMPLE_REPO_PATH/$SCRIPT_DIR}"
  if [[ "$content" == *EXAMPLE_* ]]; then
    fail "unrendered placeholder remains in $basename"
  fi
  atomic_write_public_file "$dest" <<<"$content"
}

verify_unit_file() {
  local path=$1 text secret_assignment
  text="$(<"$path")"
  [[ "$text" != *EXAMPLE_* ]] || fail "unit contains unrendered placeholder: $path"
  [[ "$text" != *DUMMY_* && "$text" != *PLACEHOLDER_* ]] || fail "unit contains placeholder secret-looking value: $path"
  for secret_assignment in B2_ACCOUNT_ID= B2_ACCOUNT_KEY= RESTIC_REPOSITORY= RESTIC_PASSWORD= RESTIC_PASSWORD_FILE= TELEGRAM_BOT_TOKEN= TELEGRAM_CHAT_ID=; do
    [[ "$text" != *"$secret_assignment"* ]] || fail "unit embeds secret/config assignment $secret_assignment: $path"
  done
  [[ "$text" != *promote.sh* && "$text" != *restore.sh* ]] || fail "backup/check scheduler must not call restore or promote commands: $path"
}

validate_systemd_embedded_path() {
  local label=$1 path=$2
  case "$path" in
    *[[:space:]]*|*\"*|*"'"*|*'$'*|*'&'*|*\\*|*%*|*';'*|*'#'*)
      fail "$label contains characters unsupported by this systemd unit renderer: $path"
      ;;
  esac
}

verify_scheduler_ready() {
  local unit
  [[ -x "$SCRIPT_DIR/scripts/backup.sh" ]] || fail "backup command is missing or not executable: $SCRIPT_DIR/scripts/backup.sh"
  [[ -x "$SCRIPT_DIR/scripts/restic-check.sh" ]] || fail "check command is missing or not executable: $SCRIPT_DIR/scripts/restic-check.sh"
  validate_private_file_if_present "local env file" "$CONFIG_DIR/hermes-backup.env"
  validate_private_file_if_present "local restic password file" "$CONFIG_DIR/restic-password"
  [[ -f "$CONFIG_DIR/hermes-backup.env" && -f "$CONFIG_DIR/restic-password" ]] || fail "local config files must exist before enabling timers"
  for unit in "${EXPECTED_UNITS[@]}"; do
    [[ -f "$SCRIPT_DIR/systemd/user/$unit" ]] || fail "source systemd template missing: $SCRIPT_DIR/systemd/user/$unit"
    [[ -f "$SYSTEMD_USER_DIR/$unit" ]] || fail "rendered systemd unit missing: $SYSTEMD_USER_DIR/$unit"
    verify_unit_file "$SYSTEMD_USER_DIR/$unit"
  done
}

validate_unit_destinations() {
  local unit dest
  for unit in "${EXPECTED_UNITS[@]}"; do
    [[ -f "$SCRIPT_DIR/systemd/user/$unit" ]] || fail "source systemd template missing: $SCRIPT_DIR/systemd/user/$unit"
    dest="$SYSTEMD_USER_DIR/$unit"
    [[ ! -L "$dest" ]] || fail "systemd unit destination must not be a symlink: $dest"
    [[ ! -e "$dest" || -f "$dest" ]] || fail "systemd unit destination exists but is not a regular file: $dest"
  done
}

validate_config_env_contents() {
  local env_file="$CONFIG_DIR/hermes-backup.env"
  env -i CONFIG_ENV_PATH="$env_file" bash <<'BASH_VALIDATE_ENV' >/dev/null 2>&1 || fail "local env file is missing required backup/check config values; rerun scripts/configure.sh safely before enabling timers"
{ set +x; } 2>/dev/null || true
source "$CONFIG_ENV_PATH" >/dev/null 2>&1 || exit 10
for name in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID HERMES_BACKUP_LOG_DIR HERMES_BACKUP_STAGING_DIR; do
  [[ -n "${!name:-}" ]] || exit 20
done
case "$RESTIC_PASSWORD_FILE" in /*) ;; *) exit 21 ;; esac
[[ ! -L "$RESTIC_PASSWORD_FILE" && -f "$RESTIC_PASSWORD_FILE" ]] || exit 22
mode="$(stat -c '%a' -- "$RESTIC_PASSWORD_FILE" 2>/dev/null || stat -f '%Lp' -- "$RESTIC_PASSWORD_FILE")" || exit 23
[[ "$mode" == "600" ]] || exit 24
BASH_VALIDATE_ENV
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EXPECTED_UNITS=(
  hermes-backup-backup.service
  hermes-backup-backup.timer
  hermes-backup-check.service
  hermes-backup-check.timer
)
CONFIG_DIR="$(config_dir_default)"
SYSTEMD_USER_DIR="$(systemd_user_dir_default)"
NON_INTERACTIVE=0
ENABLE_TIMERS=0
CUSTOM_SYSTEMD_USER_DIR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir) [[ $# -ge 2 ]] || fail "--config-dir requires a path"; CONFIG_DIR=$2; shift 2 ;;
    --systemd-user-dir) [[ $# -ge 2 ]] || fail "--systemd-user-dir requires a path"; SYSTEMD_USER_DIR=$2; CUSTOM_SYSTEMD_USER_DIR=1; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --enable-timers) ENABLE_TIMERS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ -n "${HOME:-}" ]] || fail "HOME must be set"
absolute_path_required "config directory" "$CONFIG_DIR"
absolute_path_required "systemd user unit directory" "$SYSTEMD_USER_DIR"
validate_systemd_embedded_path "repository path" "$SCRIPT_DIR"
validate_systemd_embedded_path "config directory" "$CONFIG_DIR"
if [[ "$ENABLE_TIMERS" == "1" && "$CUSTOM_SYSTEMD_USER_DIR" == "1" ]]; then
  fail "--enable-timers cannot be combined with --systemd-user-dir; render custom dirs for tests only, then enable through the default user manager path"
fi
reject_repo_contained_path "config directory" "$CONFIG_DIR"
reject_repo_contained_path "systemd user unit directory" "$SYSTEMD_USER_DIR"

STATE_DIR="$(state_dir_default)"
LOG_DIR="$STATE_DIR/logs"
STAGING_DIR="$STATE_DIR/staging"
RESTORE_DIR="$HOME/restore/hermes-vm-backup"

log "Hermes backup bootstrap and user systemd installer"
log "Step 1/5: running offline preflight before any secret prompts or timer installation."
"$SCRIPT_DIR/scripts/preflight.sh" --check

for spec in \
  "config directory|$CONFIG_DIR" \
  "local state directory|$STATE_DIR" \
  "local log directory|$LOG_DIR" \
  "local staging directory|$STAGING_DIR" \
  "safe restore directory|$RESTORE_DIR"; do
  validate_creatable_dir "${spec%%|*}" "${spec#*|}"
done
validate_systemd_user_dir "systemd user unit directory" "$SYSTEMD_USER_DIR"
validate_private_file_if_present "local env file" "$CONFIG_DIR/hermes-backup.env"
validate_private_file_if_present "local restic password file" "$CONFIG_DIR/restic-password"

log "Step 2/5: creating local config/state directories and systemd user unit directory."
umask 077
for spec in \
  "config directory|$CONFIG_DIR" \
  "local state directory|$STATE_DIR" \
  "local log directory|$LOG_DIR" \
  "local staging directory|$STAGING_DIR" \
  "safe restore directory|$RESTORE_DIR"; do
  ensure_private_dir "${spec%%|*}" "${spec#*|}"
done
ensure_systemd_user_dir "$SYSTEMD_USER_DIR"
validate_unit_destinations

log "Step 3/5: ensuring local-only config files exist. Secret values are never printed."
if [[ -f "$CONFIG_DIR/hermes-backup.env" && -f "$CONFIG_DIR/restic-password" ]]; then
  log "Reusing existing local config files under: $CONFIG_DIR"
elif [[ ! -e "$CONFIG_DIR/hermes-backup.env" && ! -e "$CONFIG_DIR/restic-password" ]]; then
  CONFIGURE_ARGS=(--config-dir "$CONFIG_DIR")
  [[ "$NON_INTERACTIVE" == "1" ]] && CONFIGURE_ARGS+=(--non-interactive)
  "$SCRIPT_DIR/scripts/configure.sh" "${CONFIGURE_ARGS[@]}"
else
  fail "partial local config exists; expected both hermes-backup.env and restic-password or neither"
fi

log "Step 4/5: rendering backup/check systemd --user units and reloading the user manager."
for template in "$SCRIPT_DIR"/systemd/user/*; do
  [[ -f "$template" ]] || continue
  case "$(basename -- "$template")" in
    hermes-backup-backup.service|hermes-backup-backup.timer|hermes-backup-check.service|hermes-backup-check.timer)
      render_unit_template "$template" "$SYSTEMD_USER_DIR"
      ;;
    *)
      log "Skipping non-backup/check unit template for this ticket: $(basename -- "$template")"
      ;;
  esac
done
verify_scheduler_ready
if [[ "$CUSTOM_SYSTEMD_USER_DIR" == "1" ]]; then
  log "Custom systemd user dir render requested; skipped systemctl --user daemon-reload."
else
  systemctl --user daemon-reload
fi

log "Step 5/5: timer enablement gate."
if [[ "$ENABLE_TIMERS" == "1" ]]; then
  verify_scheduler_ready
  validate_config_env_contents
  systemctl --user enable hermes-backup-backup.timer hermes-backup-check.timer
  if command -v loginctl >/dev/null 2>&1; then
    linger_state="$(loginctl show-user "${USER:-$(id -un)}" -p Linger --value 2>/dev/null || true)"
    if [[ "$linger_state" != "yes" ]]; then
      log "Warning: systemd user lingering is not enabled; timers may not run unattended after boot until an operator runs: loginctl enable-linger ${USER:-$(id -un)}"
    fi
  fi
  log "Enabled user timers for next user-manager activation: hermes-backup-backup.timer hermes-backup-check.timer"
else
  log "Rendered units but did not enable timers. To enable through the same verification gate after local verification:"
  log "  $(quote_arg "$SCRIPT_DIR/install.sh") --config-dir $(quote_arg "$CONFIG_DIR") --enable-timers"
fi

log "Bootstrap/systemd installer complete."
log "Created or verified local config dir: $CONFIG_DIR"
log "Created or verified local log dir: $LOG_DIR"
log "Created or verified local staging dir: $STAGING_DIR"
log "Created or verified safe restore dir: $RESTORE_DIR"
log "Rendered systemd units to: $SYSTEMD_USER_DIR"
log "Backup cadence: daily around 03:30 with 30m randomized delay."
log "Check cadence: weekly Sunday around 08:30 with 45m randomized delay."
log "No backup/check/restore/promote/drill command was run by install."
log "No restic init, B2/Telegram network validation, Hermes cron scheduling, or restore-drill timer enablement was run."
log "Restore-drill monthly scheduling remains owned by the restore-drill-runbook bundle after its command is reviewed."
