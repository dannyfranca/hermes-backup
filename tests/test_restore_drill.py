import os
import shlex
import sqlite3
import stat
import subprocess
from pathlib import Path

from test_logs_alerts import add_fake_curl, alert_message_payload
from test_stage import fake_bin, make_executable

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "restore-drill.sh"

DUMMY = {
    "B2_ACCOUNT_ID": "DUMMY_DRILL_B2_KEY_ID_NOT_REAL",
    "B2_ACCOUNT_KEY": "DUMMY_DRILL_B2_APPLICATION_KEY_NOT_REAL",
    "RESTIC_REPOSITORY": "b2:dummy-hermes-backup:drill-test-fixture",
    "RESTIC_PASSWORD": "DUMMY_DRILL_RESTIC_PASSWORD_NOT_REAL",
    "TELEGRAM_BOT_TOKEN": "DUMMY_DRILL_TELEGRAM_TOKEN_NOT_REAL",
    "TELEGRAM_CHAT_ID": "-1001234567890",
}
def combined(result) -> str:
    return result.stdout + result.stderr


def write_local_config(tmp_path: Path, *, mode_bits: int = 0o600) -> tuple[Path, Path, Path, Path]:
    config_dir = tmp_path / "config"
    config_dir.mkdir(mode=0o700, parents=True)
    password_file = config_dir / "restic-password"
    password_file.write_text(DUMMY["RESTIC_PASSWORD"] + "\n")
    password_file.chmod(0o600)
    log_dir = tmp_path / "state" / "logs"
    drill_root = tmp_path / "state" / "drills"
    env_file = config_dir / "hermes-backup.env"
    env_file.write_text(
        "\n".join(
            [
                f"B2_ACCOUNT_ID={shlex.quote(DUMMY['B2_ACCOUNT_ID'])}",
                f"B2_ACCOUNT_KEY={shlex.quote(DUMMY['B2_ACCOUNT_KEY'])}",
                f"RESTIC_REPOSITORY={shlex.quote(DUMMY['RESTIC_REPOSITORY'])}",
                f"RESTIC_PASSWORD_FILE={shlex.quote(str(password_file))}",
                f"TELEGRAM_BOT_TOKEN={shlex.quote(DUMMY['TELEGRAM_BOT_TOKEN'])}",
                f"TELEGRAM_CHAT_ID={shlex.quote(DUMMY['TELEGRAM_CHAT_ID'])}",
                f"HERMES_BACKUP_LOG_DIR={shlex.quote(str(log_dir))}",
                f"HERMES_BACKUP_DRILL_DIR={shlex.quote(str(drill_root))}",
                "",
            ]
        )
    )
    env_file.chmod(mode_bits)
    return env_file, password_file, log_dir, drill_root
def add_fake_restore(bin_dir: Path) -> Path:
    restore = bin_dir / "fake-restore.sh"
    make_executable(
        restore,
        r'''
        #!/usr/bin/env python3
        import os, sqlite3, sys
        from pathlib import Path
        args = sys.argv[1:]
        target = Path(args[args.index("--target") + 1])
        log = Path(os.environ["FAKE_RESTORE_LOG"])
        log.write_text("ARGS " + "\0".join(args) + "\n")
        if os.environ.get("FAKE_RESTORE_FAIL") == "1":
            print("restore failed " + os.environ.get("B2_ACCOUNT_KEY", "not-present"), file=sys.stderr)
            sys.exit(44)
        target.mkdir(parents=True, exist_ok=True)
        includes = "home/agent/.hermes/config.yaml,home/agent/shared/reports/status.html,home/agent/shared-assets/mermaid/mermaid.min.js,home/agent/.config/systemd/user/hermes-gateway.service,home/agent/.config/containers/systemd/home-stream.container".split(",")
        if os.environ.get("FAKE_RESTORE_MISSING_SHARED") == "1":
            includes = [p for p in includes if not p.startswith("home/agent/shared/")]
        for rel in includes:
            p = target / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("restored fixture\n")
        if os.environ.get("FAKE_RESTORE_SQLITE") == "valid":
            db = target / "home/agent/.hermes/kanban.db"
            conn = sqlite3.connect(db)
            conn.execute("create table tasks(id text primary key, title text)")
            conn.execute("insert into tasks values ('t_ok', 'ok')")
            conn.commit()
            conn.close()
        elif os.environ.get("FAKE_RESTORE_SQLITE") == "invalid":
            db = target / "home/agent/.hermes/kanban.sqlite"
            db.write_bytes(b"SQLite format 3\0corrupt")
        print("restore=ok")
        sys.exit(0)
        ''',
    )
    return restore


def run_drill(tmp_path: Path, *, extra_env: dict[str, str] | None = None, mode_bits: int = 0o600, keep: bool = False):
    bin_dir = fake_bin(tmp_path)
    restore_log = tmp_path / "restore.log"
    curl_log = tmp_path / "curl.log"
    restore = add_fake_restore(bin_dir)
    add_fake_curl(bin_dir, curl_log)
    env_file, _, log_dir, drill_root = write_local_config(tmp_path, mode_bits=mode_bits)
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(tmp_path / "home"),
            "FAKE_RESTORE_LOG": str(restore_log),
            "FAKE_CURL_LOG": str(curl_log),
            "HERMES_BACKUP_DRILL_ID": "20260705T000000Z",
            "B2_ACCOUNT_KEY": "AMBIENT_B2_KEY_MUST_NOT_LEAK",
            "TELEGRAM_BOT_TOKEN": "AMBIENT_TELEGRAM_TOKEN_MUST_NOT_LEAK",
        }
    )
    if extra_env:
        env.update(extra_env)
    args = [
        "bash",
        str(SCRIPT),
        "--config-env",
        str(env_file),
        "--restore-command",
        str(restore),
    ]
    if keep:
        args.append("--keep-artifacts")
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    return result, log_dir, drill_root, curl_log, restore_log


