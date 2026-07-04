import json
import os
import re
import sqlite3
import stat
import subprocess
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "stage.sh"
DUMMY_SECRETS = [
    "DUMMY_STAGE_B2_APPLICATION_KEY_NOT_REAL",
    "DUMMY_STAGE_RESTIC_PASSWORD_NOT_REAL",
    "DUMMY_STAGE_TELEGRAM_TOKEN_NOT_REAL",
    "RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT",
]


def combined(result):
    return result.stdout + result.stderr

def make_executable(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body).strip() + "\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def fake_bin(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    make_executable(
        bin_dir / "sqlite3",
        r'''
        #!/usr/bin/env python3
        import re, sqlite3, sys
        from pathlib import Path
        argv = sys.argv[1:]
        if argv and argv[0] == "-readonly": argv = argv[1:]
        db = Path(argv[0]); command = argv[1] if len(argv) > 1 else ""
        if command.startswith(".backup"):
            match = re.search(r"'([^']+)'", command)
            if not match: sys.exit(2)
            dest = Path(match.group(1)); dest.parent.mkdir(parents=True, exist_ok=True)
            try:
                src = sqlite3.connect(f"file:{db}?mode=ro", uri=True); dst = sqlite3.connect(dest)
                with dst: src.backup(dst)
                src.close(); dst.close()
            except sqlite3.DatabaseError:
                sys.exit(1)
            sys.exit(0)
        if command.lower().strip() == "pragma integrity_check;":
            conn = sqlite3.connect(db); print(conn.execute("PRAGMA integrity_check").fetchone()[0]); conn.close(); sys.exit(0)
        sys.exit(2)
        ''',
    )
    make_executable(
        bin_dir / "rsync",
        r'''
        #!/usr/bin/env python3
        import fnmatch, os, shutil, sys
        from pathlib import Path
        args = sys.argv[1:]
        filters = []
        for i, a in enumerate(args[:-1]):
            if a == "--filter" and args[i + 1].startswith("- "): filters.append(args[i + 1][2:])
            if a == "--exclude": filters.append(args[i + 1])
        cleaned, skip = [], False
        for arg in args:
            if skip: skip = False; continue
            if arg in {"--filter", "--exclude"}: skip = True; continue
            if arg.startswith("--filter=") or arg.startswith("--exclude=") or arg.startswith("-"): continue
            cleaned.append(arg)
        src, dest = Path(cleaned[-2].rstrip("/")), Path(cleaned[-1])
        def filtered(live):
            bare = live.lstrip("/"); name = Path(bare).name
            for pattern in filters:
                stripped = pattern.lstrip("/")
                if stripped.endswith("/**") and (bare == stripped[:-3] or bare.startswith(stripped[:-3] + "/")): return True
                if fnmatch.fnmatch(live, pattern) or fnmatch.fnmatch(bare, stripped) or fnmatch.fnmatch(name, pattern): return True
            return False
        for root, dirs, files in os.walk(src):
            root_path = Path(root); rel_dir = root_path if not root_path.is_absolute() else root_path.relative_to(Path.cwd())
            dirs[:] = [d for d in dirs if not filtered("/" + (rel_dir / d).as_posix() + "/")]
            (dest / rel_dir).mkdir(parents=True, exist_ok=True)
            for name in files:
                source = root_path / name; rel = source if not source.is_absolute() else source.relative_to(Path.cwd())
                if filtered("/" + rel.as_posix()): continue
                target = dest / rel; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
                print(f">f++++++++ {rel.as_posix()}")
        ''',
    )
    return bin_dir

def write(root: Path, live_path: str, body: str = "fixture\n") -> Path:
    target = root / live_path.lstrip("/")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body)
    return target


def fixture_root(tmp_path: Path) -> Path:
    root = tmp_path / "fixture-root"
    for path in [
        "/home/agent/.hermes/profiles/execution-coder/config.yaml",
        "/home/agent/shared/reports/status.html",
        "/home/agent/shared-assets/mermaid/mermaid.min.js",
        "/home/agent/.config/systemd/user/hermes-gateway.service",
        "/home/agent/.config/containers/systemd/home-stream.container",
    ]:
        write(root, path)
    db = root / "home/agent/.hermes/kanban.db"
    conn = sqlite3.connect(db)
    conn.execute("create table tasks(id text primary key, title text)")
    conn.execute("insert into tasks values ('t_fixture', 'SQLite fixture')")
    conn.commit(); conn.close()
    write(root, "/home/agent/.hermes/profiles/execution-coder/secret.env", "\n".join(DUMMY_SECRETS))
    for path in [
        "/home/agent/.hermes/honcho/config.json",
        "/home/agent/shared/project/.git/config",
        "/home/agent/shared/app/node_modules/pkg/index.js",
        "/home/agent/shared/app/.venv/bin/python",
        "/home/agent/shared/app/.cache/download.bin",
        "/home/agent/shared/logs/run.log",
        "/home/agent/shared/staging/snapshot/file.txt",
        "/home/agent/shared/models/model.bin",
        "/home/agent/shared/media/video.mp4",
        "/home/agent/shared/archives/hermes.tar",
        "/home/agent/shared/backups/snapshot.sqlite-backup",
    ]:
        write(root, path, "RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT")
    return root


def run_stage(tmp_path: Path, *args, root: Path):
    env = os.environ.copy()
    env.update(PATH=f"{fake_bin(tmp_path)}{os.pathsep}{os.environ.get('PATH', '')}", HOME=str(tmp_path / "home" / "agent"))
    return subprocess.run(
        ["bash", str(SCRIPT), "--root", str(root), "--staging-parent", str(tmp_path / "state/hermes-backup/staging"), *args],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False,
    )


