import os
import pwd
import shlex
import stat
import subprocess
from pathlib import Path

from test_stage import fake_bin as stage_fake_bin, fixture_root, make_executable

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "activate.sh"

DUMMY_VALUES = {
    "B2_ACCOUNT_ID": "DUMMY_ACTIVATE_B2_KEY_ID_NOT_REAL",
    "B2_ACCOUNT_KEY": "DUMMY_ACTIVATE_B2_APPLICATION_KEY_NOT_REAL",
    "RESTIC_REPOSITORY": "b2:dummy-hermes-backup:activate-fixture",
    "RESTIC_PASSWORD": "DUMMY_ACTIVATE_RESTIC_PASSWORD_NOT_REAL",
    "TELEGRAM_BOT_TOKEN": "DUMMY_ACTIVATE_TELEGRAM_BOT_TOKEN_NOT_REAL",
    "TELEGRAM_CHAT_ID": "DUMMY_ACTIVATE_TELEGRAM_CHAT_ID_NOT_REAL",
}


def combined(result) -> str:
    return result.stdout + result.stderr


def assert_no_dummy_values(text: str) -> None:
    for value in DUMMY_VALUES.values():
        assert value not in text


def write_local_config(tmp_path: Path) -> tuple[Path, Path]:
    config_dir = tmp_path / "home" / "agent" / ".config" / "hermes-backup"
    config_dir.mkdir(parents=True, mode=0o700)
    password_file = config_dir / "restic-password"
    password_file.write_text(DUMMY_VALUES["RESTIC_PASSWORD"] + "\n")
    password_file.chmod(0o600)
    env_file = config_dir / "hermes-backup.env"
    env_file.write_text(
        "\n".join(
            [
                f"B2_ACCOUNT_ID={shlex.quote(DUMMY_VALUES['B2_ACCOUNT_ID'])}",
                f"B2_ACCOUNT_KEY={shlex.quote(DUMMY_VALUES['B2_ACCOUNT_KEY'])}",
                f"RESTIC_REPOSITORY={shlex.quote(DUMMY_VALUES['RESTIC_REPOSITORY'])}",
                f"RESTIC_PASSWORD_FILE={shlex.quote(str(password_file))}",
                f"TELEGRAM_BOT_TOKEN={shlex.quote(DUMMY_VALUES['TELEGRAM_BOT_TOKEN'])}",
                f"TELEGRAM_CHAT_ID={shlex.quote(DUMMY_VALUES['TELEGRAM_CHAT_ID'])}",
                f"HERMES_BACKUP_LOG_DIR={shlex.quote(str(tmp_path / 'state' / 'hermes-backup' / 'logs'))}",
                f"HERMES_BACKUP_STAGING_DIR={shlex.quote(str(tmp_path / 'state' / 'hermes-backup' / 'staging'))}",
                "",
            ]
        )
    )
    env_file.chmod(0o600)
    return env_file, password_file


def add_fake_restic(bin_dir: Path) -> None:
    make_executable(
        bin_dir / "restic",
        r'''
        #!/usr/bin/env python3
        import json, os, sys
        from pathlib import Path
        log = Path(os.environ["FAKE_RESTIC_LOG"])
        state = Path(os.environ.get("FAKE_RESTIC_REPO_STATE", log.with_suffix(".state")))
        args = sys.argv[1:]
        with log.open("a") as f:
            f.write("ARGS " + "\0".join(args) + "\n")
            f.write("ENV " + " ".join(f"{name}={'set' if os.environ.get(name) else 'missing'}" for name in ["B2_ACCOUNT_ID", "B2_ACCOUNT_KEY", "RESTIC_REPOSITORY", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD", "RESTIC_PASSWORD_COMMAND"]) + "\n")
        if args[:1] == ["snapshots"]:
            if os.environ.get("FAKE_RESTIC_WRONG_PASSWORD") == "1":
                password_file = Path(os.environ.get("RESTIC_PASSWORD_FILE", "missing"))
                password_text = password_file.read_text().strip() if password_file.exists() else "missing-password"
                print("unable to open config file: ciphertext verification failed " + password_text, file=sys.stderr)
                sys.exit(55)
            if os.environ.get("FAKE_RESTIC_SNAPSHOTS_FAIL") == "1":
                print("repository transient failure " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
                sys.exit(55)
            if not state.exists():
                print("repository not initialized " + os.environ.get("RESTIC_REPOSITORY", "missing"), file=sys.stderr)
                sys.exit(10)
            print("[]")
            sys.exit(0)
        if args[:1] == ["init"]:
            if os.environ.get("FAKE_RESTIC_INIT_FAIL") == "1":
                print("init failed " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
                sys.exit(56)
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text("initialized\n")
            print("created restic repository")
            sys.exit(0)
        if args[:1] == ["backup"]:
            if os.environ.get("FAKE_RESTIC_BACKUP_FAIL") == "1":
                print("backup failed " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
                sys.exit(42)
            print(json.dumps({"message_type": "summary", "snapshot_id": "activate-fake-snapshot"}))
            sys.exit(0)
        if args[:1] == ["forget"]:
            print("forget ok")
            sys.exit(0)
        if args[:1] == ["check"]:
            if os.environ.get("FAKE_RESTIC_CHECK_FAIL") == "1":
                print("check failed " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
                sys.exit(37)
            print("check ok")
            sys.exit(0)
        sys.exit(2)
        ''',
    )


