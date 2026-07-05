#!/usr/bin/env bash
# Explicit live promote flow for hermes-backup safe restore outputs.
# This command is intentionally separate from restore.sh and refuses to mutate
# live paths without a restored directory plus explicit operator confirmation.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/promote.sh [--manifest-dir PATH] [--live-root PATH] [--backup-root PATH] [--dry-run] [--quiesce-ack PROMOTE-HERMES-QUIESCE] [--yes --confirm PROMOTE-HERMES-RESTORE] RESTORE_DIR
       scripts/promote.sh [--manifest-dir PATH] [--live-root PATH] [--quiesce-ack PROMOTE-HERMES-QUIESCE] --rollback PRE_PROMOTION_BACKUP_DIR --yes --confirm PROMOTE-HERMES-ROLLBACK

Promotes an already-inspected safe restore directory into the live Hermes paths.
This is the dangerous, explicit live replacement step; restore.sh never calls it.

Required guardrails:
  * RESTORE_DIR must be an absolute path and must contain restored include roots.
  * RESTORE_DIR must not overlap live include paths.
  * Mutating mode requires both --yes and --confirm PROMOTE-HERMES-RESTORE.
  * --dry-run prints the planned backup/promote and quiesce actions without changing live paths.
  * Confirmed promote stops only reviewed Hermes user-service units.
  * If other active Hermes services/processes are detected, pass --quiesce-ack PROMOTE-HERMES-QUIESCE only after manually quiescing or accepting the risk.
  * A local pre-promotion backup is created before any live path is replaced.
  * Confirmed promote writes a recovery checkpoint inside that backup directory.
  * If promote is interrupted or fails after live replacement begins, rerun the
    printed --rollback command after inspecting/quiescing the VM.

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
RECOVERY_CHECKPOINT_NAME=".hermes-backup-promote-recovery.tsv"
# Reviewed, explicit allowlist: confirmed promote may stop only these user services.
# Other Hermes-like services/processes are detected and surfaced for operator review,
# but are never killed/stopped automatically by this script.
REVIEWED_STOP_UNITS=(
  "hermes-gateway.service"
  "hermes-dashboard.service"
)
HERMES_SERVICE_GLOBS=("hermes*.service")


SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST_DIR="$REPO_ROOT/config/manifests"
LIVE_ROOT="/"
BACKUP_ROOT=""
ROLLBACK_DIR=""
DRY_RUN=0
YES=0
CONFIRM=""
QUIESCE_ACK=""
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

replace_path_contents() {
  local src=$1 dst=$2 tmp
  mkdir -p -- "$(dirname -- "$dst")"
  tmp="$(mktemp -d "$(dirname -- "$dst")/.${dst##*/}.promote-copy.XXXXXX")"
  rm -rf -- "$tmp"
  cp -a -- "$src" "$tmp"
  rm -rf -- "$dst"
  mv -- "$tmp" "$dst"
}

shell_quote() {
  printf '%q' "$1"
}

rollback_command() {
  printf 'scripts/promote.sh --manifest-dir %s --live-root %s --rollback %s --yes --confirm PROMOTE-HERMES-ROLLBACK' \
    "$(shell_quote "$MANIFEST_DIR")" "$(shell_quote "$LIVE_ROOT")" "$(shell_quote "$PROMOTION_BACKUP_DIR")"
  if [[ -n "$QUIESCE_ACK" ]]; then
    printf ' --quiesce-ack %s' "$(shell_quote "$QUIESCE_ACK")"
  fi
  printf '\n'
}

print_recovery_guidance() {
  local reason=$1
  if [[ -n "${PROMOTION_BACKUP_DIR:-}" && -f "$PROMOTION_BACKUP_DIR/$RECOVERY_CHECKPOINT_NAME" ]]; then
    printf 'promote_recovery=available reason=%s backup_path=%s checkpoint=%s\n' "$reason" "$PROMOTION_BACKUP_DIR" "$PROMOTION_BACKUP_DIR/$RECOVERY_CHECKPOINT_NAME" >&2
    printf 'promote_recovery_command=%s\n' "$(rollback_command)" >&2
    printf 'promote_recovery_service_guidance=keep unintended services stopped until rollback or rerun-promote completes; then run systemctl --user daemon-reload and restart only reviewed services after inspection\n' >&2
  else
    printf 'promote_recovery=not-started reason=%s live_replacements_not_checkpointed=true\n' "$reason" >&2
  fi
}

on_promote_exit() {
  local status=$?
  trap - EXIT INT TERM HUP
  [[ "$status" -eq 0 ]] && return 0
  case "${PROMOTE_PHASE:-}" in
    backup) print_recovery_guidance "backup-failed-before-live-replacement" ;;
    promote) print_recovery_guidance "promote-failed-or-interrupted" ;;
  esac
  exit "$status"
}

