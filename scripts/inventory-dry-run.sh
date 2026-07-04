#!/usr/bin/env bash
# Dry-run inventory for hermes-backup staging scope.
# Reads config/manifests as the single source of truth and prints only path/count/status output.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/inventory-dry-run.sh [--root PATH] [--manifest-dir PATH]

Enumerates configured backup include roots without reading or printing file contents.
Fails if any configured include tree would contain a forbidden class from the
exclude manifest. --root maps absolute VM paths under a fixture root for tests.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST_DIR="$REPO_ROOT/config/manifests"
ROOT_PREFIX=""

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
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

INCLUDE_MANIFEST="$MANIFEST_DIR/include.paths"
EXCLUDE_MANIFEST="$MANIFEST_DIR/exclude.patterns"
[[ -f "$INCLUDE_MANIFEST" ]] || fail "include manifest not found: $INCLUDE_MANIFEST"
[[ -f "$EXCLUDE_MANIFEST" ]] || fail "exclude manifest not found: $EXCLUDE_MANIFEST"

if [[ -n "$ROOT_PREFIX" ]]; then
  case "$ROOT_PREFIX" in /*) ;; *) fail "--root must be an absolute path" ;; esac
  [[ -d "$ROOT_PREFIX" ]] || fail "--root must be an existing directory: $ROOT_PREFIX"
  ROOT_PREFIX="$(cd -- "$ROOT_PREFIX" && pwd -P)"
fi

strip_comment() {
  local line=$1
  line=${line%%#*}
  # Trim leading/trailing whitespace without external tools.
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

match_exclude_pattern() {
  local live_path=$1 pattern=$2 base
  if [[ "$pattern" == *'/**' ]]; then
    base=${pattern%/**}
    [[ "$live_path" == $base || "$live_path" == $base/* ]]
    return
  fi
  [[ "$live_path" == $pattern ]]
}

count_direct_children() {
  local fs_path=$1
  find "$fs_path" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]'
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

log "Hermes backup inventory dry-run"
log "manifest_dir=$MANIFEST_DIR"
[[ -n "$ROOT_PREFIX" ]] && log "root_prefix=$ROOT_PREFIX"
log "include_roots=${#includes[@]}"
log "exclude_patterns=${#excludes[@]}"

violations=0
for live_path in "${includes[@]}"; do
  fs_path="$(map_to_fs_path "$live_path")"
  if [[ -e "$fs_path" && ! -d "$fs_path" ]]; then
    log "include path=$live_path status=invalid-not-directory entries=0"
    violations=$((violations + 1))
    continue
  fi
  if [[ ! -d "$fs_path" ]]; then
    log "include path=$live_path status=missing entries=0"
    continue
  fi

  child_count="$(count_direct_children "$fs_path")"
  log "include path=$live_path status=present entries=$child_count"

  while IFS= read -r found_fs_path || [[ -n "$found_fs_path" ]]; do
    if [[ -n "$ROOT_PREFIX" ]]; then
      case "$found_fs_path" in
        "$ROOT_PREFIX"/*) found_live_path="/${found_fs_path#"$ROOT_PREFIX"/}" ;;
        "$ROOT_PREFIX") found_live_path="/" ;;
        *) found_live_path="$found_fs_path" ;;
      esac
    else
      found_live_path="$found_fs_path"
    fi
    for pattern in "${excludes[@]}"; do
      if match_exclude_pattern "$found_live_path" "$pattern"; then
        log "forbidden path=$found_live_path pattern=$pattern"
        violations=$((violations + 1))
        break
      fi
    done
  done < <(find "$fs_path" -mindepth 0 -print 2>/dev/null)
done

if [[ "$violations" -gt 0 ]]; then
  fail "inventory dry-run found $violations forbidden path violation(s)"
fi

log "Inventory dry-run passed: no forbidden excluded classes found."
log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
