#!/usr/bin/env bash
# SQLite-safe staging pipeline for hermes-backup.
# Reads config/manifests as source of truth, stages included roots under a unique
# runtime directory, and uses sqlite3 .backup for live-like SQLite databases.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/stage.sh [--root PATH] [--manifest-dir PATH] [--staging-parent PATH] [--keep]

Creates a SQLite-safe staging snapshot from the configured include/exclude
manifests. --root maps absolute VM paths under a fixture root for tests. By
default, successful transient staging output is removed; pass --keep to preserve
it for a downstream backup command or investigation.

The command prints paths/counts/status only. It never prints file contents or
secret environment values.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST_DIR="$REPO_ROOT/config/manifests"
ROOT_PREFIX=""
STAGING_PARENT="${HERMES_BACKUP_STAGING_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hermes-backup/staging}"
KEEP_STAGING=0
STAGING_ROOT=""
STATUS="failed"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || fail "--root requires a path"
      ROOT_PREFIX=$2
      shift 2
      ;;
    --manifest-dir)
      [[ $# -ge 2 ]] || fail "--manifest-dir requires a path"
      MANIFEST_DIR=$2
      shift 2
      ;;
    --staging-parent)
      [[ $# -ge 2 ]] || fail "--staging-parent requires a path"
      STAGING_PARENT=$2
      shift 2
      ;;
    --keep)
      KEEP_STAGING=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

cleanup() {
  local rc=$?
  if [[ "$rc" -eq 0 && "$STATUS" == "ok" && "$KEEP_STAGING" -eq 0 && -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    rm -rf -- "$STAGING_ROOT"
    log "cleanup=removed staging_root=$STAGING_ROOT"
  elif [[ "$rc" -ne 0 && -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    log "cleanup=kept-for-failure staging_root=$STAGING_ROOT" >&2
  fi
}
trap cleanup EXIT

INCLUDE_MANIFEST="$MANIFEST_DIR/include.paths"
EXCLUDE_MANIFEST="$MANIFEST_DIR/exclude.patterns"
[[ -f "$INCLUDE_MANIFEST" ]] || fail "include manifest not found: $INCLUDE_MANIFEST"
[[ -f "$EXCLUDE_MANIFEST" ]] || fail "exclude manifest not found: $EXCLUDE_MANIFEST"

case "$STAGING_PARENT" in /*) ;; *) fail "--staging-parent must be an absolute path" ;; esac
if [[ -n "$ROOT_PREFIX" ]]; then
  case "$ROOT_PREFIX" in /*) ;; *) fail "--root must be an absolute path" ;; esac
  [[ -d "$ROOT_PREFIX" ]] || fail "--root must be an existing directory: $ROOT_PREFIX"
  ROOT_PREFIX="$(cd -- "$ROOT_PREFIX" && pwd -P)"
fi

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

map_to_fs_path() {
  local live_path=$1
  if [[ -z "$ROOT_PREFIX" ]]; then
    printf '%s\n' "$live_path"
  else
    printf '%s%s\n' "$ROOT_PREFIX" "$live_path"
  fi
}

fs_to_live_path() {
  local fs_path=$1
  if [[ -n "$ROOT_PREFIX" ]]; then
    case "$fs_path" in
      "$ROOT_PREFIX"/*) printf '/%s\n' "${fs_path#"$ROOT_PREFIX"/}" ;;
      "$ROOT_PREFIX") printf '/\n' ;;
      *) printf '%s\n' "$fs_path" ;;
    esac
  else
    printf '%s\n' "$fs_path"
  fi
}

match_exclude_pattern() {
  local live_path=$1 pattern=$2 base
  if [[ "$pattern" == *'/**' ]]; then
    base=${pattern%/**}
    [[ "$live_path" == $base || "$live_path" == $base/* || "$live_path" == $pattern ]]
    return
  fi
  [[ "$live_path" == $pattern ]]
}

is_excluded_live_path() {
  local live_path=$1 pattern
  for pattern in "${excludes[@]}"; do
    if match_exclude_pattern "$live_path" "$pattern"; then
      return 0
    fi
  done
  return 1
}

is_sqlite_candidate_name() {
  local live_path=$1 lower
  lower=${live_path,,}
  case "$lower" in
    *.db|*.sqlite|*.sqlite3|*.db3) return 0 ;;
    *) return 1 ;;
  esac
}

is_sqlite_sidecar_name() {
  local live_path=$1 lower
  lower=${live_path,,}
  case "$lower" in
    *-wal|*-shm|*-journal|*.db-wal|*.db-shm|*.sqlite-wal|*.sqlite-shm|*.sqlite3-wal|*.sqlite3-shm) return 0 ;;
    *) return 1 ;;
  esac
}

has_sqlite_header() {
  local fs_path=$1
  LC_ALL=C head -c 15 -- "$fs_path" 2>/dev/null | LC_ALL=C grep -aq '^SQLite format 3'
}

relative_without_leading_slash() {
  local live_path=$1
  printf '%s\n' "${live_path#/}"
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//"/\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

metadata_array() {
  local name=$1; shift
  local first=1 item
  printf '  "%s": [' "$name"
  for item in "$@"; do
    if [[ "$first" -eq 0 ]]; then printf ', '; fi
    printf '"%s"' "$(json_escape "$item")"
    first=0
  done
  printf ']'
}

includes=()
excludes=()
while IFS= read -r line; do includes+=("$line"); done < <(read_manifest_lines "$INCLUDE_MANIFEST")
while IFS= read -r line; do excludes+=("$line"); done < <(read_manifest_lines "$EXCLUDE_MANIFEST")

[[ ${#includes[@]} -gt 0 ]] || fail "include manifest is empty"
[[ ${#excludes[@]} -gt 0 ]] || fail "exclude manifest is empty"

for live_path in "${includes[@]}"; do
  case "$live_path" in /*) ;; *) fail "include manifest path must be absolute: $live_path" ;; esac
done
for pattern in "${excludes[@]}"; do
  case "$pattern" in /*) ;; *) fail "exclude manifest pattern must be absolute: $pattern" ;; esac
done

command -v rsync >/dev/null 2>&1 || fail "rsync is required for staging copies"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required for SQLite-safe backups"

[[ -d "$STAGING_PARENT" || ! -e "$STAGING_PARENT" ]] || fail "staging parent is not a directory: $STAGING_PARENT"
mkdir -p -- "$STAGING_PARENT"
chmod 700 "$STAGING_PARENT" 2>/dev/null || true
STAGING_PARENT="$(cd -- "$STAGING_PARENT" && pwd -P)"
STAGING_ROOT="$(mktemp -d "$STAGING_PARENT/stage-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
chmod 700 "$STAGING_ROOT" 2>/dev/null || true

skipped_paths=()
sqlite_paths=()
non_sqlite_candidates=()
missing_roots=()
include_roots_staged=0
rsync_files=0
sqlite_backups=0

log "Hermes backup SQLite-safe staging"
log "manifest_dir=$MANIFEST_DIR"
[[ -n "$ROOT_PREFIX" ]] && log "root_prefix=$ROOT_PREFIX"
log "staging_root=$STAGING_ROOT"
log "include_roots=${#includes[@]}"
log "exclude_patterns=${#excludes[@]}"

RSYNC_FILTERS=()
for pattern in "${excludes[@]}"; do
  stripped_pattern="${pattern#/}"
  RSYNC_FILTERS+=(--filter "- $stripped_pattern")
  RSYNC_FILTERS+=(--filter "- /$stripped_pattern")
  if [[ "$stripped_pattern" == *'/**' ]]; then
    base_pattern="${stripped_pattern%/**}"
    RSYNC_FILTERS+=(--filter "- $base_pattern")
    RSYNC_FILTERS+=(--filter "- /$base_pattern")
    RSYNC_FILTERS+=(--filter "- $base_pattern/***")
    RSYNC_FILTERS+=(--filter "- /$base_pattern/***")
  fi
done
RSYNC_FILTERS+=(--filter '+ */')
for sqlite_pattern in '*.[dD][bB]' '*.[sS][qQ][lL][iI][tT][eE]' '*.[sS][qQ][lL][iI][tT][eE]3' '*.[dD][bB]3' '*-wal' '*-shm' '*-journal'; do
  RSYNC_FILTERS+=(--filter "- $sqlite_pattern")
done

for live_root in "${includes[@]}"; do
  fs_root="$(map_to_fs_path "$live_root")"
  if [[ -e "$fs_root" && ! -d "$fs_root" ]]; then
    skipped_paths+=("$live_root invalid-not-directory")
    log "include path=$live_root status=invalid-not-directory"
    continue
  fi
  if [[ ! -d "$fs_root" ]]; then
    missing_roots+=("$live_root")
    log "include path=$live_root status=missing"
    continue
  fi

  rel_root="$(relative_without_leading_slash "$live_root")"
  log "include path=$live_root status=staging"
  mkdir -p -- "$STAGING_ROOT/$(dirname -- "$rel_root")"

  rsync_out="$(mktemp -t hermes-backup-rsync.XXXXXX)"
  if [[ -n "$ROOT_PREFIX" ]]; then
    (
      cd "$ROOT_PREFIX"
      rsync -a --delete --relative --itemize-changes "${RSYNC_FILTERS[@]}" "$rel_root/" "$STAGING_ROOT/" >"$rsync_out"
    )
  else
    (
      cd /
      rsync -a --delete --relative --itemize-changes "${RSYNC_FILTERS[@]}" "$rel_root/" "$STAGING_ROOT/" >"$rsync_out"
    )
  fi
  copied_count="$(grep -c '^>f' "$rsync_out" || true)"
  rm -f -- "$rsync_out"
  rsync_files=$((rsync_files + copied_count))
  include_roots_staged=$((include_roots_staged + 1))

  while IFS= read -r -d '' candidate; do
    live_candidate="$(fs_to_live_path "$candidate")"
    if is_excluded_live_path "$live_candidate"; then
      skipped_paths+=("$live_candidate excluded")
      continue
    fi
    if is_sqlite_sidecar_name "$live_candidate"; then
      rel_sidecar="$(relative_without_leading_slash "$live_candidate")"
      rm -f -- "$STAGING_ROOT/$rel_sidecar"
      skipped_paths+=("$live_candidate sqlite-sidecar")
      continue
    fi
    if ! is_sqlite_candidate_name "$live_candidate"; then
      continue
    fi
    rel_candidate="$(relative_without_leading_slash "$live_candidate")"
    dest_db="$STAGING_ROOT/$rel_candidate"
    mkdir -p -- "$(dirname -- "$dest_db")"
    if ! has_sqlite_header "$candidate"; then
      cp -p -- "$candidate" "$dest_db"
      non_sqlite_candidates+=("$live_candidate")
      log "sqlite-candidate path=$live_candidate status=not-sqlite-copied-raw"
      continue
    fi
    rm -f -- "$dest_db" "$dest_db-wal" "$dest_db-shm" "$dest_db-journal"
    if ! sqlite3 -readonly "$candidate" ".backup '$dest_db'" >/dev/null 2>&1; then
      rm -f -- "$dest_db"
      fail "sqlite backup failed for path: $live_candidate"
    fi
    integrity_result="$(sqlite3 "$dest_db" 'PRAGMA integrity_check;' 2>&1)" || fail "integrity_check failed for staged SQLite path: $live_candidate"
    [[ "$integrity_result" == "ok" ]] || fail "integrity_check returned non-ok for staged SQLite path: $live_candidate"
    sqlite_paths+=("$live_candidate")
    sqlite_backups=$((sqlite_backups + 1))
    log "sqlite path=$live_candidate status=backed-up integrity=ok"
  done < <(find "$fs_root" -type f \( -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' -o -iname '*.db3' -o -iname '*-wal' -o -iname '*-shm' -o -iname '*-journal' \) -print0 2>/dev/null)
done

# Final guard: no excluded class may remain in the staging tree.
violations=0
while IFS= read -r -d '' staged_path; do
  live_path="/${staged_path#"$STAGING_ROOT"/}"
  if is_excluded_live_path "$live_path"; then
    log "forbidden-staged path=$live_path"
    violations=$((violations + 1))
  fi
done < <(find "$STAGING_ROOT" -mindepth 1 -print0 2>/dev/null)
[[ "$violations" -eq 0 ]] || fail "staging produced $violations excluded path violation(s)"

metadata_path="$STAGING_ROOT/staging-metadata.json"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
include_sha="$(sha256sum "$INCLUDE_MANIFEST" | awk '{print $1}')"
exclude_sha="$(sha256sum "$EXCLUDE_MANIFEST" | awk '{print $1}')"
{
  printf '{\n'
  printf '  "created_at": "%s",\n' "$(json_escape "$timestamp")"
  printf '  "manifest_dir": "%s",\n' "$(json_escape "$MANIFEST_DIR")"
  printf '  "include_manifest_sha256": "%s",\n' "$include_sha"
  printf '  "exclude_manifest_sha256": "%s",\n' "$exclude_sha"
  metadata_array "include_roots" "${includes[@]}"; printf ',\n'
  metadata_array "missing_roots" "${missing_roots[@]}"; printf ',\n'
  metadata_array "sqlite_backups" "${sqlite_paths[@]}"; printf ',\n'
  metadata_array "non_sqlite_candidates" "${non_sqlite_candidates[@]}"; printf ',\n'
  metadata_array "skipped_paths" "${skipped_paths[@]}"; printf ',\n'
  printf '  "counts": {"include_roots_staged": %s, "rsync_files": %s, "sqlite_backups": %s}\n' "$include_roots_staged" "$rsync_files" "$sqlite_backups"
  printf '}\n'
} >"$metadata_path"
chmod 600 "$metadata_path" 2>/dev/null || true

STATUS="ok"
log "metadata=$metadata_path"
log "staging passed include_roots_staged=$include_roots_staged rsync_files=$rsync_files sqlite_backups=$sqlite_backups missing_roots=${#missing_roots[@]}"
log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
if [[ "$KEEP_STAGING" -eq 1 ]]; then
  log "cleanup=kept staging_root=$STAGING_ROOT"
fi
