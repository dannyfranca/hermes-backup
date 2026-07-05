import os
import shlex
import sqlite3
import stat
import subprocess
from pathlib import Path

from test_stage import fake_bin, fixture_root, make_executable

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "backup.sh"

DUMMY_ENV = {
    "B2_ACCOUNT_ID": "DUMMY_BACKUP_B2_KEY_ID_NOT_REAL",
    "B2_ACCOUNT_KEY": "DUMMY_BACKUP_B2_APPLICATION_KEY_NOT_REAL",
    "RESTIC_REPOSITORY": "b2:dummy-hermes-backup:backup-test-fixture",
    "TELEGRAM_BOT_TOKEN": "DUMMY_BACKUP_TELEGRAM_TOKEN_NOT_REAL",
}
RESTIC_PASSWORD = "DUMMY_BACKUP_RESTIC_PASSWORD_NOT_REAL"


def combined(result) -> str:
    return result.stdout + result.stderr


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def write_local_config(tmp_path: Path, *, mode_bits: int = 0o600) -> tuple[Path, Path]:
    config_dir = tmp_path / "config"
    config_dir.mkdir(mode=0o700)
    password_file = config_dir / "restic-password"
    password_file.write_text(RESTIC_PASSWORD + "\n")
    password_file.chmod(0o600)
    env_file = config_dir / "hermes-backup.env"
    env_file.write_text(
        "\n".join(
            [
                f"B2_ACCOUNT_ID={shlex.quote(DUMMY_ENV['B2_ACCOUNT_ID'])}",
                f"B2_ACCOUNT_KEY={shlex.quote(DUMMY_ENV['B2_ACCOUNT_KEY'])}",
                f"RESTIC_REPOSITORY={shlex.quote(DUMMY_ENV['RESTIC_REPOSITORY'])}",
                f"RESTIC_PASSWORD_FILE={shlex.quote(str(password_file))}",
                f"TELEGRAM_BOT_TOKEN={shlex.quote(DUMMY_ENV['TELEGRAM_BOT_TOKEN'])}",
                f"HERMES_BACKUP_LOG_DIR={shlex.quote(str(tmp_path / 'state' / 'hermes-backup' / 'logs'))}",
                f"HERMES_BACKUP_STAGING_DIR={shlex.quote(str(tmp_path / 'state' / 'hermes-backup' / 'staging'))}",
                "",
            ]
        )
    )
    env_file.chmod(mode_bits)
    return env_file, password_file


def add_fake_restic(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "restic",
        r'''
        #!/usr/bin/env python3
        import json, os, sys
        from pathlib import Path
        log = Path(os.environ["FAKE_RESTIC_LOG"])
        args = sys.argv[1:]
        with log.open("a") as f:
            f.write("ARGS " + "\0".join(args) + "\n")
            f.write("ENV " + " ".join(f"{name}={'set' if os.environ.get(name) else 'missing'}" for name in ["B2_ACCOUNT_ID", "B2_ACCOUNT_KEY", "RESTIC_REPOSITORY", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD", "RESTIC_PASSWORD_COMMAND"]) + "\n")
        if args[:1] == ["backup"]:
            if os.environ.get("FAKE_RESTIC_BACKUP_FAIL") == "1":
                sys.exit(42)
            print(json.dumps({"message_type": "summary", "snapshot_id": "fake-snapshot-id"}))
            sys.exit(0)
        if args[:1] == ["forget"]:
            if os.environ.get("FAKE_RESTIC_FORGET_FAIL") == "1":
                sys.exit(43)
            print("forget ok")
            sys.exit(0)
        sys.exit(2)
        ''',
    )


