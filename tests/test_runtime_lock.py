import fcntl
import os
import shlex
import subprocess
import time
from pathlib import Path

from test_backup import DUMMY_ENV, RESTIC_PASSWORD, write_local_config
from test_logs_alerts import add_fake_curl, alert_message_payload, one_daily_log
from test_restic_check import add_fake_restic as add_fake_check_restic
from test_restore_drill import add_fake_restore, write_local_config as write_drill_config
from test_stage import fake_bin, fixture_root, make_executable

ROOT = Path(__file__).resolve().parents[1]
BACKUP_SCRIPT = ROOT / "scripts" / "backup.sh"
CHECK_SCRIPT = ROOT / "scripts" / "restic-check.sh"
DRILL_SCRIPT = ROOT / "scripts" / "restore-drill.sh"


def combined(result) -> str:
    return result.stdout + result.stderr


def hold_lock(lock_file: Path):
    lock_file.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_file.open("w")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    return handle


def add_lock_config(env_file: Path, lock_file: Path, *, telegram_chat: str | None = None) -> None:
    additions = [f"HERMES_BACKUP_LOCK_FILE={shlex.quote(str(lock_file))}"]
    if telegram_chat is not None:
        additions.append(f"TELEGRAM_CHAT_ID={shlex.quote(telegram_chat)}")
    env_file.write_text(env_file.read_text() + "\n" + "\n".join(additions) + "\n")
    env_file.chmod(0o600)


def assert_no_backup_secret_values(text: str) -> None:
    for value in [*DUMMY_ENV.values(), RESTIC_PASSWORD, "-1001234567890"]:
        assert value not in text


def add_unexpected_restic(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "restic",
        f"""#!/usr/bin/env python3
from pathlib import Path
import sys
Path({str(log_file)!r}).write_text("unexpected restic invocation\\n")
sys.exit(99)
""",
    )


def test_backup_lock_contention_fails_and_sends_one_raw_telegram_alert_without_restic(tmp_path):
    bin_dir = fake_bin(tmp_path)
    curl_log = tmp_path / "curl.log"
    restic_log = tmp_path / "restic.log"
    add_unexpected_restic(bin_dir, restic_log)
    add_fake_curl(bin_dir, curl_log)
    env_file, _ = write_local_config(tmp_path)
    lock_file = tmp_path / "state" / "hermes-backup" / "run.lock"
    add_lock_config(env_file, lock_file, telegram_chat="-1001234567890")
    root = fixture_root(tmp_path)

    with hold_lock(lock_file):
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
            env={
                **os.environ,
                "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                "HOME": str(tmp_path / "home"),
                "FAKE_CURL_LOG": str(curl_log),
            },
            text=True,
            capture_output=True,
            check=False,
        )

    output = combined(result)
    assert result.returncode == 75, output
    assert "runtime lock busy" in output
    assert "another hermes-backup job is running" in output
    assert not restic_log.exists()
    log_text = one_daily_log(tmp_path / "state" / "hermes-backup" / "logs")
    payload = alert_message_payload(curl_log.read_text())
    assert "command=backup status=failure exit=75" in log_text
    assert "command: backup" in payload
    assert "exit: 75" in payload
    assert_no_backup_secret_values(output + log_text + payload)


def test_restic_check_lock_contention_skips_cleanly_without_running_restic_or_alert(tmp_path):
    bin_dir = fake_bin(tmp_path)
    curl_log = tmp_path / "curl.log"
    add_fake_curl(bin_dir, curl_log)
    env_file, _ = write_local_config(tmp_path)
    lock_file = tmp_path / "state" / "hermes-backup" / "run.lock"
    add_lock_config(env_file, lock_file, telegram_chat="-1001234567890")
    restic_log = tmp_path / "restic.log"
    add_unexpected_restic(bin_dir, restic_log)

    with hold_lock(lock_file):
        result = subprocess.run(
            ["bash", str(CHECK_SCRIPT), "--config-env", str(env_file)],
            cwd=ROOT,
            env={**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "HOME": str(tmp_path / "home"), "FAKE_RESTIC_LOG": str(restic_log), "FAKE_CURL_LOG": str(curl_log)},
            text=True,
            capture_output=True,
            check=False,
        )

    output = combined(result)
    assert result.returncode == 0, output
    assert "check=skipped reason=runtime-lock-held" in output
    assert "No restic check was started" in output
    assert not restic_log.exists()
    assert not curl_log.exists()
    log_text = one_daily_log(tmp_path / "state" / "hermes-backup" / "logs")
    assert "command=check status=skipped exit=0" in log_text
    assert_no_backup_secret_values(output + log_text)