def add_fake_curl(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "curl",
        r'''
        #!/usr/bin/env python3
        import os, sys
        from pathlib import Path
        log = Path(os.environ["FAKE_CURL_LOG"])
        config = sys.stdin.read()
        with log.open("a") as f:
            f.write("ARGS " + "\0".join(sys.argv[1:]) + "\n")
            for raw_line in config.splitlines():
                f.write("CONFIG " + raw_line + "\n")
                stripped = raw_line.strip()
                if stripped.startswith("data-urlencode = "):
                    value = stripped.split("=", 1)[1].strip().strip('"')
                    if value.startswith("text@"):
                        f.write("DATA text=" + Path(value.removeprefix("text@")).read_text() + "\n")
                    else:
                        f.write("DATA " + value + "\n")
        if os.environ.get("FAKE_CURL_FAIL") == "1":
            print("curl failure token=" + os.environ.get("TELEGRAM_BOT_TOKEN", "missing-token"), file=sys.stderr)
            sys.exit(22)
        print('{"ok":true}')
        ''',
    )


def add_fake_systemctl(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "systemctl",
        f'''
        #!/bin/sh
        printf '%s\n' "$*" >> {log_file}
        case "$*" in
          "--user list-unit-files"*) exit 0 ;;
          "--user daemon-reload") exit 0 ;;
          "--user enable hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer") exit 0 ;;
        esac
        exit 42
        ''',
    )


def fake_bin(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    bin_dir = stage_fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    curl_log = tmp_path / "curl.log"
    systemctl_log = tmp_path / "systemctl.log"
    add_fake_restic(bin_dir)
    add_fake_curl(bin_dir, curl_log)
    add_fake_systemctl(bin_dir, systemctl_log)
    return bin_dir, restic_log, curl_log, systemctl_log


def run_activate(tmp_path: Path, *args: str, extra_env: dict[str, str] | None = None):
    env_file, _password_file = write_local_config(tmp_path)
    bin_dir, restic_log, curl_log, systemctl_log = fake_bin(tmp_path)
    home = tmp_path / "home" / "agent"
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
            "HERMES_BACKUP_EXPECTED_HOME": str(home),
            "HERMES_BACKUP_EXPECTED_USER": pwd.getpwuid(os.geteuid()).pw_name,
            "HERMES_BACKUP_EXPECTED_EUID": str(os.geteuid()),
            "FAKE_RESTIC_LOG": str(restic_log),
            "FAKE_RESTIC_REPO_STATE": str(tmp_path / "restic-initialized.state"),
            "FAKE_CURL_LOG": str(curl_log),
        }
    )
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--config-env", str(env_file), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, restic_log, curl_log, systemctl_log


def restic_args(log_file: Path) -> list[list[str]]:
    return [line.removeprefix("ARGS ").split("\0") for line in log_file.read_text().splitlines() if line.startswith("ARGS ")]


def test_activate_has_valid_bash_syntax_and_is_executable():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=ROOT, text=True, capture_output=True, check=False)
    assert result.returncode == 0, combined(result)
    assert SCRIPT.stat().st_mode & stat.S_IXUSR


def test_activate_default_checks_config_only_and_does_not_touch_network_or_timers(tmp_path):
    result, restic_log, curl_log, systemctl_log = run_activate(tmp_path)
    output = combined(result)

    assert result.returncode == 0, output
    assert "restic_repository=skipped reason=no-restic-dependent-flag" in output
    assert "first_backup=skipped reason=flag-not-set" in output
    assert "timer_enablement=skipped reason=flag-not-set" in output
    assert not restic_log.exists()
    assert not curl_log.exists()
    calls = systemctl_log.read_text().splitlines()
    assert calls == ["--user list-unit-files --no-pager"]
    assert_no_dummy_values(output)


def test_activate_dry_run_with_flags_still_does_not_touch_restic_network_or_timers(tmp_path):
    result, restic_log, curl_log, systemctl_log = run_activate(tmp_path, "--dry-run", "--init-restic", "--telegram-test", "--first-backup", "--first-check", "--enable-timers")
    output = combined(result)

    assert result.returncode == 0, output
    assert "dry_run=1" in output
    assert not restic_log.exists()
    assert not curl_log.exists()
    calls = systemctl_log.read_text().splitlines()
    assert calls == ["--user list-unit-files --no-pager"]
    assert_no_dummy_values(output)