def one_daily_log(log_dir: Path) -> str:
    logs = list(log_dir.glob("hermes-backup-*.log"))
    assert len(logs) == 1
    return logs[0].read_text()


def target_from_output(output: str) -> Path:
    for line in output.splitlines():
        if line.startswith("drill_target="):
            return Path(line.split("=", 1)[1])
    raise AssertionError(output)


def assert_no_secret_values(text: str) -> None:
    for value in [*DUMMY.values(), "AMBIENT_B2_KEY_MUST_NOT_LEAK", "AMBIENT_TELEGRAM_TOKEN_MUST_NOT_LEAK"]:
        assert value not in text


def test_restore_drill_has_valid_bash_syntax_and_is_executable():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=ROOT, text=True, capture_output=True, check=False)
    assert result.returncode == 0, combined(result)
    assert SCRIPT.stat().st_mode & stat.S_IXUSR


def test_restore_drill_success_verifies_paths_sqlite_logs_and_sends_pass_report(tmp_path):
    result, log_dir, drill_root, curl_log, restore_log = run_drill(tmp_path, extra_env={"FAKE_RESTORE_SQLITE": "valid"}, keep=True)
    output = combined(result)

    assert result.returncode == 0, output
    target = target_from_output(output)
    assert str(target).startswith(str(drill_root))
    assert target.exists()
    assert "mode=temporary-safe-restore promote=false" in output
    assert "verify path=/home/agent/.hermes status=present" in output
    assert "sqlite path=home/agent/.hermes/kanban.db status=ok" in output
    assert "drill=ok present=5 missing=0 sqlite_checked=1 sqlite_failed=0" in output
    assert "drill_report=sent transport=raw-telegram-api" in output

    restore_args = restore_log.read_text().split(" ", 1)[1].split("\0")
    assert "--target" in restore_args
    assert str(target) == restore_args[restore_args.index("--target") + 1]
    assert str(target) not in ["/home/agent", "/home/agent/.hermes", "/home/agent/shared"]

    log_text = one_daily_log(log_dir)
    assert "command=drill status=success exit=0" in log_text
    assert "drill_report=sent command=drill transport=raw-telegram-api" in log_text
    payload = alert_message_payload(curl_log.read_text())
    assert "Hermes backup restore drill" in payload
    assert "status: PASS" in payload
    assert "sqlite_checked=1" in payload
    assert_no_secret_values(output + log_text + payload)


def test_restore_drill_missing_key_path_fails_and_sends_fail_report_without_retaining_artifacts_by_default(tmp_path):
    result, log_dir, _, curl_log, _ = run_drill(tmp_path, extra_env={"FAKE_RESTORE_MISSING_SHARED": "1"})
    output = combined(result)

    assert result.returncode == 1, output
    target = target_from_output(output)
    assert not target.exists()
    assert "verify path=/home/agent/shared status=missing" in output
    assert "drill_report=sent transport=raw-telegram-api" in output
    log_text = one_daily_log(log_dir)
    assert "command=drill status=failure exit=1" in log_text
    payload = alert_message_payload(curl_log.read_text())
    assert "status: FAIL" in payload
    assert "missing=1" in payload
    assert_no_secret_values(output + log_text + payload)


def test_restore_drill_sqlite_integrity_failure_fails_and_reports_context(tmp_path):
    result, log_dir, _, curl_log, _ = run_drill(tmp_path, extra_env={"FAKE_RESTORE_SQLITE": "invalid"})
    output = combined(result)

    assert result.returncode == 1, output
    assert "sqlite path=home/agent/.hermes/kanban.sqlite status=failed reason=integrity-check" in output
    assert "sqlite_failed=1" in output
    log_text = one_daily_log(log_dir)
    payload = alert_message_payload(curl_log.read_text())
    assert "status: FAIL" in payload
    assert "sqlite_failed=1" in payload
    assert_no_secret_values(output + log_text + payload)


def test_restore_drill_restore_failure_propagates_restore_exit_and_reports_fail(tmp_path):
    result, log_dir, _, curl_log, _ = run_drill(tmp_path, extra_env={"FAKE_RESTORE_FAIL": "1"})
    output = combined(result)

    assert result.returncode == 44
    assert "restore=failed exit=44" in output
    log_text = one_daily_log(log_dir)
    payload = alert_message_payload(curl_log.read_text())
    assert "status: FAIL" in payload
    assert "restore failed" in payload
    assert_no_secret_values(output + log_text + payload)


def test_restore_drill_refuses_unsafe_local_env_before_restore_or_report(tmp_path):
    result, log_dir, _, curl_log, restore_log = run_drill(tmp_path, mode_bits=0o644)
    output = combined(result)

    assert result.returncode != 0
    assert "local env file permissions are unsafe" in output
    assert not restore_log.exists()
    assert not curl_log.exists()
    assert not log_dir.exists()
    assert_no_secret_values(output)
