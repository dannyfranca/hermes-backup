import os
import shlex
import subprocess
from pathlib import Path

from test_backup import DUMMY_ENV, RESTIC_PASSWORD, write_local_config
from test_stage import fake_bin, fixture_root, make_executable

ROOT = Path(__file__).resolve().parents[1]
BACKUP_SCRIPT = ROOT / "scripts" / "backup.sh"
CHECK_SCRIPT = ROOT / "scripts" / "restic-check.sh"

DUMMY_CHAT_ID = "-1001234567890"
GENERIC_PASSWORD = "password=DUMMY_GENERIC_PASSWORD_NOT_REAL"
GENERIC_AUTH = "Authorization: Bearer DUMMY_AUTH_BEARER_NOT_REAL"


def combined(result) -> str:
    return result.stdout + result.stderr


def add_alert_config(env_file: Path, tmp_path: Path) -> Path:
    log_dir = tmp_path / "state" / "hermes-backup" / "logs"
    env_file.write_text(
        env_file.read_text()
        + "\n".join(
            [
                f"TELEGRAM_CHAT_ID={shlex.quote(DUMMY_CHAT_ID)}",
                f"HERMES_BACKUP_LOG_DIR={shlex.quote(str(log_dir))}",
                "",
            ]
        )
    )
    env_file.chmod(0o600)
    return log_dir


def add_fake_curl(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "curl",
        r'''
        #!/usr/bin/env python3
        import os, sys
        from pathlib import Path
        log = Path(os.environ["FAKE_CURL_LOG"])
        args = sys.argv[1:]
        config = sys.stdin.read()
        with log.open("a") as f:
            f.write("ARGS " + "\0".join(args) + "\n")
            if config:
                for raw_line in config.splitlines():
                    f.write("CONFIG " + raw_line + "\n")
                    stripped = raw_line.strip()
                    if stripped.startswith("url = "):
                        f.write("URL " + stripped.split("=", 1)[1].strip().strip('"') + "\n")
                    if stripped.startswith("data-urlencode = "):
                        value = stripped.split("=", 1)[1].strip().strip('"')
                        if value.startswith("text@"):
                            try:
                                f.write("DATA text=" + Path(value.removeprefix("text@")).read_text() + "\n")
                            except Exception as exc:
                                f.write("DATA text-read-error=" + str(exc) + "\n")
                        else:
                            f.write("DATA " + value + "\n")
            for index, arg in enumerate(args):
                if arg == "--data-urlencode" and index + 1 < len(args):
                    f.write("DATA " + args[index + 1] + "\n")
        if os.environ.get("FAKE_CURL_FAIL") == "1":
            print("curl failed with " + os.environ.get("TELEGRAM_BOT_TOKEN", "missing-token"), file=sys.stderr)
            sys.exit(22)
        print('{"ok":true}')
        ''',
    )