def fake_backup_env(tmp_path: Path, bin_dir: Path, log_file: Path, **extra: str) -> dict[str, str]:
    env = os.environ.copy()
    env.update({"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "HOME": str(tmp_path / "home"), "FAKE_RESTIC_LOG": str(log_file), **extra})
    return env


def run_backup(tmp_path: Path, *args: str, extra_env: dict[str, str] | None = None):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env_file, _ = write_local_config(tmp_path)
    root = fixture_root(tmp_path)
    env = fake_backup_env(tmp_path, bin_dir, log_file)
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--config-env",
            str(env_file),
            "--root",
            str(root),
            "--staging-parent",
            str(tmp_path / "state" / "hermes-backup" / "staging"),
            *args,
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, log_file, root


def assert_no_secret_values(output: str) -> None:
    for value in [*DUMMY_ENV.values(), RESTIC_PASSWORD]:
        assert value not in output


def test_backup_refuses_missing_local_env_file_before_staging_or_restic(tmp_path):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    missing_env = tmp_path / "missing.env"
    env = fake_backup_env(tmp_path, bin_dir, log_file)

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(missing_env)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode != 0
    output = combined(result)
    assert "local env file not found" in output
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_backup_requires_keys_from_local_env_not_ambient_environment(tmp_path):
    env_file, _ = write_local_config(tmp_path)
    env_file.write_text("\n".join(line for line in env_file.read_text().splitlines() if not line.startswith("B2_ACCOUNT_KEY=")) + "\n")
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_backup_env(tmp_path, bin_dir, log_file, B2_ACCOUNT_KEY="AMBIENT_B2_KEY_MUST_NOT_BE_USED")

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode != 0
    output = combined(result)
    assert "B2_ACCOUNT_KEY is required in local config env" in output
    assert "AMBIENT_B2_KEY_MUST_NOT_BE_USED" not in output
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_backup_refuses_unsafe_local_env_permissions(tmp_path):
    env_file, _ = write_local_config(tmp_path, mode_bits=0o644)
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_backup_env(tmp_path, bin_dir, log_file)

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode != 0
    output = combined(result)
    assert "local env file permissions are unsafe" in output
    assert "chmod 600" in output
    assert not log_file.exists()
    assert mode(env_file) == 0o644
    assert_no_secret_values(output)


def test_backup_refuses_non_0600_restic_password_file(tmp_path):
    env_file, password_file = write_local_config(tmp_path)
    password_file.chmod(0o400)
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_backup_env(tmp_path, bin_dir, log_file)

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode != 0
    output = combined(result)
    assert "local restic password file permissions are unsafe" in output
    assert "chmod 600" in output
    assert not log_file.exists()
    assert mode(password_file) == 0o400
    assert_no_secret_values(output)


def test_backup_suppresses_xtrace_from_local_env_file(tmp_path):
    custom_config_root = tmp_path / "custom-config-root"
    custom_config_root.mkdir()
    env_file, _ = write_local_config(custom_config_root)
    original = env_file.read_text()
    env_file.write_text("set -x\n" + original + "\necho SHOULD_NOT_PRINT_FROM_ENV\n")
    env_file.chmod(0o600)

    result, _, _ = run_backup(tmp_path, "--config-env", str(env_file))
    output = combined(result)

    assert result.returncode == 0, output
    assert "SHOULD_NOT_PRINT_FROM_ENV" not in output
    assert "+ B2_ACCOUNT_KEY=" not in output
    assert_no_secret_values(output)


def test_backup_ignores_internal_cleanup_names_from_local_env_file(tmp_path):
    custom_config_root = tmp_path / "internal-name-config-root"
    custom_config_root.mkdir()
    env_file, password_file = write_local_config(custom_config_root)
    victim = tmp_path / "stage-victim"
    victim.mkdir()
    (victim / "live.txt").write_text("must survive")
    env_file.write_text(env_file.read_text() + f"\nSTAGING_ROOT={shlex.quote(str(victim))}\n")
    password_file.chmod(0o400)

    result, _, _ = run_backup(tmp_path, "--config-env", str(env_file))
    output = combined(result)

    assert result.returncode != 0
    assert "local restic password file permissions are unsafe" in output
    assert (victim / "live.txt").read_text() == "must survive"
    assert_no_secret_values(output)


def test_backup_stages_first_backs_up_staging_root_then_forgets_with_locked_retention(tmp_path):
    result, log_file, root = run_backup(
        tmp_path,
        extra_env={"RESTIC_PASSWORD": "INHERITED_PASSWORD_MUST_NOT_BE_USED", "RESTIC_PASSWORD_COMMAND": "echo inherited"},
    )
    output = combined(result)

    assert result.returncode == 0, output
    assert "backup=ok snapshot_id=fake-snapshot-id" in output
    assert "retention=ok tag=hermes-vm-backup group-by=host,tags keep-daily=7 keep-weekly=8 keep-monthly=12 keep-yearly=2 prune=ok" in output
    assert "cleanup=removed staging_root=" in output
    assert_no_secret_values(output)

    log = log_file.read_text().splitlines()
    backup_args = log[0].split(" ", 1)[1].split("\0")
    forget_args = log[2].split(" ", 1)[1].split("\0")
    assert backup_args[0:4] == ["backup", "--json", "--tag", "hermes-vm-backup"]
    staged_source = Path(backup_args[-1])
    assert staged_source.is_absolute()
    assert str(staged_source).startswith(str(tmp_path / "state" / "hermes-backup" / "staging"))
    assert staged_source != root
    assert staged_source not in [Path("/home/agent"), Path("/home/agent/.hermes"), Path("/home/agent/shared")]
    assert forget_args == ["forget", "--tag", "hermes-vm-backup", "--group-by", "host,tags", "--keep-daily", "7", "--keep-weekly", "8", "--keep-monthly", "12", "--keep-yearly", "2", "--prune"]
    assert "B2_ACCOUNT_KEY=set" in log[1]
    assert "RESTIC_PASSWORD_FILE=set" in log[1]
    assert "RESTIC_PASSWORD=missing" in log[1]
    assert "RESTIC_PASSWORD_COMMAND=missing" in log[1]


def test_backup_preserves_staging_paths_containing_equals(tmp_path):
    staging_parent = tmp_path / "staging_root=with=equals" / "hermes-backup" / "staging"
    result, log_file, _ = run_backup(tmp_path, "--staging-parent", str(staging_parent))
    output = combined(result)

    assert result.returncode == 0, output
    assert_no_secret_values(output)
    log = log_file.read_text().splitlines()
    backup_args = log[0].split(" ", 1)[1].split("\0")
    assert str(Path(backup_args[-1])).startswith(str(staging_parent))
    assert "staging_root=with=equals" in backup_args[-1]


def test_backup_rejects_staging_root_under_live_include_root(tmp_path):
    root = fixture_root(tmp_path / "live-root")
    staging_parent = root / "home/agent/.hermes/profiles/execution-coder/staging"
    result, log_file, _ = run_backup(tmp_path, "--keep-staging", "--root", str(root) + "/.", "--staging-parent", str(staging_parent))
    output = combined(result)

    assert result.returncode != 0
    assert "refusing staging root inside configured live include root" in output
    assert "cleanup=removed-unsafe-staging-root staging_root=" in output
    cleanup_line = next(line for line in output.splitlines() if line.startswith("cleanup=removed-unsafe-staging-root staging_root="))
    assert not Path(cleanup_line.split("=", 2)[2]).exists()
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_backup_removes_partial_staging_after_staging_failure_by_default(tmp_path):
    root = fixture_root(tmp_path / "wal-root")
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

    result, log_file, _ = run_backup(tmp_path, "--root", str(root))
    output = combined(result)

    assert result.returncode != 0
    assert "refusing to open WAL-mode SQLite source" in output
    assert "cleanup=removed-after-staging-failure staging_root=" in output
    cleanup_line = next(line for line in output.splitlines() if line.startswith("cleanup=removed-after-staging-failure staging_root="))
    assert not Path(cleanup_line.split("=", 2)[2]).exists()
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_backup_skips_forget_and_prune_when_backup_fails(tmp_path):
    result, log_file, _ = run_backup(tmp_path, extra_env={"FAKE_RESTIC_BACKUP_FAIL": "1"})
    output = combined(result)

    assert result.returncode != 0
    assert "restic backup failed; retention/prune was skipped" in output
    assert_no_secret_values(output)
    log = log_file.read_text().splitlines()
    assert any(line.startswith("ARGS backup") for line in log)
    assert not any(line.startswith("ARGS forget") for line in log)