def staging_root_from(output: str) -> Path:
    match = re.search(r"^staging_root=(.+)$", output, re.MULTILINE)
    assert match, output
    return Path(match.group(1))


def assert_no_secrets(output: str) -> None:
    for value in DUMMY_SECRETS:
        assert value not in output


def sidecar_state(db: Path) -> dict[str, tuple[int, int, int] | None]:
    state = {}
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = db.with_name(db.name + suffix)
        if sidecar.exists():
            stat_result = sidecar.stat()
            state[suffix] = (stat_result.st_size, stat_result.st_mtime_ns, stat_result.st_mode)
        else:
            state[suffix] = None
    return state


def test_stage_has_valid_bash_syntax_and_is_executable():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=ROOT, text=True, capture_output=True, check=False)
    assert result.returncode == 0, combined(result)
    assert SCRIPT.stat().st_mode & stat.S_IXUSR


def test_stage_keep_preserves_structure_sqlite_backup_metadata_and_excludes(tmp_path):
    result = run_stage(tmp_path, "--keep", root=fixture_root(tmp_path))
    output = combined(result)
    assert result.returncode == 0, output
    assert_no_secrets(output)
    staging_root = staging_root_from(output)
    for relative in [
        "home/agent/.hermes/profiles/execution-coder/config.yaml",
        "home/agent/shared/reports/status.html",
        "home/agent/shared-assets/mermaid/mermaid.min.js",
        "home/agent/.config/systemd/user/hermes-gateway.service",
        "home/agent/.config/containers/systemd/home-stream.container",
    ]:
        assert (staging_root / relative).is_file()
    staged_db = staging_root / "home/agent/.hermes/kanban.db"
    conn = sqlite3.connect(staged_db)
    assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert conn.execute("select title from tasks where id='t_fixture'").fetchone()[0] == "SQLite fixture"
    conn.close()
    for relative in ["home/agent/.hermes/honcho/config.json", "home/agent/shared/project/.git/config", "home/agent/shared/app/node_modules/pkg/index.js", "home/agent/shared/logs/run.log", "home/agent/shared/archives/hermes.tar", "home/agent/shared/backups/snapshot.sqlite-backup"]:
        assert not (staging_root / relative).exists(), relative
    metadata = json.loads((staging_root / "staging-metadata.json").read_text())
    assert metadata["include_roots"][:2] == ["/home/agent/.hermes", "/home/agent/shared"]
    assert metadata["sqlite_backups"] == ["/home/agent/.hermes/kanban.db"]
    assert metadata["counts"]["sqlite_backups"] == 1


def test_stage_default_cleanup_removes_successful_transient_staging(tmp_path):
    result = run_stage(tmp_path, root=fixture_root(tmp_path))
    output = combined(result)
    assert result.returncode == 0, output
    staging_root = staging_root_from(output)
    assert not staging_root.exists()
    assert f"cleanup=removed staging_root={staging_root}" in output
    assert_no_secrets(output)


def test_stage_refuses_wal_mode_sqlite_without_source_sidecar_effects(tmp_path):
    root = fixture_root(tmp_path)
    db = root / "home/agent/.hermes/kanban.db"
    db.unlink()
    conn = sqlite3.connect(db)
    assert conn.execute("PRAGMA journal_mode=WAL").fetchone()[0].lower() == "wal"
    conn.execute("create table tasks(id text primary key, title text)")
    conn.execute("insert into tasks values ('t_wal', 'WAL fixture')")
    conn.commit()
    conn.close()
    for suffix in ("-wal", "-shm", "-journal"):
        db.with_name(db.name + suffix).unlink(missing_ok=True)
    assert db.read_bytes()[18:20] == b"\x02\x02"
    before = sidecar_state(db)

    result = run_stage(tmp_path, "--keep", root=root)
    output = combined(result)

    assert result.returncode != 0
    assert "refusing to open WAL-mode SQLite source without quiesce/snapshot" in output
    assert "/home/agent/.hermes/kanban.db" in output
    assert sidecar_state(db) == before == {"-wal": None, "-shm": None, "-journal": None}
    assert "sqlite path=/home/agent/.hermes/kanban.db status=backed-up" not in output
    assert_no_secrets(output)


def test_stage_consumes_custom_manifests_as_source_of_truth(tmp_path):
    root = fixture_root(tmp_path)
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text("/home/agent/shared\n")
    (manifest_dir / "exclude.patterns").write_text("/home/agent/shared/custom-forbidden/**\n")
    write(root, "/home/agent/shared/custom-forbidden/x.txt", "contents must not print")
    result = run_stage(tmp_path, "--manifest-dir", str(manifest_dir), "--keep", root=root)
    output = combined(result)
    assert result.returncode == 0, output
    assert "include_roots=1" in output and "contents must not print" not in output
    staging_root = staging_root_from(output)
    assert (staging_root / "home/agent/shared/reports/status.html").is_file()
    assert not (staging_root / "home/agent/.hermes").exists()
    assert not (staging_root / "home/agent/shared/custom-forbidden/x.txt").exists()
    assert json.loads((staging_root / "staging-metadata.json").read_text())["include_roots"] == ["/home/agent/shared"]


def test_stage_failure_reports_nonzero_without_secret_values(tmp_path):
    parent = tmp_path / "not-a-directory"; parent.write_text("not a directory")
    env = os.environ.copy(); env.update(PATH=f"{fake_bin(tmp_path)}{os.pathsep}{os.environ.get('PATH', '')}", HOME=str(tmp_path / "home"))
    result = subprocess.run(["bash", str(SCRIPT), "--root", str(fixture_root(tmp_path)), "--staging-parent", str(parent)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    assert result.returncode != 0
    assert "not a directory" in combined(result).lower()
    assert_no_secrets(combined(result))
