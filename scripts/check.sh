#!/usr/bin/env bash
# Offline foundation verification harness. Safe for clean clones: no network,
# no live backup/check/restore, no timer enablement, and no secret prompts.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/check.sh [--pytest-args ...]

Runs the offline bootstrap/config/staging/backup/restore verification harness:
  1. Bash syntax checks for install.sh and scripts/*.sh.
  2. A tracked-ignored-file guard so local-only secret/output files cannot become committed.
  3. Pytest coverage for preflight, config writer, install skeleton, inventory, SQLite-safe staging, restic backup/retention, restic check, safe restore, repo safety, and harness contracts.

This command does not call B2, restic repositories, Telegram, Hermes cron, or systemd enable/start.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--pytest-args" ]]; then
  shift
fi

cd "$REPO_ROOT"

log "Hermes backup foundation verification (offline)"
log "Step 1/3: shell syntax"
for shell_script in install.sh scripts/*.sh; do
  bash -n "$shell_script"
done

log "Step 2/3: tracked ignored-file guard"
tracked_ignored_file="$(mktemp -t hermes-backup-tracked-ignored.XXXXXX)"
cleanup() { rm -f "$tracked_ignored_file"; }
trap cleanup EXIT
git ls-files -ci --exclude-standard >"$tracked_ignored_file"
if [[ -s "$tracked_ignored_file" ]]; then
  cat "$tracked_ignored_file" >&2
  fail "tracked files match local-secret/runtime-output ignore rules"
fi

log "Step 3/3: pytest bootstrap/config harness"
PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS= PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python3 -m pytest -q -p no:cacheprovider "$@"

log "Foundation verification passed."
log "No live backup/check/restore, network validation, timer enablement, or Hermes cron action was run."