on_promote_signal() {
  local signal=$1 status=1
  trap - EXIT INT TERM HUP
  case "$signal" in
    HUP) status=129 ;;
    INT) status=130 ;;
    TERM) status=143 ;;
  esac
  case "${PROMOTE_PHASE:-}" in
    backup) print_recovery_guidance "backup-interrupted-by-$signal-before-live-replacement" ;;
    promote) print_recovery_guidance "promote-interrupted-by-$signal" ;;
  esac
  exit "$status"
}

write_recovery_checkpoint_header() {
  local checkpoint=$1
  : >"$checkpoint"
  chmod 600 "$checkpoint" 2>/dev/null || true
  printf '# hermes-backup promote recovery checkpoint v1\n' >>"$checkpoint"
  printf '# status<TAB>live_path<TAB>backup_path\n' >>"$checkpoint"
}

record_recovery_checkpoint() {
  local status=$1 live_path=$2 backup_target=$3 checkpoint=$4
  printf '%s\t%s\t%s\n' "$status" "$live_path" "$backup_target" >>"$checkpoint"
}

validate_args() {
  case "$MANIFEST_DIR" in /*) ;; *) fail "--manifest-dir must be an absolute path" ;; esac
  case "$LIVE_ROOT" in /*) ;; *) fail "--live-root must be an absolute path" ;; esac
  if [[ -n "$ROLLBACK_DIR" ]]; then
    [[ -z "$RESTORE_DIR" ]] || fail "--rollback cannot be combined with RESTORE_DIR"
    case "$ROLLBACK_DIR" in /*) ;; *) fail "--rollback requires an absolute PRE_PROMOTION_BACKUP_DIR" ;; esac
    [[ "$DRY_RUN" -eq 0 ]] || fail "--rollback does not support --dry-run; inspect the checkpoint manually instead"
    [[ "$YES" -eq 1 && "$CONFIRM" == "PROMOTE-HERMES-ROLLBACK" ]] || fail "rollback requires --yes --confirm PROMOTE-HERMES-ROLLBACK"
    return 0
  fi
  [[ -n "$RESTORE_DIR" ]] || fail "RESTORE_DIR is required; run restore.sh first, inspect the output, then pass that absolute path here"
  case "$RESTORE_DIR" in /*) ;; *) fail "RESTORE_DIR must be an absolute path" ;; esac
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

unit_is_reviewed_stop_unit() {
  local candidate=$1 unit
  for unit in "${REVIEWED_STOP_UNITS[@]}"; do
    [[ "$candidate" == "$unit" ]] && return 0
  done
  return 1
}

reviewed_process_class_for_unit() {
  case "$1" in
    hermes-gateway.service) printf '%s\n' "hermes-gateway" ;;
    hermes-dashboard.service) printf '%s\n' "hermes-dashboard" ;;
    *) return 1 ;;
  esac
}

quiesce_process_class() {
  local comm=$1 args=$2 text word base
  text="$comm $args"
  case "$text" in
    *hermes-gateway*|*"hermes gateway"*) printf '%s\n' "hermes-gateway" ;;
    *hermes-dashboard*|*"hermes dashboard"*) printf '%s\n' "hermes-dashboard" ;;
    *hermes-github-pr-kanban-bridge*|*github_pr_kanban_bridge.py*) printf '%s\n' "hermes-pr-kanban-bridge" ;;
    *"hermes kanban"*) printf '%s\n' "hermes-kanban" ;;
    *)
      for word in $comm $args; do
        base=${word##*/}
        case "$base" in
          hermes|hermes-[!-]*) printf '%s\n' "$base"; return 0 ;;
        esac
      done
      return 1 ;;
  esac
}

