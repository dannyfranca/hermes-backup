import os
import re
import stat
import subprocess
from pathlib import Path

from test_stage import fixture_root as stage_fixture_root
from test_stage import run_stage, staging_root_from

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


def write(root: Path, live_path: str, body: str = "fixture\n") -> Path:
    target = root / live_path.lstrip("/")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body)
    return target


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


def assert_no_dummy_secrets(output: str) -> None:
    assert "fixture file content" not in output
    for secret in DUMMY_SECRET_VALUES:
        assert secret not in output


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
        "go/pkg/mod",
        "pnpm/store",
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
    assert "max_examples=3" in output
    assert "include path=/home/agent/.hermes status=present" in output
    assert "include path=/home/agent/shared status=present" in output
    assert "summary include_roots_present=5 missing_roots=0 invalid_roots=0" in output
    assert "Inventory dry-run passed" in output
    assert_no_dummy_secrets(output)


def test_inventory_dry_run_summarizes_representative_omissions_without_failing(tmp_path):
    root = make_fixture_root(tmp_path)
    omitted_paths = [
        "/home/agent/.hermes/honcho/config.json",
        "/home/agent/shared/project/.git/config",
        "/home/agent/shared/project/worktrees/t_123/file.txt",
        "/home/agent/shared/app/node_modules/pkg/index.js",
        "/home/agent/.hermes/home/go/pkg/mod/github.com/example/module/cache.go",
        "/home/agent/.hermes/profiles/execution-coder/home/go/pkg/mod/github.com/example/module/cache.go",
        "/home/agent/.hermes/profiles/execution-coder/home/.local/share/pnpm/store/v3/files/aa/cache",
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
    for path in omitted_paths:
        write(root, path, "RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT")

    result = run_inventory(root)
    output = combined(result)

    assert result.returncode == 0, output
    assert "omitted pattern=/home/agent/**/node_modules/**" in output
    assert "omitted pattern=/home/agent/.hermes/home/go/pkg/mod/**" in output
    assert "omitted pattern=/home/agent/.hermes/profiles/*/home/go/pkg/mod/**" in output
    assert "omitted pattern=/home/agent/.hermes/profiles/*/home/.local/share/pnpm/store/**" in output
    assert "omitted pattern=/home/agent/**/logs/**" in output
    assert "omitted pattern=/home/agent/**/archives/**" in output
    assert "omitted pattern=/home/agent/**/*.log" in output
    assert "omitted-example pattern=/home/agent/**/node_modules/** path=/home/agent/shared/app/node_modules" in output
    assert "omitted-example pattern=/home/agent/.hermes/home/go/pkg/mod/** path=/home/agent/.hermes/home/go/pkg/mod" in output
    assert "summary include_roots_present=5 missing_roots=0 invalid_roots=0" in output
    assert re.search(r"omitted=\d+", output)
    assert_no_dummy_secrets(output)


def test_inventory_dry_run_output_stays_bounded_for_many_excluded_files(tmp_path):
    root = make_fixture_root(tmp_path)
    for index in range(500):
        write(root, f"/home/agent/shared/app/node_modules/pkg/generated-{index}.js")
        write(root, f"/home/agent/shared/app/.cache/blob-{index}.bin")
        write(root, f"/home/agent/shared/logs/run-{index}.log")

    result = run_inventory(root, "--max-examples", "2")
    output = combined(result)

    assert result.returncode == 0, output
    assert "max_examples=2" in output
    assert "omitted pattern=/home/agent/**/node_modules/** count=1 examples_shown=1" in output
    assert "omitted pattern=/home/agent/**/.cache/** count=1 examples_shown=1" in output
    assert "omitted pattern=/home/agent/**/logs/** count=1 examples_shown=1" in output
    assert len(output.splitlines()) < 40
    assert len(output) < 6000


def test_inventory_dry_run_uses_manifest_source_of_truth(tmp_path):
    root = make_fixture_root(tmp_path)
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text("/home/agent/shared\n")
    (manifest_dir / "exclude.patterns").write_text("/home/agent/shared/custom-forbidden/**\n")
    forbidden = write(root, "/home/agent/shared/custom-forbidden/x.txt", "contents must not print")

    result = run_inventory(root, "--manifest-dir", str(manifest_dir))
    output = combined(result)

    assert result.returncode == 0, output
    assert "include_roots=1" in output
    assert "exclude_patterns=1" in output
    assert "omitted pattern=/home/agent/shared/custom-forbidden/** count=1 examples_shown=1" in output
    assert "omitted-example pattern=/home/agent/shared/custom-forbidden/** path=/home/agent/shared/custom-forbidden" in output
    assert forbidden.read_text() not in output


def test_inventory_omissions_align_with_stage_final_payload_absence(tmp_path):
    root = stage_fixture_root(tmp_path)

    inventory = run_inventory(root, "--max-examples", "5")
    inventory_output = combined(inventory)
    assert inventory.returncode == 0, inventory_output

    staged = run_stage(tmp_path, "--keep", root=root)
    stage_output = combined(staged)
    assert staged.returncode == 0, stage_output
    staging_root = staging_root_from(stage_output)

    representatives = [
        (
            "/home/agent/.hermes/home/go/pkg/mod/**",
            "/home/agent/.hermes/home/go/pkg/mod",
            "home/agent/.hermes/home/go/pkg/mod/github.com/example/module/cache.go",
        ),
        (
            "/home/agent/.hermes/profiles/*/home/.local/share/pnpm/store/**",
            "/home/agent/.hermes/profiles/execution-coder/home/.local/share/pnpm/store",
            "home/agent/.hermes/profiles/execution-coder/home/.local/share/pnpm/store/v3/files/aa/cache",
        ),
        (
            "/home/agent/**/logs/**",
            "/home/agent/shared/logs",
            "home/agent/shared/logs/run.log",
        ),
        (
            "/home/agent/**/archives/**",
            "/home/agent/shared/archives",
            "home/agent/shared/archives/hermes.tar",
        ),
    ]
    for pattern, inventory_example, staged_relative in representatives:
        assert f"omitted pattern={pattern}" in inventory_output
        assert f"path={inventory_example}" in inventory_output
        assert not (staging_root / staged_relative).exists(), staged_relative

    assert_no_dummy_secrets(inventory_output)
    assert_no_dummy_secrets(stage_output)


def test_inventory_dry_run_fails_for_invalid_include_root(tmp_path):
    root = make_fixture_root(tmp_path)
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text("/home/agent/shared/reports/status.html\n")
    (manifest_dir / "exclude.patterns").write_text("/home/agent/shared/cache/**\n")

    result = run_inventory(root, "--manifest-dir", str(manifest_dir))
    output = combined(result)

    assert result.returncode != 0
    assert "status=invalid-not-directory" in output
    assert "invalid include root" in output


def test_inventory_dry_run_fails_for_unreadable_subtree_with_bounded_examples(tmp_path):
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        return
    root = make_fixture_root(tmp_path)
    unreadable_dirs = []
    for index in range(5):
        unreadable = root / "home" / "agent" / "shared" / f"unreadable-{index}"
        unreadable.mkdir(parents=True)
        unreadable.chmod(0)
        unreadable_dirs.append(unreadable)
    try:
        result = run_inventory(root, "--max-examples", "2")
        output = combined(result)
    finally:
        for unreadable in unreadable_dirs:
            unreadable.chmod(0o700)

    assert result.returncode != 0
    assert output.count("traversal-error path=") == 2
    assert "traversal-error path=/home/agent/shared/unreadable-0 status=unreadable" in output
    assert "traversal-error-summary count=5 examples_shown=2" in output
    assert "unreadable include path" in output


def test_inventory_dry_run_treats_leading_zero_max_examples_as_decimal(tmp_path):
    root = make_fixture_root(tmp_path)
    for index in range(3):
        write(root, f"/home/agent/shared/cache-{index}.log")

    result = run_inventory(root, "--max-examples", "08")
    output = combined(result)

    assert result.returncode == 0, output
    assert "max_examples=8" in output
    assert "bash:" not in output.lower()


def test_inventory_dry_run_rejects_overflowing_max_examples(tmp_path):
    root = make_fixture_root(tmp_path)

    result = run_inventory(root, "--max-examples", "999999999999999999999999999999999")
    output = combined(result)

    assert result.returncode != 0
    assert "--max-examples must be between 0 and 100" in output
    assert "bash:" not in output.lower()


def test_inventory_dry_run_bounds_newline_containing_omitted_examples(tmp_path):
    root = make_fixture_root(tmp_path)
    write(root, "/home/agent/shared/app/weird\nname.log")

    result = run_inventory(root, "--max-examples", "1")
    output = combined(result)

    assert result.returncode == 0, output
    assert output.count("omitted-example pattern=/home/agent/**/*.log") == 1
    assert "path=/home/agent/shared/app/weird\\nname.log" in output
    assert "weird\nname.log" not in output


def test_inventory_script_is_executable():
    assert SCRIPT.stat().st_mode & stat.S_IXUSR