def add_fake_backup_restic(bin_dir: Path, log_file: Path) -> None:
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
        if args[:1] == ["backup"]:
            if os.environ.get("FAKE_RESTIC_BACKUP_FAIL") == "1":
                print("backup exploded " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
                print(os.environ.get("RESTIC_REPOSITORY", "missing"), file=sys.stderr)
                print("Authorization: Bearer DUMMY_AUTH_BEARER_NOT_REAL", file=sys.stderr)
                print("password=DUMMY_GENERIC_PASSWORD_NOT_REAL", file=sys.stderr)
                sys.exit(42)
            print(json.dumps({"message_type": "summary", "snapshot_id": "fake-snapshot-id"}))
            sys.exit(0)
        if args[:1] == ["forget"]:
            print("forget ok")
            sys.exit(0)
        sys.exit(2)
        ''',
    )


def add_fake_check_restic(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "restic",
        r'''
        #!/usr/bin/env python3
        import os, sys
        from pathlib import Path
        log = Path(os.environ["FAKE_RESTIC_LOG"])
        args = sys.argv[1:]
        with log.open("a") as f:
            f.write("ARGS " + "\0".join(args) + "\n")
        if args[:1] == ["check"]:
            print("repository broken " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
            print(os.environ.get("RESTIC_REPOSITORY", "missing"), file=sys.stderr)
            print(os.environ.get("FAKE_RESTIC_STDERR_SECRET", ""), file=sys.stderr)
            print("Authorization: Bearer DUMMY_AUTH_BEARER_NOT_REAL", file=sys.stderr)
            print("Authorization: Basic DUMMY_BASIC_AUTH_NOT_REAL", file=sys.stderr)
            print("Authorization=Bearer DUMMY_EQUALS_AUTH_NOT_REAL", file=sys.stderr)
            print("api_key: DUMMY_API_KEY_NOT_REAL", file=sys.stderr)
            print("key=DUMMY_PLAIN_KEY_NOT_REAL", file=sys.stderr)
            print('json {"api_key":"DUMMY_JSON_API_KEY_NOT_REAL","Authorization":"Bearer DUMMY_JSON_AUTH_NOT_REAL"}', file=sys.stderr)
            print("url https://example.invalid/path?access_token=DUMMY_QUERY_TOKEN_NOT_REAL&api_key=DUMMY_QUERY_API_KEY_NOT_REAL", file=sys.stderr)
            print("credential=DUMMY_CREDENTIAL_FIELD_NOT_REAL", file=sys.stderr)
            print("error,token=DUMMY_PUNCT_TOKEN_NOT_REAL", file=sys.stderr)
            print(os.environ.get("FAKE_RESTIC_PASSWORD_CONTENT", ""), file=sys.stderr)
            sys.exit(37)
        sys.exit(2)
        ''',
    )


def run_backup_with_fakes(tmp_path: Path, *, restic_fail: bool = False, curl_fail: bool = False):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    curl_log = tmp_path / "curl.log"
    add_fake_backup_restic(bin_dir, restic_log)
    add_fake_curl(bin_dir, curl_log)
    env_file, _ = write_local_config(tmp_path)
    log_dir = add_alert_config(env_file, tmp_path)
    root = fixture_root(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(tmp_path / "home"),
            "FAKE_RESTIC_LOG": str(restic_log),
            "FAKE_CURL_LOG": str(curl_log),
            "GENERIC_AUTH": GENERIC_AUTH,
            "GENERIC_PASSWORD": GENERIC_PASSWORD,
        }
    )
    if restic_fail:
        env["FAKE_RESTIC_BACKUP_FAIL"] = "1"
    if curl_fail:
        env["FAKE_CURL_FAIL"] = "1"
    result = subprocess.run(
        [
            "bash",
            str(BACKUP_SCRIPT),
            "--config-env",
            str(env_file),
            "--root",
            str(root),
            "--staging-parent",
            str(tmp_path / "state" / "hermes-backup" / "staging"),
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, log_dir, curl_log


def run_check_with_fakes(tmp_path: Path):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    curl_log = tmp_path / "curl.log"
    add_fake_check_restic(bin_dir, restic_log)
    add_fake_curl(bin_dir, curl_log)
    env_file, _ = write_local_config(tmp_path)
    log_dir = add_alert_config(env_file, tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(tmp_path / "home"),
            "FAKE_RESTIC_LOG": str(restic_log),
            "FAKE_CURL_LOG": str(curl_log),
            "FAKE_RESTIC_STDERR_SECRET": DUMMY_ENV["TELEGRAM_BOT_TOKEN"],
            "FAKE_RESTIC_PASSWORD_CONTENT": RESTIC_PASSWORD,
            "GENERIC_AUTH": GENERIC_AUTH,
            "GENERIC_PASSWORD": GENERIC_PASSWORD,
        }
    )
    result = subprocess.run(["bash", str(CHECK_SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    return result, log_dir, curl_log


def one_daily_log(log_dir: Path) -> str:
    logs = list(log_dir.glob("hermes-backup-*.log"))
    assert len(logs) == 1
    return logs[0].read_text()


def alert_message_payload(curl_text: str) -> str:
    lines = curl_text.splitlines()
    payload: list[str] = []
    capturing = False
    for line in lines:
        if line.startswith("DATA text="):
            capturing = True
            payload.append(line.removeprefix("DATA text="))
            continue
        if capturing and (line.startswith("DATA ") or line.startswith("ARGS ")):
            capturing = False
        if capturing:
            payload.append(line)
    return "\n".join(payload)


def assert_sensitive_values_redacted(text: str) -> None:
    for value in [*DUMMY_ENV.values(), RESTIC_PASSWORD, DUMMY_CHAT_ID, "DUMMY_AUTH_BEARER_NOT_REAL", "DUMMY_BASIC_AUTH_NOT_REAL", "DUMMY_EQUALS_AUTH_NOT_REAL", "DUMMY_API_KEY_NOT_REAL", "DUMMY_PLAIN_KEY_NOT_REAL", "DUMMY_JSON_API_KEY_NOT_REAL", "DUMMY_JSON_AUTH_NOT_REAL", "DUMMY_QUERY_TOKEN_NOT_REAL", "DUMMY_QUERY_API_KEY_NOT_REAL", "DUMMY_CREDENTIAL_FIELD_NOT_REAL", "DUMMY_PUNCT_TOKEN_NOT_REAL", "DUMMY_GENERIC_PASSWORD_NOT_REAL"]:
        assert value not in text
    assert "[redacted:B2_ACCOUNT_KEY]" in text
    assert "[redacted:credential]" in text


def test_scripts_resolve_library_when_invoked_from_scripts_directory():
    backup_help = subprocess.run(["bash", "backup.sh", "--help"], cwd=ROOT / "scripts", text=True, capture_output=True, check=False)
    check_help = subprocess.run(["bash", "restic-check.sh", "--help"], cwd=ROOT / "scripts", text=True, capture_output=True, check=False)

    assert backup_help.returncode == 0, combined(backup_help)
    assert "Usage: scripts/backup.sh" in backup_help.stdout
    assert check_help.returncode == 0, combined(check_help)
    assert "Usage: scripts/restic-check.sh" in check_help.stdout


def test_backup_success_writes_daily_local_log_without_telegram_success_noise(tmp_path):
    result, log_dir, curl_log = run_backup_with_fakes(tmp_path)
    output = combined(result)

    assert result.returncode == 0, output
    log_text = one_daily_log(log_dir)
    assert "command=backup status=success exit=0" in log_text
    assert "backup=ok snapshot_id=fake-snapshot-id" in log_text
    assert not curl_log.exists()
    assert_sensitive_values_redacted(log_text + output + "[redacted:B2_ACCOUNT_KEY][redacted:TELEGRAM_BOT_TOKEN][redacted:credential]")


def test_backup_failure_logs_redacted_summary_and_sends_one_raw_telegram_alert(tmp_path):
    result, log_dir, curl_log = run_backup_with_fakes(tmp_path, restic_fail=True)
    output = combined(result)

    assert result.returncode != 0
    log_text = one_daily_log(log_dir)
    curl_text = curl_log.read_text()
    assert "command=backup status=failure exit=42" in log_text
    assert "https://api.telegram.org/bot" in curl_text
    assert "sendMessage" in curl_text
    assert "DATA chat_id=" in curl_text
    assert curl_text.count("ARGS ") == 1
    assert "command: backup" in curl_text
    assert "exit: 42" in curl_text
    assert_sensitive_values_redacted(log_text + alert_message_payload(curl_text) + output)


def test_backup_failure_records_redacted_curl_failure_without_duplicate_alert(tmp_path):
    result, log_dir, curl_log = run_backup_with_fakes(tmp_path, restic_fail=True, curl_fail=True)
    output = combined(result)

    assert result.returncode != 0
    log_text = one_daily_log(log_dir)
    curl_text = curl_log.read_text()
    assert curl_text.count("ARGS ") == 1
    assert "alert=failed command=backup" in log_text
    assert "alert_error=" in log_text
    assert_sensitive_values_redacted(log_text + alert_message_payload(curl_text) + output)


def test_restic_check_failure_logs_redacted_summary_and_sends_one_raw_telegram_alert(tmp_path):
    result, log_dir, curl_log = run_check_with_fakes(tmp_path)
    output = combined(result)

    assert result.returncode == 37
    log_text = one_daily_log(log_dir)
    curl_text = curl_log.read_text()
    assert "command=check status=failure exit=37" in log_text
    assert "https://api.telegram.org/bot" in curl_text
    assert "sendMessage" in curl_text
    assert curl_text.count("ARGS ") == 1
    assert "command: check" in curl_text
    assert "exit: 37" in curl_text
    assert_sensitive_values_redacted(log_text + alert_message_payload(curl_text) + output)
    assert "[redacted:TELEGRAM_BOT_TOKEN]" in log_text + alert_message_payload(curl_text) + output
