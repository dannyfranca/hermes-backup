import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "inventory-dry-run.sh"
INCLUDE_MANIFEST = ROOT / "config" / "manifests" / "include.paths"
EXCLUDE_MANIFEST = ROOT / "config" / "manifests" / "exclude.patterns"

DUMMY_SECRET_VALUES = [
    "DUMMY_B2_KEY_ID_NOT_REAL",
    "DUMMY_B2_APPLICATION_KEY_NOT_REAL",
    "DUMMY_RESTIC_PASSWORD_NOT_REAL",
    "DUMMY_TELEGRAM_TOKEN_NOT_REAL",
    "RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT",
]


def make_fixture_root(tmp_path: Path) -> Path:
    root = tmp_path / "fixture-root"
    for path in [
        "/home/agent/.hermes/profiles/execution-coder/config.yaml",
        "/home/agent/shared/reports/status.html",
        "/home/agent/shared-assets/mermaid/mermaid.min.js",
        "/home/agent/.config/systemd/user/hermes-gateway.service",
        "/home/agent/.config/containers/systemd/home-stream.container",
    ]:
        target = root / path.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture file content that must never appear in dry-run output\n")
    return root


def run_inventory(root: Path, *extra_args):
    result = subprocess.run(
        ["bash", str(SCRIPT), "--root", str(root), *extra_args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    return result


def combined(result) -> str:
    return result.stdout + result.stderr


def test_manifest_files_exist_and_cover_required_scope():
    assert INCLUDE_MANIFEST.is_file()
    assert EXCLUDE_MANIFEST.is_file()

    includes = INCLUDE_MANIFEST.read_text().splitlines()
    for required in [
        "/home/agent/.hermes",
        "/home/agent/shared",
        "/home/agent/shared-assets",
        "/home/agent/.config/systemd/user",
        "/home/agent/.config/containers/systemd",
    ]:
        assert required in includes

    excludes = EXCLUDE_MANIFEST.read_text().lower()
    for required_fragment in [
        "honcho",
        "/home/agent/git/**",
        "worktrees",
        "node_modules",
        ".venv",
        "__pycache__",
        ".cache",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        "restic-cache",
        "dist",
        "build",
        "models",
        "media",
        "/var/lib/vz/**",
        "/etc/pve/**",
        "staging",
        "logs",
        "restic-repo",
        "*.restic",
        "archives",
        "backups",
        "*.db-backup",
        "*.sqlite-backup",
        "*.sqlite3-backup",
        "*.tar",
        "*.7z",
    ]:
        assert required_fragment in excludes


def test_inventory_dry_run_has_valid_bash_syntax():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=ROOT, text=True, capture_output=True, check=False)
    assert result.returncode == 0, combined(result)


def test_inventory_dry_run_reports_only_paths_counts_and_status(tmp_path):
    root = make_fixture_root(tmp_path)
    secret_file = root / "home" / "agent" / ".hermes" / "profiles" / "execution-coder" / "secret.env"
    secret_file.write_text("\n".join(DUMMY_SECRET_VALUES))

    result = run_inventory(root)
    output = combined(result)

    assert result.returncode == 0, output
    assert "Hermes backup inventory dry-run" in output
    assert "include_roots=5" in output
    assert "exclude_patterns=" in output
    assert "include path=/home/agent/.hermes status=present entries=1" in output
    assert "include path=/home/agent/shared status=present entries=1" in output
    assert "Inventory dry-run passed" in output
    assert "fixture file content" not in output
    for secret in DUMMY_SECRET_VALUES:
        assert secret not in output


def test_inventory_dry_run_fails_for_representative_forbidden_classes(tmp_path):
    root = make_fixture_root(tmp_path)
    forbidden_paths = [
        "/home/agent/.hermes/honcho/config.json",
        "/home/agent/shared/project/.git/config",
        "/home/agent/shared/project/worktrees/t_123/file.txt",
        "/home/agent/shared/app/node_modules/pkg/index.js",
        "/home/agent/shared/app/.venv/bin/python",
        "/home/agent/shared/app/__pycache__/module.pyc",
        "/home/agent/shared/app/.cache/download.bin",
        "/home/agent/shared/app/.mypy_cache/module.meta.json",
        "/home/agent/shared/app/.pytest_cache/v/cache/nodeids",
        "/home/agent/shared/app/.ruff_cache/0.14.0/file",
        "/home/agent/shared/app/restic-cache/chunk",
        "/home/agent/shared/app/dist/bundle.js",
        "/home/agent/shared/app/build/output.o",
        "/home/agent/shared/logs/run.log",
        "/home/agent/shared/staging/snapshot/file.txt",
        "/home/agent/shared/models/model.bin",
        "/home/agent/shared/media/video.mp4",
        "/home/agent/shared/runtime/restic-repo/config",
        "/home/agent/shared/runtime/repo.restic/config",
        "/home/agent/shared/archives/hermes.tar",
        "/home/agent/shared/archives/hermes.tar.xz",
        "/home/agent/shared/backups/snapshot.db-backup",
        "/home/agent/shared/backups/snapshot.sqlite-backup",
        "/home/agent/shared/backups/snapshot.sqlite3-backup",
        "/home/agent/shared/archives/snapshot.7z",
        "/home/agent/shared/run.log",
    ]
    for path in forbidden_paths:
        target = root / path.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT")

    result = run_inventory(root)
    output = combined(result)

    assert result.returncode != 0
    assert "forbidden path=/home/agent/.hermes/honcho/config.json" in output
    assert "forbidden path=/home/agent/shared/app/node_modules/pkg/index.js" in output
    assert "forbidden path=/home/agent/shared/app/.mypy_cache/module.meta.json" in output
    assert "forbidden path=/home/agent/shared/app/restic-cache/chunk" in output
    assert "forbidden path=/home/agent/shared/logs/run.log" in output
    assert "forbidden path=/home/agent/shared/staging/snapshot/file.txt" in output
    assert "forbidden path=/home/agent/shared/models/model.bin" in output
    assert "forbidden path=/home/agent/shared/runtime/repo.restic/config" in output
    assert "forbidden path=/home/agent/shared/archives/hermes.tar" in output
    assert "forbidden path=/home/agent/shared/archives/hermes.tar.xz" in output
    assert "forbidden path=/home/agent/shared/backups/snapshot.db-backup" in output
    assert "forbidden path=/home/agent/shared/archives/snapshot.7z" in output
    assert "forbidden path=/home/agent/shared/run.log" in output
    assert "inventory dry-run found" in output
    assert "RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT" not in output


def test_inventory_dry_run_uses_manifest_source_of_truth(tmp_path):
    root = make_fixture_root(tmp_path)
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text("/home/agent/shared\n")
    (manifest_dir / "exclude.patterns").write_text("/home/agent/shared/custom-forbidden/**\n")
    forbidden = root / "home" / "agent" / "shared" / "custom-forbidden" / "x.txt"
    forbidden.parent.mkdir(parents=True)
    forbidden.write_text("contents must not print")

    result = run_inventory(root, "--manifest-dir", str(manifest_dir))
    output = combined(result)

    assert result.returncode != 0
    assert "include_roots=1" in output
    assert "exclude_patterns=1" in output
    assert "forbidden path=/home/agent/shared/custom-forbidden/x.txt" in output
    assert "contents must not print" not in output


def test_inventory_script_is_executable():
    assert SCRIPT.stat().st_mode & stat.S_IXUSR