collect_hermes_processes() {
  command -v ps >/dev/null 2>&1 || return 2
  local pid comm args class ps_output
  ps_output="$(ps -eo pid=,comm=,args= 2>/dev/null)" || return $?
  while read -r pid comm args; do
    [[ -n "${pid:-}" && "$pid" != "$$" && "$pid" != "${BASHPID:-}" ]] || continue
    class="$(quiesce_process_class "${comm:-}" "${args:-}" 2>/dev/null || true)"
    [[ -n "$class" ]] || continue
    printf '%s\t%s\t%s\n' "$pid" "${comm:-unknown}" "$class"
  done <<< "$ps_output"
}

emit_quiesce_plan() {
  local phase=${1:-pre-promote} unit glob line pid comm class active_count=0 reviewed_active=0 unreviewed_active=0 process_active=0 probe_blockers=0 process_lines process_status=0 service_lines service_status=0 reviewed_process_classes="" unit_class
  log "quiesce_plan=begin phase=$phase reviewed_stop_units=${REVIEWED_STOP_UNITS[*]}"
  if systemd_user_available; then
    for unit in "${REVIEWED_STOP_UNITS[@]}"; do
      if systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then
        log "quiesce service=$unit status=active action=stop-reviewed-before-promote"
        unit_class="$(reviewed_process_class_for_unit "$unit" 2>/dev/null || true)"
        [[ -z "$unit_class" ]] || reviewed_process_classes="${reviewed_process_classes} ${unit_class}"
        active_count=$((active_count + 1)); reviewed_active=$((reviewed_active + 1))
      else
        log "quiesce service=$unit status=inactive action=none"
      fi
    done
    for glob in "${HERMES_SERVICE_GLOBS[@]}"; do
      service_status=0
      service_lines="$(systemctl --user list-units --type=service --state=active --all --no-legend --plain "$glob" 2>/dev/null)" || service_status=$?
      if [[ "$service_status" -ne 0 ]]; then
        log "quiesce service_probe=systemd_user_list_units pattern=$glob status=failed action=manual-check-or-ack"
        probe_blockers=$((probe_blockers + 1))
        continue
      fi
      while IFS= read -r line; do
        unit=${line%% *}
        [[ -n "$unit" ]] || continue
        unit_is_reviewed_stop_unit "$unit" && continue
        log "quiesce service=$unit status=active action=manual-stop-or-ack"
        active_count=$((active_count + 1)); unreviewed_active=$((unreviewed_active + 1))
      done <<< "$service_lines"
    done
  else
    log "quiesce service_probe=systemd_user status=unavailable action=manual-check-or-ack"
    probe_blockers=$((probe_blockers + 1))
  fi

  if command -v ps >/dev/null 2>&1; then
    process_lines="$(collect_hermes_processes)" || process_status=$?
    if [[ "$process_status" -ne 0 ]]; then
      log "quiesce process_probe=ps status=failed action=manual-check-or-ack"
      probe_blockers=$((probe_blockers + 1))
    else
      while IFS=$'\t' read -r pid comm class; do
        [[ -n "$pid" ]] || continue
        if [[ " $reviewed_process_classes " == *" $class "* ]]; then
          log "quiesce process_class=$class pid=$pid command=$comm status=active action=covered-by-reviewed-service-stop"
          continue
        fi
        log "quiesce process_class=$class pid=$pid command=$comm status=active action=manual-stop-or-ack"
        active_count=$((active_count + 1)); process_active=$((process_active + 1))
      done <<< "$process_lines"
    fi
  else
    log "quiesce process_probe=ps status=unavailable action=manual-check-or-ack"
    probe_blockers=$((probe_blockers + 1))
  fi
  log "quiesce_plan=end phase=$phase active_items=$active_count reviewed_service_active=$reviewed_active unreviewed_service_active=$unreviewed_active process_active=$process_active probe_blockers=$probe_blockers"
  QUIESCE_REVIEWED_ACTIVE=$reviewed_active
  QUIESCE_NONREVIEWED_BLOCKERS=$((unreviewed_active + process_active + probe_blockers))
  QUIESCE_REMAINING_BLOCKERS=$((reviewed_active + QUIESCE_NONREVIEWED_BLOCKERS))
}

stop_reviewed_user_services() {
  systemd_user_available || return 0
  local unit stopped=0
  for unit in "${REVIEWED_STOP_UNITS[@]}"; do
    if systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then
      log "systemd_user=stop unit=$unit reason=reviewed-quiesce-allowlist"
      systemctl --user stop "$unit"
      stopped=$((stopped + 1))
    fi
  done
  log "systemd_user=stop_checked stopped=$stopped"
}