def test_restore_drill_lock_contention_skips_and_reports_without_restore(tmp_path):
    bin_dir = fake_bin(tmp_path)
    curl_log = tmp_path / "curl.log"
    restore_log = tmp_path / "restore.log"
    add_fake_curl(bin_dir, curl_log)
    restore = add_fake_restore(bin_dir)
    env_file, _, log_dir, _ = write_drill_config(tmp_path)
    lock_file = tmp_path / "state" / "hermes-backup" / "run.lock"
    add_lock_config(env_file, lock_file)

    with hold_lock(lock_file):
        result = subprocess.run(
            ["bash", str(DRILL_SCRIPT), "--config-env", str(env_file), "--restore-command", str(restore)],
            cwd=ROOT,
            env={
                **os.environ,
                "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                "HOME": str(tmp_path / "home"),
                "FAKE_RESTORE_LOG": str(restore_log),
                "FAKE_CURL_LOG": str(curl_log),
                "HERMES_BACKUP_DRILL_ID": "20260705T000000Z",
            },
            text=True,
            capture_output=True,
            check=False,
        )

    output = combined(result)
    assert result.returncode == 0, output
    assert "drill=skipped reason=runtime-lock-held" in output
    assert "No restore or promote command was started" in output
    assert not restore_log.exists()
    log_text = one_daily_log(log_dir)
    payload = alert_message_payload(curl_log.read_text())
    assert "command=drill status=skipped exit=0" in log_text
    assert "Hermes backup restore drill" in payload
    assert "status: SKIP" in payload
    assert "runtime lock busy" in payload


def add_slow_backup_restic(bin_dir: Path, log_file: Path, started_file: Path) -> None:
    make_executable(
        bin_dir / "restic",
        r'''
        #!/usr/bin/env python3
        import json, os, sys, time
        from pathlib import Path
        log = Path(os.environ["FAKE_RESTIC_LOG"])
        args = sys.argv[1:]
        with log.open("a") as f:
            f.write("ARGS " + "\0".join(args) + "\n")
        if args[:1] == ["backup"]:
            Path(os.environ["FAKE_RESTIC_STARTED"]).write_text("started\n")
            time.sleep(30)
            print(json.dumps({"message_type": "summary", "snapshot_id": "fake-snapshot-id"}))
            sys.exit(0)
        if args[:1] == ["forget"]:
            print("forget ok")
            sys.exit(0)
        if args[:1] == ["check"]:
            print("check ok")
            sys.exit(0)
        sys.exit(2)
        ''',
    )