def test_activate_initializes_uninitialized_restic_before_first_backup_and_check(tmp_path):
    root = fixture_root(tmp_path / "fixture")
    result, restic_log, curl_log, _systemctl_log = run_activate(
        tmp_path,
        "--init-restic",
        "--first-backup",
        "--first-check",
        "--backup-root",
        str(root),
        "--staging-parent",
        str(tmp_path / "state" / "hermes-backup" / "staging"),
    )
    output = combined(result)

    assert result.returncode == 0, output
    assert "restic_repository=missing action=init" in output
    assert "restic_init=ok" in output
    assert "first_backup=ok" in output
    assert "first_check=ok" in output
    assert not curl_log.exists()
    args = restic_args(restic_log)
    assert args[0] == ["snapshots", "--json"]
    assert args[1] == ["init"]
    assert args[2] == ["snapshots", "--json"]
    assert args[3][0:4] == ["backup", "--json", "--tag", "hermes-vm-backup"]
    assert ["forget", "--tag", "hermes-vm-backup", "--group-by", "host,tags", "--keep-daily", "7", "--keep-weekly", "8", "--keep-monthly", "12", "--keep-yearly", "2", "--prune"] in args
    assert args[-1] == ["check"]
    assert all("RESTIC_PASSWORD=missing" in line for line in restic_log.read_text().splitlines() if line.startswith("ENV "))
    assert_no_dummy_values(output)


def test_activate_refuses_restic_init_for_wrong_password_like_failures(tmp_path):
    result, restic_log, _curl_log, _systemctl_log = run_activate(tmp_path, "--init-restic", extra_env={"FAKE_RESTIC_WRONG_PASSWORD": "1"})
    output = combined(result)

    assert result.returncode != 0
    assert "refusing restic init" in output
    assert "ciphertext verification failed" in output
    assert ["init"] not in restic_args(restic_log)
    assert_no_dummy_values(output)


def test_activate_requires_timer_enablement_config_to_be_the_scheduled_env_name(tmp_path):
    env_file, _password_file = write_local_config(tmp_path)
    custom_env = env_file.with_name("custom.env")
    custom_env.write_text(env_file.read_text())
    custom_env.chmod(0o600)
    bin_dir, restic_log, curl_log, systemctl_log = fake_bin(tmp_path)
    home = tmp_path / "home" / "agent"
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
            "HERMES_BACKUP_EXPECTED_HOME": str(home),
            "HERMES_BACKUP_EXPECTED_USER": pwd.getpwuid(os.geteuid()).pw_name,
            "HERMES_BACKUP_EXPECTED_EUID": str(os.geteuid()),
            "FAKE_RESTIC_LOG": str(restic_log),
            "FAKE_CURL_LOG": str(curl_log),
        }
    )
    result = subprocess.run(
        ["bash", str(SCRIPT), "--config-env", str(custom_env), "--first-backup", "--first-check", "--enable-timers"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    output = combined(result)

    assert result.returncode != 0
    assert "--enable-timers requires --config-env to point at a hermes-backup.env file" in output
    assert not restic_log.exists()
    assert not curl_log.exists()
    assert not systemctl_log.exists()
    assert_no_dummy_values(output)


def test_activate_telegram_test_reports_redacted_curl_failure_without_real_telegram(tmp_path):
    state = tmp_path / "restic-initialized.state"
    state.write_text("already initialized\n")
    result, _restic_log, curl_log, _systemctl_log = run_activate(tmp_path, "--telegram-test", extra_env={"FAKE_CURL_FAIL": "1"})
    output = combined(result)

    assert result.returncode != 0
    assert "raw Telegram test failed" in output
    assert "telegram_test=failed" in (tmp_path / "state" / "hermes-backup" / "logs").glob("hermes-backup-*.log").__next__().read_text()
    assert "https://api.telegram.org/bot" in curl_log.read_text()
    assert "Hermes backup setup test" in curl_log.read_text()
    assert_no_dummy_values(output)
    log_text = next((tmp_path / "state" / "hermes-backup" / "logs").glob("hermes-backup-*.log")).read_text()
    assert_no_dummy_values(log_text)


def test_activate_enables_timers_only_after_first_backup_and_check_without_starting(tmp_path):
    (tmp_path / "restic-initialized.state").write_text("already initialized\n")
    root = fixture_root(tmp_path / "fixture")
    result, _restic_log, _curl_log, systemctl_log = run_activate(
        tmp_path,
        "--first-backup",
        "--first-check",
        "--enable-timers",
        "--backup-root",
        str(root),
        "--staging-parent",
        str(tmp_path / "state" / "hermes-backup" / "staging"),
    )
    output = combined(result)

    assert result.returncode == 0, output
    assert "first_backup=ok" in output
    assert "first_check=ok" in output
    assert "timer_enablement=ok enabled_without_now=true" in output
    calls = systemctl_log.read_text().splitlines()
    assert calls[-2:] == [
        "--user daemon-reload",
        "--user enable hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer",
    ]
    all_calls = "\n".join(calls)
    assert "--now" not in all_calls
    assert " start " not in f" {all_calls} "
    assert "restart" not in all_calls
    assert_no_dummy_values(output)


def test_activate_refuses_timer_enablement_without_same_run_verification(tmp_path):
    result, restic_log, curl_log, systemctl_log = run_activate(tmp_path, "--enable-timers")
    output = combined(result)

    assert result.returncode != 0
    assert "--enable-timers requires --first-backup and --first-check" in output
    assert not restic_log.exists()
    assert not curl_log.exists()
    assert not systemctl_log.exists()
    assert_no_dummy_values(output)
