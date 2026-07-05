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
SQLITE_SNAPSHOT_ROOT=""
SQLITE_SNAPSHOT_MAX_ATTEMPTS="${HERMES_BACKUP_SQLITE_SNAPSHOT_ATTEMPTS:-3}"
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
  if [[ -n "$SQLITE_SNAPSHOT_ROOT" && -d "$SQLITE_SNAPSHOT_ROOT" ]]; then
    rm -rf -- "$SQLITE_SNAPSHOT_ROOT"
  fi
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

is_sqlite_wal_mode() {
  local fs_path=$1 first_byte second_byte
  read -r first_byte second_byte _ < <(LC_ALL=C od -An -tu1 -j 18 -N 2 -- "$fs_path" 2>/dev/null || true)
  [[ "$first_byte" == "2" || "$second_byte" == "2" ]]
}

sqlite_sidecar_exists() {
  local fs_path=$1 suffix
  for suffix in -wal -shm -journal; do
    [[ ! -e "${fs_path}${suffix}" ]] || return 0
  done
  return 1
}

sqlite_snapshot_state() {
  local fs_path=$1 suffix sidecar
  for suffix in '' -wal -shm -journal; do
    sidecar="${fs_path}${suffix}"
    if [[ -e "$sidecar" ]]; then
      [[ ! -L "$sidecar" && -f "$sidecar" ]] || return 1
      printf '%s\t' "${suffix:-main}"
      stat -c '%s:%y:%i' -- "$sidecar" || return 1
    else
      printf '%s\tmissing\n' "${suffix:-main}"
    fi
  done
}

