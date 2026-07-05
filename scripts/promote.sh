#!/usr/bin/env bash
# Explicit live promote flow for hermes-backup safe restore outputs.
# This command is intentionally separate from restore.sh and refuses to mutate
# live paths without a restored directory plus explicit operator confirmation.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/promote.sh [--manifest-dir PATH] [--live-root PATH] [--backup-root PATH] [--dry-run] [--yes --confirm PROMOTE-HERMES-RESTORE] RESTORE_DIR

Promotes an already-inspected safe restore directory into the live Hermes paths.
This is the dangerous, explicit live replacement step; restore.sh never calls it.

Required guardrails:
  * RESTORE_DIR must be an absolute path and must contain restored include roots.
  * RESTORE_DIR must not overlap live include paths.
  * Mutating mode requires both --yes and --confirm PROMOTE-HERMES-RESTORE.
  * --dry-run prints the planned backup/promote actions without changing live paths.
  * A local pre-promotion backup is created before any live path is replaced.

Defaults:
  manifest dir: scripts/../config/manifests
  live root:    /          (tests may pass a temp --live-root)
  backup root:  ~/.local/state/hermes-backup/pre-promotion-backups

Output is limited to paths/status. It never prints file contents, B2 keys, restic
passwords, Telegram tokens, raw backup archives, or credential values.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
RESTORE_MARKER_NAME=".hermes-backup-restore.json"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST_DIR="$REPO_ROOT/config/manifests"
LIVE_ROOT="/"
BACKUP_ROOT=""
DRY_RUN=0
YES=0
CONFIRM=""
RESTORE_DIR=""

