#!/usr/bin/env bash
# Bounded dry-run inventory for hermes-backup staging scope.
# Reads config/manifests as the single source of truth and prints only path/count/status output.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/inventory-dry-run.sh [--root PATH] [--manifest-dir PATH] [--max-examples N]

Summarizes configured backup include roots without reading or printing file
contents. The dry-run uses the same include/exclude manifest semantics as
scripts/stage.sh: paths matching exclude.patterns are reported as omitted with
bounded examples/counts instead of causing failure merely because rebuildable
cache/log/dependency classes exist under included roots.

Options:
  --root PATH          Map absolute VM paths under a fixture root for tests.
  --manifest-dir PATH  Read include.paths and exclude.patterns from PATH.
  --max-examples N     Maximum example omitted paths per matched exclude pattern
                       (default: 3, maximum: 100, use 0 for counts only).
  -h, --help           Show this help.

Exit status is non-zero only for invalid include roots, malformed/empty
manifests, unsafe option values, or filesystem traversal errors. Missing include
roots are summarized but are not failures, matching staging behavior.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST_DIR="$REPO_ROOT/config/manifests"
ROOT_PREFIX=""
MAX_EXAMPLES=3

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
    --max-examples)
      [[ $# -ge 2 ]] || fail "--max-examples requires a number"
      MAX_EXAMPLES=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$MAX_EXAMPLES" in
  ''|*[!0-9]*) fail "--max-examples must be a non-negative integer" ;;
esac
while [[ "$MAX_EXAMPLES" == 0* && "$MAX_EXAMPLES" != "0" ]]; do
  MAX_EXAMPLES=${MAX_EXAMPLES#0}
done
if [[ "${#MAX_EXAMPLES}" -gt 3 ]]; then
  fail "--max-examples must be between 0 and 100"
fi
MAX_EXAMPLES=$((10#$MAX_EXAMPLES))
if [[ "$MAX_EXAMPLES" -gt 100 ]]; then
  fail "--max-examples must be between 0 and 100"
fi

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

safe_output() {
  local value=$1
  value=${value//$'\n'/\\n}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
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

first_matching_exclude_pattern() {
  local live_path=$1 pattern
  for pattern in "${excludes[@]}"; do
    if match_exclude_pattern "$live_path" "$pattern"; then
      printf '%s\n' "$pattern"
      return 0
    fi
  done
  return 1
}

count_direct_children() {
  local fs_path=$1
  find "$fs_path" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]'
}

record_omitted_path() {
  local pattern=$1 live_path=$2 existing_count existing_examples safe_live_path
  existing_count=${omitted_counts[$pattern]:-0}
  omitted_counts[$pattern]=$((existing_count + 1))
  include_omitted=$((include_omitted + 1))
  total_omitted=$((total_omitted + 1))

  existing_examples=${omitted_example_counts[$pattern]:-0}
  if [[ "$existing_examples" -lt "$MAX_EXAMPLES" ]]; then
    safe_live_path="$(safe_output "$live_path")"
    if [[ -n "${omitted_examples[$pattern]:-}" ]]; then
      omitted_examples[$pattern]+=$'\n'
    fi
    omitted_examples[$pattern]+=$safe_live_path
    omitted_example_counts[$pattern]=$((existing_examples + 1))
  fi
}

walk_tree() {
  local fs_dir=$1 child live_path matched_pattern
  if [[ ! -r "$fs_dir" || ! -x "$fs_dir" ]]; then
    traversal_errors+=("$(fs_to_live_path "$fs_dir")")
    return
  fi
  for child in "$fs_dir"/*; do
    [[ -e "$child" || -L "$child" ]] || continue
    live_path="$(fs_to_live_path "$child")"
    include_entries=$((include_entries + 1))
    total_entries=$((total_entries + 1))

    if matched_pattern="$(first_matching_exclude_pattern "$live_path")"; then
      record_omitted_path "$matched_pattern" "$live_path"
      if [[ -d "$child" && ! -L "$child" ]]; then
        continue
      fi
    elif [[ -d "$child" && ! -L "$child" ]]; then
      include_dirs=$((include_dirs + 1))
      total_dirs=$((total_dirs + 1))
      walk_tree "$child"
    else
      include_files=$((include_files + 1))
      total_files=$((total_files + 1))
    fi
  done
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

shopt -s nullglob dotglob

declare -A omitted_counts=()
declare -A omitted_examples=()
declare -A omitted_example_counts=()
missing_roots=()
invalid_roots=()
traversal_errors=()
include_roots_present=0
total_entries=0
total_files=0
total_dirs=0
total_omitted=0

log "Hermes backup inventory dry-run"
log "manifest_dir=$MANIFEST_DIR"
[[ -n "$ROOT_PREFIX" ]] && log "root_prefix=$ROOT_PREFIX"
log "include_roots=${#includes[@]}"
log "exclude_patterns=${#excludes[@]}"
log "max_examples=$MAX_EXAMPLES"

for live_path in "${includes[@]}"; do
  fs_path="$(map_to_fs_path "$live_path")"
  if [[ -e "$fs_path" && ! -d "$fs_path" ]]; then
    invalid_roots+=("$live_path")
    log "include path=$(safe_output "$live_path") status=invalid-not-directory entries=0 files=0 dirs=0 omitted=0 direct_entries=0"
    continue
  fi
  if [[ ! -d "$fs_path" ]]; then
    missing_roots+=("$live_path")
    log "include path=$(safe_output "$live_path") status=missing entries=0 files=0 dirs=0 omitted=0 direct_entries=0"
    continue
  fi

  include_entries=0
  include_files=0
  include_dirs=0
  include_omitted=0
  direct_count=0
  if [[ ! -r "$fs_path" || ! -x "$fs_path" ]]; then
    traversal_errors+=("$live_path")
  else
    direct_count="$(count_direct_children "$fs_path")"
    walk_tree "$fs_path"
  fi
  include_roots_present=$((include_roots_present + 1))
  log "include path=$(safe_output "$live_path") status=present entries=$include_entries files=$include_files dirs=$include_dirs omitted=$include_omitted direct_entries=$direct_count"
done

matched_patterns=0
for pattern in "${excludes[@]}"; do
  count=${omitted_counts[$pattern]:-0}
  [[ "$count" -gt 0 ]] || continue
  matched_patterns=$((matched_patterns + 1))
  shown=${omitted_example_counts[$pattern]:-0}
  log "omitted pattern=$(safe_output "$pattern") count=$count examples_shown=$shown"
  if [[ "$shown" -gt 0 ]]; then
    while IFS= read -r example; do
      log "omitted-example pattern=$(safe_output "$pattern") path=$(safe_output "$example")"
    done <<<"${omitted_examples[$pattern]}"
  fi
done

log "summary include_roots_present=$include_roots_present missing_roots=${#missing_roots[@]} invalid_roots=${#invalid_roots[@]} traversal_errors=${#traversal_errors[@]} entries=$total_entries files=$total_files dirs=$total_dirs omitted=$total_omitted omitted_patterns=$matched_patterns"

traversal_examples_shown=0
for traversal_path in "${traversal_errors[@]}"; do
  [[ "$traversal_examples_shown" -lt "$MAX_EXAMPLES" ]] || break
  log "traversal-error path=$(safe_output "$traversal_path") status=unreadable"
  traversal_examples_shown=$((traversal_examples_shown + 1))
done
if [[ "${#traversal_errors[@]}" -gt 0 ]]; then
  log "traversal-error-summary count=${#traversal_errors[@]} examples_shown=$traversal_examples_shown"
fi

if [[ "${#invalid_roots[@]}" -gt 0 ]]; then
  fail "inventory dry-run found ${#invalid_roots[@]} invalid include root(s)"
fi
if [[ "${#traversal_errors[@]}" -gt 0 ]]; then
  fail "inventory dry-run found ${#traversal_errors[@]} unreadable include path(s)"
fi

log "Inventory dry-run passed: excluded classes were summarized as staging omissions."
log "No file contents, secrets, B2 keys, restic passwords, Telegram tokens, or backup archives were printed."
