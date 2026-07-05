#!/usr/bin/env bash
# Offline foundation verification harness. Safe for clean clones: no network,
# no live backup/check/restore, no timer enablement, and no secret prompts.
{ set +x; } 2>/dev/null || true
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/check.sh [--pytest-args ...]

Runs the offline bootstrap/config/staging/backup/restore/promote/timer verification harness:
  1. Bash syntax checks for install.sh and scripts/*.sh.
  2. A tracked-ignored-file guard so local-only secret/output files cannot become committed.
  3. `git diff --check` so the current review diff cannot carry whitespace errors.
  4. Pytest coverage for preflight, config writer, install/systemd timer rendering, inventory, SQLite-safe staging, restic backup/retention, restic check, safe restore, explicit promote, repo safety, and harness contracts.

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
log "Step 1/4: shell syntax"
for shell_script in install.sh scripts/*.sh lib/hermes-backup/*.sh; do
  bash -n "$shell_script"
done

log "Step 2/4: tracked ignored-file guard"
tracked_ignored_file="$(mktemp -t hermes-backup-tracked-ignored.XXXXXX)"
cleanup() { rm -f "$tracked_ignored_file"; }
trap cleanup EXIT
git ls-files -ci --exclude-standard >"$tracked_ignored_file"
if [[ -s "$tracked_ignored_file" ]]; then
  cat "$tracked_ignored_file" >&2
  fail "tracked files match local-secret/runtime-output ignore rules"
fi

log "Step 3/4: diff whitespace/secret-shape check"
python3 - <<'PY_DIFF_SAFETY'
import re
import subprocess
from pathlib import Path

secret_patterns = {
    'telegram_bot_token': re.compile(rb'\b\d{8,10}:[A-Za-z0-9_-]{35,}\b'),
    'private_key': re.compile(rb'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
    'b2_key_like': re.compile(rb'\bK[0-9A-Za-z]{30,}\b'),
}
allowed_markers = (b'DUMMY_', b'PLACEHOLDER_', b'EXAMPLE_', b'NOT_REAL')
bad = []

def git_lines(*args):
    return subprocess.check_output(['git', *args], text=True).splitlines()

def scan_bytes(label, data):
    if b'\0' in data:
        return
    for number, line in enumerate(data.splitlines(), 1):
        if line.endswith((b' ', b'\t')):
            bad.append(f'{label}:{number}: trailing whitespace')
        leading = line[: len(line) - len(line.lstrip(b' \t'))]
        if b' \t' in leading:
            bad.append(f'{label}:{number}: space before tab in indent')
        if line.startswith((b'<<<<<<< ', b'=======', b'>>>>>>> ')):
            bad.append(f'{label}:{number}: conflict marker')
    if data.endswith(b'\n\n'):
        bad.append(f'{label}: new blank line at EOF')
    for pattern_name, pattern in secret_patterns.items():
        for match in pattern.finditer(data):
            value = match.group(0)
            if any(marker in value for marker in allowed_markers):
                continue
            bad.append(f'{label}: secret-like content: {pattern_name}')

worktree_files = sorted(set(git_lines('diff', '--name-only') + git_lines('ls-files', '--others', '--exclude-standard')))
for name in worktree_files:
    path = Path(name)
    if path.is_file():
        scan_bytes(name, path.read_bytes())

for name in sorted(set(git_lines('diff', '--cached', '--name-only'))):
    try:
        data = subprocess.check_output(['git', 'show', f':{name}'])
    except subprocess.CalledProcessError:
        continue
    scan_bytes(f'staged:{name}', data)

if bad:
    print('\n'.join(bad))
    raise SystemExit(1)
PY_DIFF_SAFETY
git diff --check
git diff --cached --check

log "Step 4/4: pytest bootstrap/config harness"
PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS= PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python3 -m pytest -q -p no:cacheprovider "$@"

log "Foundation verification passed."
log "No live backup/check/restore, network validation, timer enablement, or Hermes cron action was run."