backup_root_default() {
  [[ -n "${HOME:-}" ]] || fail "HOME must be set"
  printf '%s/.local/state/hermes-backup/pre-promotion-backups\n' "$HOME"
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
  if [[ "$parent" == "/" ]]; then
    [[ "$candidate" == /* ]]
  else
    [[ "$candidate" == "$parent" || "$candidate" == "$parent"/* ]]
  fi
}

relative_without_leading_slash() {
  local live_path=$1
  printf '%s\n' "${live_path#/}"
}

join_live_root() {
  local live_path=$1 root_norm rel
  root_norm="$(normalize_path "$LIVE_ROOT")"
  rel="$(relative_without_leading_slash "$live_path")"
  if [[ "$root_norm" == "/" ]]; then
    printf '/%s\n' "$rel"
  else
    printf '%s/%s\n' "$root_norm" "$rel"
  fi
}

copy_path_contents() {
  local src=$1 dst=$2
  mkdir -p -- "$(dirname -- "$dst")"
  rm -rf -- "$dst"
  cp -a -- "$src" "$dst"
}

validate_args() {
  [[ -n "$RESTORE_DIR" ]] || fail "RESTORE_DIR is required; run restore.sh first, inspect the output, then pass that absolute path here"
  case "$RESTORE_DIR" in /*) ;; *) fail "RESTORE_DIR must be an absolute path" ;; esac
  case "$MANIFEST_DIR" in /*) ;; *) fail "--manifest-dir must be an absolute path" ;; esac
  case "$LIVE_ROOT" in /*) ;; *) fail "--live-root must be an absolute path" ;; esac
  BACKUP_ROOT=${BACKUP_ROOT:-$(backup_root_default)}
  case "$BACKUP_ROOT" in /*) ;; *) fail "--backup-root must be an absolute path" ;; esac
  [[ "$DRY_RUN" -eq 1 || ( "$YES" -eq 1 && "$CONFIRM" == "PROMOTE-HERMES-RESTORE" ) ]] || fail "live promote requires --yes --confirm PROMOTE-HERMES-RESTORE, or use --dry-run"
}

refuse_symlinked_path_components() {
  local label=$1 path=$2 current="" part
  local rest=${path#/}
  IFS=/ read -r -a parts <<< "$rest"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    [[ ! -L "$current" ]] || fail "$label must not contain symlinked path components: $current"
  done
}

validate_backup_root_safety() {
  local include_manifest=$1 restore_norm=$2 backup_norm=$3 live_path live_target live_norm
  if is_same_or_descendant "$backup_norm" "$restore_norm" || is_same_or_descendant "$restore_norm" "$backup_norm"; then
    fail "--backup-root must not overlap RESTORE_DIR: backup_root=$backup_norm restore_dir=$restore_norm"
  fi
  while IFS= read -r live_path; do
    live_target="$(join_live_root "$live_path")"
    live_norm="$(normalize_path "$live_target")"
    if is_same_or_descendant "$backup_norm" "$live_norm" || is_same_or_descendant "$live_norm" "$backup_norm"; then
      fail "--backup-root must not overlap live include path: backup_root=$backup_norm live_path=$live_norm"
    fi
  done < <(read_manifest_lines "$include_manifest")
}

validate_restore_layout() {
  local include_manifest=$1 restore_norm=$2 live_path rel restored_path restored_real live_target live_norm count=0 marker
  [[ ! -L "$RESTORE_DIR" ]] || fail "RESTORE_DIR must not be a symlink: $RESTORE_DIR"
  [[ -d "$RESTORE_DIR" ]] || fail "RESTORE_DIR not found or not a directory: $RESTORE_DIR"
  restore_norm="$(realpath -e -- "$RESTORE_DIR")"
  marker="$RESTORE_DIR/$RESTORE_MARKER_NAME"
  [[ ! -L "$marker" ]] || fail "restore provenance marker must not be a symlink: $marker"
  [[ -f "$marker" ]] || fail "RESTORE_DIR missing restore provenance marker from restore.sh: $marker"
  grep -q '"tool":"restore.sh"' "$marker" || fail "restore provenance marker is not from restore.sh: $marker"
  grep -q '"mode":"non-live-inspection-only"' "$marker" || fail "restore provenance marker is not a safe non-live restore: $marker"
  grep -q '"promote":"false"' "$marker" || fail "restore provenance marker does not prove non-promoted restore output: $marker"
  [[ ! -e "$RESTORE_DIR/.restic-restore-raw" ]] || fail "RESTORE_DIR still contains raw restic layout; use restore.sh output after flattening"
  while IFS= read -r live_path; do
    case "$live_path" in /*) ;; *) fail "include manifest path must be absolute: $live_path" ;; esac
    rel="$(relative_without_leading_slash "$live_path")"
    restored_path="$RESTORE_DIR/$rel"
    live_target="$(join_live_root "$live_path")"
    live_norm="$(normalize_path "$live_target")"
    if is_same_or_descendant "$restore_norm" "$live_norm" || is_same_or_descendant "$live_norm" "$restore_norm"; then
      fail "refusing promote from restore path overlapping live include path: restore=$restore_norm live_path=$live_norm"
    fi
    [[ -e "$restored_path" ]] || fail "restore path does not contain expected include path: $restored_path"
    [[ -d "$restored_path" ]] || fail "restored include path must be a directory: $restored_path"
    refuse_symlinked_path_components "restored include path" "$restored_path"
    restored_real="$(realpath -e -- "$restored_path")"
    is_same_or_descendant "$restored_real" "$restore_norm" || fail "restored include path resolves outside RESTORE_DIR: $restored_path"
    refuse_symlinked_path_components "live include path" "$live_target"
    count=$((count + 1))
  done < <(read_manifest_lines "$include_manifest")
  [[ "$count" -gt 0 ]] || fail "include manifest is empty: $include_manifest"
}

systemd_user_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user list-units >/dev/null 2>&1
}

maybe_stop_user_services() {
  systemd_user_available || { log "systemd_user=unavailable action=skip"; return 0; }
  local unit stopped=0
  for unit in hermes-gateway.service hermes-dashboard.service; do
    if systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then
      log "systemd_user=stop unit=$unit"
      systemctl --user stop "$unit"
      stopped=$((stopped + 1))
    fi
  done
  log "systemd_user=stop_checked stopped=$stopped"
}

maybe_reload_user_systemd() {
  systemd_user_available || { log "systemd_user_reload=unavailable action=skip"; return 0; }
  log "systemd_user=daemon-reload"
  if ! systemctl --user daemon-reload; then
    log "systemd_user_reload=warning action=failed-after-promote-check-manually"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-dir)
      [[ $# -ge 2 ]] || fail "--manifest-dir requires a path"
      MANIFEST_DIR=$2; shift 2 ;;
    --live-root)
      [[ $# -ge 2 ]] || fail "--live-root requires a path"
      LIVE_ROOT=$2; shift 2 ;;
    --backup-root)
      [[ $# -ge 2 ]] || fail "--backup-root requires a path"
      BACKUP_ROOT=$2; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --yes)
      YES=1; shift ;;
    --confirm)
      [[ $# -ge 2 ]] || fail "--confirm requires PROMOTE-HERMES-RESTORE"
      CONFIRM=$2; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*) fail "unknown argument: $1" ;;
    *)
      [[ -z "$RESTORE_DIR" ]] || fail "only one RESTORE_DIR may be provided"
      RESTORE_DIR=$1; shift ;;
  esac
done

validate_args
refuse_symlinked_path_components "RESTORE_DIR" "$RESTORE_DIR"
refuse_symlinked_path_components "live root" "$LIVE_ROOT"
refuse_symlinked_path_components "backup root" "$BACKUP_ROOT"
INCLUDE_MANIFEST="$MANIFEST_DIR/include.paths"
EXCLUDE_MANIFEST="$MANIFEST_DIR/exclude.patterns"
[[ -f "$INCLUDE_MANIFEST" ]] || fail "include manifest not found: $INCLUDE_MANIFEST"
[[ -f "$EXCLUDE_MANIFEST" ]] || fail "exclude manifest not found: $EXCLUDE_MANIFEST"
RESTORE_DIR="$(normalize_path "$RESTORE_DIR")"
LIVE_ROOT="$(normalize_path "$LIVE_ROOT")"
BACKUP_ROOT="$(normalize_path "$BACKUP_ROOT")"
validate_restore_layout "$INCLUDE_MANIFEST" "$RESTORE_DIR"
RESTORE_DIR="$(realpath -e -- "$RESTORE_DIR")"
validate_backup_root_safety "$INCLUDE_MANIFEST" "$RESTORE_DIR" "$BACKUP_ROOT"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  PROMOTION_BACKUP_DIR="$BACKUP_ROOT/$stamp.<unique>"
else
  mkdir -p -- "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
  PROMOTION_BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/$stamp.XXXXXX")"
  chmod 700 "$PROMOTION_BACKUP_DIR" 2>/dev/null || true
fi
log "Hermes backup explicit live promote"
log "restore_dir=$RESTORE_DIR"
log "live_root=$LIVE_ROOT"
log "pre_promotion_backup=$PROMOTION_BACKUP_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "mode=dry-run promote=false"
else
  log "mode=confirmed promote=true"
fi

while IFS= read -r live_path; do
  rel="$(relative_without_leading_slash "$live_path")"
  restored_path="$RESTORE_DIR/$rel"
  live_target="$(join_live_root "$live_path")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -e "$live_target" ]]; then
      log "plan backup live_path=$live_path status=would-back-up"
    else
      log "plan backup live_path=$live_path status=missing-live"
    fi
    log "plan promote live_path=$live_path restored_path=$restored_path"
  fi
done < <(read_manifest_lines "$INCLUDE_MANIFEST")

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry_run=ok no_live_paths_changed=true"
  log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
  exit 0
fi

maybe_stop_user_services

while IFS= read -r live_path; do
  rel="$(relative_without_leading_slash "$live_path")"
  live_target="$(join_live_root "$live_path")"
  backup_target="$PROMOTION_BACKUP_DIR/$rel"
  if [[ -e "$live_target" ]]; then
    copy_path_contents "$live_target" "$backup_target"
    log "backup live_path=$live_path status=ok backup_path=$backup_target"
  else
    log "backup live_path=$live_path status=missing-live backup_path=$backup_target"
  fi
done < <(read_manifest_lines "$INCLUDE_MANIFEST")

while IFS= read -r live_path; do
  rel="$(relative_without_leading_slash "$live_path")"
  restored_path="$RESTORE_DIR/$rel"
  live_target="$(join_live_root "$live_path")"
  copy_path_contents "$restored_path" "$live_target"
  log "promote live_path=$live_path status=ok restored_path=$restored_path"
done < <(read_manifest_lines "$INCLUDE_MANIFEST")

maybe_reload_user_systemd
log "promote=ok"
log "verification_checklist=inspect Hermes profiles, shared outputs, shared-assets, systemd user units, and Quadlets; restart only intended services after review"
log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