require_nonreviewed_clear_or_ack() {
  local blockers=${QUIESCE_NONREVIEWED_BLOCKERS:-0}
  if [[ "$blockers" -eq 0 ]]; then
    return 0
  fi
  if [[ "$QUIESCE_ACK" == "PROMOTE-HERMES-QUIESCE" ]]; then
    log "quiesce=acknowledged nonreviewed_blockers=$blockers ack=PROMOTE-HERMES-QUIESCE"
    return 0
  fi
  fail "active or unverified Hermes services/processes remain; rerun --dry-run, quiesce them manually, or pass --quiesce-ack PROMOTE-HERMES-QUIESCE after review"
}

require_quiesce_clear_after_stop() {
  local reviewed=${QUIESCE_REVIEWED_ACTIVE:-0}
  if [[ "$reviewed" -ne 0 ]]; then
    fail "reviewed Hermes services remain active after stop; inspect systemctl status before promoting"
  fi
  require_nonreviewed_clear_or_ack
  log "quiesce=ok remaining_blockers=0"
}

maybe_reload_user_systemd() {
  systemd_user_available || { log "systemd_user_reload=unavailable action=skip"; return 0; }
  log "systemd_user=daemon-reload"
  if ! systemctl --user daemon-reload; then
    log "systemd_user_reload=warning action=failed-after-promote-check-manually"
  fi
}