copy_sqlite_snapshot_once() {
  local source_db=$1 snapshot_db=$2 before_state after_state suffix sidecar snapshot_sidecar
  rm -f -- "$snapshot_db" "$snapshot_db-wal" "$snapshot_db-shm" "$snapshot_db-journal"
  before_state="$(sqlite_snapshot_state "$source_db")" || return 2
  cp -p -- "$source_db" "$snapshot_db" || return 2
  for suffix in -wal -shm -journal; do
    sidecar="${source_db}${suffix}"
    snapshot_sidecar="${snapshot_db}${suffix}"
    if [[ -e "$sidecar" ]]; then
      cp -p -- "$sidecar" "$snapshot_sidecar" || return 2
    else
      rm -f -- "$snapshot_sidecar"
    fi
  done
  after_state="$(sqlite_snapshot_state "$source_db")" || return 2
  [[ "$before_state" == "$after_state" ]] || return 3
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

sqlite_shell_quote() {
  local value=$1
  [[ "$value" != *$'\n'* ]] || return 1
  value=${value//\\/\\\\}
  value=${value//"/\\"}
  printf '"%s"' "$value"
}

canonicalize_path_allow_missing() {
  local path=$1 probe suffix base
  probe=$path
  suffix=""
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do
    base="$(basename -- "$probe")"
    suffix="/$base$suffix"
    probe="$(dirname -- "$probe")"
  done
  if [[ -e "$probe" ]]; then
    probe="$(cd -P -- "$probe" && pwd -P)"
    printf '%s%s\n' "$probe" "$suffix"
  else
    printf '%s\n' "$path"
  fi
}

is_under_configured_live_root() {
  local candidate=$1 live_root fs_root
  for live_root in "${includes[@]}"; do
    fs_root="$(map_to_fs_path "$live_root")"
    if [[ -e "$fs_root" ]]; then
      fs_root="$(cd -P -- "$fs_root" && pwd -P)"
    fi
    case "$candidate" in
      "$fs_root"|"$fs_root"/*) return 0 ;;
    esac
  done
  return 1
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
case "$SQLITE_SNAPSHOT_MAX_ATTEMPTS" in
  ''|*[!0-9]*) fail "HERMES_BACKUP_SQLITE_SNAPSHOT_ATTEMPTS must be a positive integer" ;;
esac
[[ "$SQLITE_SNAPSHOT_MAX_ATTEMPTS" -ge 1 ]] || fail "HERMES_BACKUP_SQLITE_SNAPSHOT_ATTEMPTS must be at least 1"

[[ -d "$STAGING_PARENT" || ! -e "$STAGING_PARENT" ]] || fail "staging parent is not a directory: $STAGING_PARENT"
STAGING_PARENT_CANONICAL="$(canonicalize_path_allow_missing "$STAGING_PARENT")"
if is_under_configured_live_root "$STAGING_PARENT_CANONICAL"; then
  fail "refusing staging root inside configured live include root: $STAGING_PARENT_CANONICAL"
fi
mkdir -p -- "$STAGING_PARENT"
chmod 700 "$STAGING_PARENT" 2>/dev/null || true
STAGING_PARENT="$(cd -- "$STAGING_PARENT" && pwd -P)"
STAGING_ROOT="$(mktemp -d "$STAGING_PARENT/stage-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
chmod 700 "$STAGING_ROOT" 2>/dev/null || true
SQLITE_SNAPSHOT_ROOT="$(mktemp -d "$STAGING_PARENT/sqlite-snapshots-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
chmod 700 "$SQLITE_SNAPSHOT_ROOT" 2>/dev/null || true

skipped_paths=()
sqlite_paths=()
sqlite_clean_paths=()
sqlite_wal_snapshot_paths=()
non_sqlite_candidates=()
missing_roots=()
include_roots_staged=0
rsync_files=0
sqlite_backups=0
sqlite_clean_backups=0
sqlite_wal_snapshot_backups=0
sqlite_snapshot_retries=0
sqlite_snapshot_failures=0

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
    snapshot_kind=clean
    if is_sqlite_wal_mode "$candidate" || sqlite_sidecar_exists "$candidate"; then
      snapshot_kind=wal
    fi
    snapshot_dir="$(mktemp -d "$SQLITE_SNAPSHOT_ROOT/db.XXXXXX")"
    snapshot_db="$snapshot_dir/$(basename -- "$candidate")"
    backup_dest_arg="$(sqlite_shell_quote "$dest_db")" || fail "SQLite backup destination contains unsupported newline for path: $live_candidate"
    attempt=1
    snapshot_ok=0
    while [[ "$attempt" -le "$SQLITE_SNAPSHOT_MAX_ATTEMPTS" ]]; do
      rm -f -- "$dest_db" "$dest_db-wal" "$dest_db-shm" "$dest_db-journal"
      snapshot_copy_status=0
      copy_sqlite_snapshot_once "$candidate" "$snapshot_db" || snapshot_copy_status=$?
      if [[ "$snapshot_copy_status" -eq 0 ]] && sqlite3 "$snapshot_db" ".backup main $backup_dest_arg" >/dev/null 2>&1; then
        if integrity_result="$(sqlite3 "$dest_db" 'PRAGMA integrity_check;' 2>&1)" && [[ "$integrity_result" == "ok" ]]; then
          snapshot_ok=1
          break
        fi
      fi
      rm -f -- "$dest_db" "$dest_db-wal" "$dest_db-shm" "$dest_db-journal"
      if [[ "$attempt" -lt "$SQLITE_SNAPSHOT_MAX_ATTEMPTS" ]]; then
        sqlite_snapshot_retries=$((sqlite_snapshot_retries + 1))
        log "sqlite path=$live_candidate status=snapshot-retry kind=$snapshot_kind attempt=$attempt max=$SQLITE_SNAPSHOT_MAX_ATTEMPTS"
      fi
      attempt=$((attempt + 1))
    done
    if [[ "$snapshot_ok" -ne 1 ]]; then
      rm -f -- "$dest_db" "$dest_db-wal" "$dest_db-shm" "$dest_db-journal"
      sqlite_snapshot_failures=$((sqlite_snapshot_failures + 1))
      fail "SQLite snapshot failed after $SQLITE_SNAPSHOT_MAX_ATTEMPTS attempt(s) for path: $live_candidate; database changed during snapshot, sidecars were unsafe, or snapshot was inconsistent. Retry later or temporarily stop the writer service, then run backup again."
    fi
    sqlite_paths+=("$live_candidate")
    sqlite_backups=$((sqlite_backups + 1))
    if [[ "$snapshot_kind" == "wal" ]]; then
      sqlite_wal_snapshot_paths+=("$live_candidate")
      sqlite_wal_snapshot_backups=$((sqlite_wal_snapshot_backups + 1))
      log "sqlite path=$live_candidate status=wal-snapshot-backed-up attempts=$attempt integrity=ok"
    else
      sqlite_clean_paths+=("$live_candidate")
      sqlite_clean_backups=$((sqlite_clean_backups + 1))
      log "sqlite path=$live_candidate status=clean-snapshot-backed-up attempts=$attempt integrity=ok"
    fi
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
  metadata_array "sqlite_clean_backups" "${sqlite_clean_paths[@]}"; printf ',\n'
  metadata_array "sqlite_wal_snapshot_backups" "${sqlite_wal_snapshot_paths[@]}"; printf ',\n'
  metadata_array "non_sqlite_candidates" "${non_sqlite_candidates[@]}"; printf ',\n'
  metadata_array "skipped_paths" "${skipped_paths[@]}"; printf ',\n'
  printf '  "counts": {"include_roots_staged": %s, "rsync_files": %s, "sqlite_backups": %s, "sqlite_clean_backups": %s, "sqlite_wal_snapshot_backups": %s, "sqlite_snapshot_retries": %s, "sqlite_snapshot_failures": %s}\n' "$include_roots_staged" "$rsync_files" "$sqlite_backups" "$sqlite_clean_backups" "$sqlite_wal_snapshot_backups" "$sqlite_snapshot_retries" "$sqlite_snapshot_failures"
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