def test_hermes_backup_command_holds_default_lock_across_check_drill_and_backup_contention(tmp_path):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    started = tmp_path / "backup-started"
    curl_log = tmp_path / "curl.log"
    restore_log = tmp_path / "restore.log"
    add_slow_backup_restic(bin_dir, restic_log, started)
    add_fake_curl(bin_dir, curl_log)
    restore = add_fake_restore(bin_dir)
    backup_config_root = tmp_path / "backup-config"
    backup_config_root.mkdir()
    backup_env, _ = write_local_config(backup_config_root)
    check_env = backup_env
    drill_env, _, drill_log_dir, _ = write_drill_config(tmp_path / "drill-config")
    root = fixture_root(tmp_path / "live-root")
    shared_home = tmp_path / "home"
    common_env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
        "HOME": str(shared_home),
        "XDG_STATE_HOME": str(tmp_path / "xdg-state"),
        "HERMES_BACKUP_STATE_DIR": "",
        "FAKE_RESTIC_LOG": str(restic_log),
        "FAKE_RESTIC_STARTED": str(started),
        "FAKE_CURL_LOG": str(curl_log),
        "FAKE_RESTORE_LOG": str(restore_log),
        "HERMES_BACKUP_DRILL_ID": "20260705T000000Z",
    }

    holder = subprocess.Popen(
        [
            "bash",
            str(BACKUP_SCRIPT),
            "--config-env",
            str(backup_env),
            "--root",
            str(root),
            "--staging-parent",
            str(tmp_path / "state" / "hermes-backup" / "staging"),
        ],
        cwd=ROOT,
        env=common_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + 10
        while not started.exists() and time.monotonic() < deadline:
            if holder.poll() is not None:
                stdout, stderr = holder.communicate()
                raise AssertionError(stdout + stderr)
            time.sleep(0.05)
        assert started.exists(), "backup holder did not reach fake restic backup"

        check = subprocess.run(["bash", str(CHECK_SCRIPT), "--config-env", str(check_env)], cwd=ROOT, env=common_env, text=True, capture_output=True, check=False)
        drill = subprocess.run(["bash", str(DRILL_SCRIPT), "--config-env", str(drill_env), "--restore-command", str(restore)], cwd=ROOT, env=common_env, text=True, capture_output=True, check=False)
        second_backup = subprocess.run(
            [
                "bash",
                str(BACKUP_SCRIPT),
                "--config-env",
                str(backup_env),
                "--root",
                str(root),
                "--staging-parent",
                str(tmp_path / "state" / "hermes-backup" / "staging-second"),
            ],
            cwd=ROOT,
            env=common_env,
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        holder.terminate()
        try:
            holder.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            holder.kill()
            holder.communicate()

    assert check.returncode == 0, combined(check)
    assert "check=skipped reason=runtime-lock-held" in combined(check)
    assert drill.returncode == 0, combined(drill)
    assert "drill=skipped reason=runtime-lock-held" in combined(drill)
    assert not restore_log.exists()
    assert second_backup.returncode == 75, combined(second_backup)
    assert "runtime lock busy" in combined(second_backup)
    restic_calls = restic_log.read_text().splitlines()
    assert sum(line.startswith("ARGS backup") for line in restic_calls) == 1
    assert not any(line.startswith("ARGS check") for line in restic_calls)
    assert "command=drill status=skipped exit=0" in one_daily_log(drill_log_dir)


def test_runtime_lock_uses_existing_regular_file_without_truncating_it(tmp_path):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    add_fake_check_restic(bin_dir, restic_log)
    env_file, _ = write_local_config(tmp_path)
    lock_file = tmp_path / "state" / "hermes-backup" / "run.lock"
    lock_file.parent.mkdir(parents=True)
    lock_file.write_text("existing lock metadata must survive\n")
    add_lock_config(env_file, lock_file)

    result = subprocess.run(
        ["bash", str(CHECK_SCRIPT), "--config-env", str(env_file)],
        cwd=ROOT,
        env={**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "HOME": str(tmp_path / "home"), "FAKE_RESTIC_LOG": str(restic_log)},
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, combined(result)
    assert "check=ok repository=configured" in combined(result)
    assert lock_file.read_text() == "existing lock metadata must survive\n"
    assert any(line.startswith("ARGS check") for line in restic_log.read_text().splitlines())


def add_slow_check_restic(bin_dir: Path, log_file: Path, started_file: Path) -> None:
    make_executable(
        bin_dir / "restic",
        f"""#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
log = Path(os.environ["FAKE_RESTIC_LOG"])
args = sys.argv[1:]
with log.open("a") as f:
    f.write("ARGS " + "\\0".join(args) + "\\n")
if args[:1] == ["check"]:
    Path({str(started_file)!r}).write_text("started\\n")
    time.sleep(30)
    print("check ok")
    sys.exit(0)
if args[:1] == ["backup"]:
    print("unexpected backup", file=sys.stderr)
    sys.exit(88)
sys.exit(2)
""",
    )


def add_slow_restore(bin_dir: Path, started_file: Path) -> Path:
    restore = bin_dir / "slow-restore.sh"
    make_executable(
        restore,
        r'''
        #!/usr/bin/env python3
        import os, sys, time
        from pathlib import Path
        log = Path(os.environ["FAKE_RESTORE_LOG"])
        log.write_text("ARGS " + "\0".join(sys.argv[1:]) + "\n")
        Path(os.environ["FAKE_RESTORE_STARTED"]).write_text("started\n")
        time.sleep(30)
        sys.exit(0)
        ''',
    )
    return restore


def wait_for_started(process: subprocess.Popen, started_file: Path) -> None:
    deadline = time.monotonic() + 10
    while not started_file.exists() and time.monotonic() < deadline:
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise AssertionError((stdout or "") + (stderr or ""))
        time.sleep(0.05)
    assert started_file.exists(), "holder command did not reach slow fake operation"


def terminate_holder(process: subprocess.Popen) -> None:
    process.terminate()
    try:
        process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()


def test_restic_check_command_holds_default_lock_against_backup_and_drill_contention(tmp_path):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    started = tmp_path / "check-started"
    curl_log = tmp_path / "curl.log"
    restore_log = tmp_path / "restore.log"
    add_slow_check_restic(bin_dir, restic_log, started)
    add_fake_curl(bin_dir, curl_log)
    restore = add_fake_restore(bin_dir)
    config_root = tmp_path / "config-root"
    config_root.mkdir()
    env_file, _ = write_local_config(config_root)
    drill_env, _, drill_log_dir, _ = write_drill_config(tmp_path / "drill-config")
    root = fixture_root(tmp_path / "live-root")
    common_env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
        "HOME": str(tmp_path / "home"),
        "XDG_STATE_HOME": str(tmp_path / "xdg-state"),
        "HERMES_BACKUP_STATE_DIR": "",
        "FAKE_RESTIC_LOG": str(restic_log),
        "FAKE_RESTIC_STARTED": str(started),
        "FAKE_CURL_LOG": str(curl_log),
        "FAKE_RESTORE_LOG": str(restore_log),
        "HERMES_BACKUP_DRILL_ID": "20260705T000000Z",
    }
    holder = subprocess.Popen(["bash", str(CHECK_SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=common_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_for_started(holder, started)
        backup = subprocess.run(["bash", str(BACKUP_SCRIPT), "--config-env", str(env_file), "--root", str(root), "--staging-parent", str(tmp_path / "staging")], cwd=ROOT, env=common_env, text=True, capture_output=True, check=False)
        drill = subprocess.run(["bash", str(DRILL_SCRIPT), "--config-env", str(drill_env), "--restore-command", str(restore)], cwd=ROOT, env=common_env, text=True, capture_output=True, check=False)
    finally:
        terminate_holder(holder)

    assert backup.returncode == 75, combined(backup)
    assert "runtime lock busy" in combined(backup)
    assert drill.returncode == 0, combined(drill)
    assert "drill=skipped reason=runtime-lock-held" in combined(drill)
    assert not restore_log.exists()
    calls = restic_log.read_text().splitlines()
    assert sum(line.startswith("ARGS check") for line in calls) == 1
    assert not any(line.startswith("ARGS backup") for line in calls)
    assert "command=drill status=skipped exit=0" in one_daily_log(drill_log_dir)


def test_restore_drill_command_holds_default_lock_against_backup_and_check_contention(tmp_path):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    curl_log = tmp_path / "curl.log"
    restore_log = tmp_path / "restore.log"
    started = tmp_path / "restore-started"
    add_fake_check_restic(bin_dir, restic_log)
    add_fake_curl(bin_dir, curl_log)
    restore = add_slow_restore(bin_dir, started)
    config_root = tmp_path / "config-root"
    config_root.mkdir()
    env_file, _ = write_local_config(config_root)
    drill_env, _, _, _ = write_drill_config(tmp_path / "drill-config")
    root = fixture_root(tmp_path / "live-root")
    common_env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
        "HOME": str(tmp_path / "home"),
        "XDG_STATE_HOME": str(tmp_path / "xdg-state"),
        "HERMES_BACKUP_STATE_DIR": "",
        "FAKE_RESTIC_LOG": str(restic_log),
        "FAKE_CURL_LOG": str(curl_log),
        "FAKE_RESTORE_LOG": str(restore_log),
        "FAKE_RESTORE_STARTED": str(started),
        "HERMES_BACKUP_DRILL_ID": "20260705T000000Z",
    }
    holder = subprocess.Popen(["bash", str(DRILL_SCRIPT), "--config-env", str(drill_env), "--restore-command", str(restore), "--keep-artifacts"], cwd=ROOT, env=common_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_for_started(holder, started)
        check = subprocess.run(["bash", str(CHECK_SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=common_env, text=True, capture_output=True, check=False)
        backup = subprocess.run(["bash", str(BACKUP_SCRIPT), "--config-env", str(env_file), "--root", str(root), "--staging-parent", str(tmp_path / "staging")], cwd=ROOT, env=common_env, text=True, capture_output=True, check=False)
    finally:
        terminate_holder(holder)

    assert check.returncode == 0, combined(check)
    assert "check=skipped reason=runtime-lock-held" in combined(check)
    assert backup.returncode == 75, combined(backup)
    assert "runtime lock busy" in combined(backup)
    assert not restic_log.exists()