run_rollback() {
  local checkpoint live_path backup_target status rel expected_backup live_target restored=0 removed=0
  ROLLBACK_DIR="$(normalize_path "$ROLLBACK_DIR")"
  LIVE_ROOT="$(normalize_path "$LIVE_ROOT")"
  refuse_symlinked_path_components "rollback backup root" "$ROLLBACK_DIR"
  [[ -d "$ROLLBACK_DIR" ]] || fail "rollback backup directory not found: $ROLLBACK_DIR"
  checkpoint="$ROLLBACK_DIR/$RECOVERY_CHECKPOINT_NAME"
  [[ ! -L "$checkpoint" ]] || fail "rollback checkpoint must not be a symlink: $checkpoint"
  [[ -f "$checkpoint" ]] || fail "rollback checkpoint not found: $checkpoint"

  log "Hermes backup explicit promote rollback"
  log "rollback_backup=$ROLLBACK_DIR"
  log "live_root=$LIVE_ROOT"
  emit_quiesce_plan "pre-rollback"
  require_nonreviewed_clear_or_ack
  stop_reviewed_user_services
  emit_quiesce_plan "post-reviewed-stop-rollback"
  require_quiesce_clear_after_stop

  while IFS=$'\t' read -r status live_path backup_target; do
    [[ -n "${status:-}" ]] || continue
    [[ "$status" != \#* ]] || continue
    case "$live_path" in /*) ;; *) fail "rollback checkpoint live path must be absolute: $live_path" ;; esac
    rel="$(relative_without_leading_slash "$live_path")"
    expected_backup="$ROLLBACK_DIR/$rel"
    [[ "$backup_target" == "$expected_backup" ]] || fail "rollback checkpoint backup path mismatch for $live_path"
    live_target="$(join_live_root "$live_path")"
    case "$status" in
      present)
        [[ -d "$backup_target" ]] || fail "rollback backup path missing for $live_path: $backup_target"
        replace_path_contents "$backup_target" "$live_target"
        log "rollback live_path=$live_path status=restored backup_path=$backup_target"
        restored=$((restored + 1))
        ;;
      missing)
        rm -rf -- "$live_target"
        log "rollback live_path=$live_path status=removed-to-original-missing"
        removed=$((removed + 1))
        ;;
      *) fail "rollback checkpoint has unknown status for $live_path: $status" ;;
    esac
  done <"$checkpoint"

  maybe_reload_user_systemd
  log "rollback=ok restored=$restored removed=$removed"
  log "verification_checklist=inspect Hermes profiles, shared outputs, shared-assets, systemd user units, and Quadlets; restart only intended services after review"
  log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
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
    --rollback)
      [[ $# -ge 2 ]] || fail "--rollback requires a pre-promotion backup directory"
      ROLLBACK_DIR=$2; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --yes)
      YES=1; shift ;;
    --confirm)
      [[ $# -ge 2 ]] || fail "--confirm requires PROMOTE-HERMES-RESTORE"
      CONFIRM=$2; shift 2 ;;
    --quiesce-ack)
      [[ $# -ge 2 ]] || fail "--quiesce-ack requires PROMOTE-HERMES-QUIESCE"
      QUIESCE_ACK=$2; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*) fail "unknown argument: $1" ;;
    *)
      [[ -z "$RESTORE_DIR" ]] || fail "only one RESTORE_DIR may be provided"
      RESTORE_DIR=$1; shift ;;
  esac
done

validate_args
refuse_symlinked_path_components "live root" "$LIVE_ROOT"
INCLUDE_MANIFEST="$MANIFEST_DIR/include.paths"
EXCLUDE_MANIFEST="$MANIFEST_DIR/exclude.patterns"
[[ -f "$INCLUDE_MANIFEST" ]] || fail "include manifest not found: $INCLUDE_MANIFEST"
[[ -f "$EXCLUDE_MANIFEST" ]] || fail "exclude manifest not found: $EXCLUDE_MANIFEST"
if [[ -n "$ROLLBACK_DIR" ]]; then
  run_rollback
  exit 0
fi
refuse_symlinked_path_components "RESTORE_DIR" "$RESTORE_DIR"
refuse_symlinked_path_components "backup root" "$BACKUP_ROOT"
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
  PROMOTION_BACKUP_DIR=""
fi
log "Hermes backup explicit live promote"
log "restore_dir=$RESTORE_DIR"
log "live_root=$LIVE_ROOT"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "pre_promotion_backup=$PROMOTION_BACKUP_DIR"
  log "mode=dry-run promote=false"
else
  log "mode=confirmed promote=true"
fi

emit_quiesce_plan "pre-promote"
if [[ "$DRY_RUN" -eq 0 ]]; then
  require_nonreviewed_clear_or_ack
  stop_reviewed_user_services
  emit_quiesce_plan "post-reviewed-stop"
  require_quiesce_clear_after_stop
  mkdir -p -- "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
  PROMOTION_BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/$stamp.XXXXXX")"
  chmod 700 "$PROMOTION_BACKUP_DIR" 2>/dev/null || true
  log "pre_promotion_backup=$PROMOTION_BACKUP_DIR"
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

# Quiesce was checked and reviewed services were stopped before any live backup or promote mutation.
CHECKPOINT_PATH="$PROMOTION_BACKUP_DIR/$RECOVERY_CHECKPOINT_NAME"
write_recovery_checkpoint_header "$CHECKPOINT_PATH"
trap on_promote_exit EXIT
trap 'on_promote_signal HUP' HUP
trap 'on_promote_signal INT' INT
trap 'on_promote_signal TERM' TERM
PROMOTE_PHASE=backup

while IFS= read -r live_path; do
  rel="$(relative_without_leading_slash "$live_path")"
  live_target="$(join_live_root "$live_path")"
  backup_target="$PROMOTION_BACKUP_DIR/$rel"
  if [[ -e "$live_target" ]]; then
    copy_path_contents "$live_target" "$backup_target"
    record_recovery_checkpoint "present" "$live_path" "$backup_target" "$CHECKPOINT_PATH"
    log "backup live_path=$live_path status=ok backup_path=$backup_target"
  else
    record_recovery_checkpoint "missing" "$live_path" "$backup_target" "$CHECKPOINT_PATH"
    log "backup live_path=$live_path status=missing-live backup_path=$backup_target"
  fi
done < <(read_manifest_lines "$INCLUDE_MANIFEST")

log "promote_recovery_checkpoint=$CHECKPOINT_PATH"
log "promote_recovery_command=$(rollback_command)"
PROMOTE_PHASE=promote

while IFS= read -r live_path; do
  rel="$(relative_without_leading_slash "$live_path")"
  restored_path="$RESTORE_DIR/$rel"
  live_target="$(join_live_root "$live_path")"
  replace_path_contents "$restored_path" "$live_target"
  log "promote live_path=$live_path status=ok restored_path=$restored_path"
done < <(read_manifest_lines "$INCLUDE_MANIFEST")
PROMOTE_PHASE=done
trap - EXIT INT TERM HUP

maybe_reload_user_systemd
log "promote=ok"
log "verification_checklist=inspect Hermes profiles, shared outputs, shared-assets, systemd user units, and Quadlets; restart only intended services after review"
log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
