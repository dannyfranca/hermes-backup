import os
import pwd
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "install.sh"
DUMMY_ENV = {
    "B2_ACCOUNT_ID": "DUMMY_INSTALL_B2_KEY_ID_NOT_REAL",
    "B2_ACCOUNT_KEY": "DUMMY_INSTALL_B2_APPLICATION_KEY_NOT_REAL",
    "RESTIC_REPOSITORY": "b2:dummy-hermes-backup:install-fixture",
    "RESTIC_PASSWORD": "DUMMY_INSTALL_RESTIC_PASSWORD_NOT_REAL",
    "TELEGRAM_BOT_TOKEN": "DUMMY_INSTALL_TELEGRAM_BOT_TOKEN_NOT_REAL",
    "TELEGRAM_CHAT_ID": "DUMMY_INSTALL_TELEGRAM_CHAT_ID_NOT_REAL",
}
UNIT_NAMES = [
    "hermes-backup-backup.service",
    "hermes-backup-backup.timer",
    "hermes-backup-check.service",
    "hermes-backup-check.timer",
    "hermes-backup-restore-drill.service",
    "hermes-backup-restore-drill.timer",
]


def make_executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def fake_bin(tmp_path: Path, *, systemctl_body=None) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    for command in ["restic", "sqlite3", "rsync", "curl"]:
        make_executable(bin_dir / command, "#!/bin/sh\nexit 0\n")
    body = systemctl_body or """#!/bin/sh
case "$*" in
  "--user list-unit-files"*) exit 0 ;;
  "--user daemon-reload") exit 0 ;;
  "--user enable hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer") exit 0 ;;
esac
exit 42
"""
    make_executable(bin_dir / "systemctl", body)
    return bin_dir


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def combined(result) -> str:
    return result.stdout + result.stderr


def assert_no_dummy_secrets(output: str) -> None:
    for value in DUMMY_ENV.values():
        assert value not in output


def run_install(tmp_path: Path, *, systemctl_body=None, extra_env=None, extra_args=None):
    home = tmp_path / "home" / "agent"
    config_dir = home / ".config" / "hermes-backup"
    state_home = home / ".local" / "state"
    home.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(DUMMY_ENV)
    env.update(
        HOME=str(home),
        XDG_CONFIG_HOME=str(home / ".config"),
        XDG_STATE_HOME=str(state_home),
        PATH=f"{fake_bin(tmp_path, systemctl_body=systemctl_body)}{os.pathsep}{os.environ.get('PATH', '')}",
        HERMES_BACKUP_EXPECTED_HOME=str(home),
        HERMES_BACKUP_EXPECTED_USER=pwd.getpwuid(os.geteuid()).pw_name,
        HERMES_BACKUP_EXPECTED_EUID=str(os.geteuid()),
    )
    if extra_env:
        env.update(extra_env)
    args = ["bash", str(INSTALL), "--config-dir", str(config_dir), "--non-interactive"]
    if extra_args:
        args.extend(extra_args)
    result = subprocess.run(
        args,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, home, config_dir, state_home


def test_install_has_valid_bash_syntax():
    result = subprocess.run(["bash", "-n", str(INSTALL)], cwd=ROOT, text=True, capture_output=True, check=False)
    assert result.returncode == 0, combined(result)


def test_install_fails_before_config_prompt_when_preflight_fails(tmp_path):
    result, _home, config_dir, state_home = run_install(tmp_path, systemctl_body="#!/bin/sh\nexit 1\n")
    output = combined(result).lower()
    assert result.returncode != 0
    assert "step 1/5: running offline preflight" in output
    assert "fail: systemctl --user is not available" in output
    assert "step 2/5" not in output
    assert not config_dir.exists()
    assert not state_home.exists()
    assert_no_dummy_secrets(combined(result))


def test_install_validates_local_paths_before_config_prompt(tmp_path):
    bad_state_home = tmp_path / "state-file"
    bad_state_home.write_text("not a directory")
    result, _home, config_dir, _state_home = run_install(tmp_path, extra_env={"XDG_STATE_HOME": str(bad_state_home)})
    output = combined(result).lower()
    assert result.returncode != 0
    assert "local state directory parent is not a directory" in output
    assert "step 2/5" not in output
    assert not config_dir.exists()
    assert_no_dummy_secrets(combined(result))


def test_install_rejects_repo_local_config_dir_before_side_effects(tmp_path):
    repo_config = ROOT / "config" / "install-local-test-config"
    result = subprocess.run(
        ["bash", str(INSTALL), "--config-dir", str(repo_config), "--non-interactive"],
        cwd=ROOT,
        env={**os.environ, **DUMMY_ENV, "HOME": str(tmp_path / "home")},
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert "refusing config directory inside the repository" in combined(result)
    assert "Step 1/5" not in combined(result)
    assert not repo_config.exists()
    assert_no_dummy_secrets(combined(result))


def test_install_rejects_config_paths_that_cannot_be_rendered_safely_for_systemd(tmp_path):
    home = tmp_path / "home" / "agent"
    config_dir = tmp_path / "config with spaces" / "hermes-backup"
    result = subprocess.run(
        ["bash", str(INSTALL), "--config-dir", str(config_dir), "--non-interactive"],
        cwd=ROOT,
        env={
            **os.environ,
            **DUMMY_ENV,
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
            "PATH": f"{fake_bin(tmp_path)}{os.pathsep}{os.environ.get('PATH', '')}",
        },
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert "config directory contains characters unsupported by this systemd unit renderer" in combined(result)
    assert "Step 1/5" not in combined(result)
    assert not config_dir.exists()
    assert_no_dummy_secrets(combined(result))


def test_install_rejects_unsafe_systemd_unit_destination(tmp_path):
    home = tmp_path / "home" / "agent"
    unit_dir = home / ".config" / "systemd" / "user"
    bad_dest = unit_dir / "hermes-backup-backup.service"
    bad_dest.mkdir(parents=True)
    unit_dir.chmod(0o700)
    result, _home, config_dir, _state_home = run_install(tmp_path)
    assert result.returncode != 0
    assert "systemd unit destination exists but is not a regular file" in combined(result).lower()
    assert "step 3/5" not in combined(result).lower()
    assert not (config_dir / "hermes-backup.env").exists()
    assert_no_dummy_secrets(combined(result))


def test_install_bootstraps_temp_home_with_rendered_systemd_units(tmp_path):
    result, home, config_dir, state_home = run_install(tmp_path)
    assert result.returncode == 0, combined(result)
    env_file = config_dir / "hermes-backup.env"
    password_file = config_dir / "restic-password"
    log_dir = state_home / "hermes-backup" / "logs"
    staging_dir = state_home / "hermes-backup" / "staging"
    restore_dir = home / "restore" / "hermes-vm-backup"
    unit_dir = home / ".config" / "systemd" / "user"
    for path in [config_dir, log_dir, staging_dir, restore_dir, unit_dir]:
        assert path.is_dir()
        assert mode(path) == 0o700
    for path in [env_file, password_file]:
        assert path.is_file()
        assert mode(path) == 0o600
    expected_unit_text = {
        "hermes-backup-backup.service": [
            f"WorkingDirectory={ROOT}",
            f"ExecStart={ROOT}/scripts/backup.sh --config-env {config_dir / 'hermes-backup.env'}",
        ],
        "hermes-backup-check.service": [
            f"WorkingDirectory={ROOT}",
            f"ExecStart={ROOT}/scripts/restic-check.sh --config-env {config_dir / 'hermes-backup.env'}",
        ],
        "hermes-backup-backup.timer": [
            "OnCalendar=*-*-* 03:30:00",
            "RandomizedDelaySec=30m",
            "Unit=hermes-backup-backup.service",
            "WantedBy=timers.target",
        ],
        "hermes-backup-check.timer": [
            "OnCalendar=Sun *-*-* 08:30:00",
            "RandomizedDelaySec=45m",
            "Unit=hermes-backup-check.service",
            "WantedBy=timers.target",
        ],
        "hermes-backup-restore-drill.service": [
            f"WorkingDirectory={ROOT}",
            f"ExecStart={ROOT}/scripts/restore-drill.sh --config-env {config_dir / 'hermes-backup.env'}",
        ],
        "hermes-backup-restore-drill.timer": [
            "OnCalendar=Sun *-*-01..07 10:30:00",
            "RandomizedDelaySec=2h",
            "Unit=hermes-backup-restore-drill.service",
            "WantedBy=timers.target",
        ],
    }
    for unit_name in UNIT_NAMES:
        unit = unit_dir / unit_name
        assert unit.is_file()
        assert mode(unit) == 0o644
        text = unit.read_text()
        assert "EXAMPLE_" not in text
        for needle in expected_unit_text[unit_name]:
            assert needle in text
        assert "promote.sh" not in text
        if unit_name != "hermes-backup-restore-drill.service":
            assert "restore.sh" not in text
        assert "promote.sh" not in text
        if unit_name.endswith(".service"):
            assert text.count("\nExecStart=") == 1
            assert "\nExecStartPre=" not in text
            assert "\nExecStartPost=" not in text
            assert "\nEnvironmentFile=" not in text
        if unit_name.endswith(".timer"):
            assert text.count("\nOnCalendar=") == 1
            assert text.count("\nUnit=") == 1
        for secret in DUMMY_ENV.values():
            assert secret not in text
    env_text = env_file.read_text()
    assert f"HERMES_BACKUP_LOG_DIR='{log_dir}'" in env_text
    assert f"HERMES_BACKUP_STAGING_DIR='{staging_dir}'" in env_text
    output = combined(result)
    assert_no_dummy_secrets(output)
    assert "Rendered units but did not enable timers" in output
    assert "No backup/check/restore/promote/drill command was run by install" in output
    assert "Hermes cron" in output


def test_install_is_idempotent_and_reuses_existing_local_config(tmp_path):
    first, home, config_dir, _state_home = run_install(tmp_path)
    assert first.returncode == 0, combined(first)
    env_file = config_dir / "hermes-backup.env"
    original = env_file.read_text()
    unit_dir = home / ".config" / "systemd" / "user"
    check_timer = unit_dir / "hermes-backup-check.timer"
    check_timer.write_text("[Timer]\nOnCalendar=bad-stale-value\nUnit=wrong.service\n")
    second, _home, _config_dir, _state_home = run_install(tmp_path)
    assert second.returncode == 0, combined(second)
    assert env_file.read_text() == original
    assert "Reusing existing local config files" in combined(second)
    restored_timer = check_timer.read_text()
    assert "OnCalendar=Sun *-*-* 08:30:00" in restored_timer
    assert "Unit=hermes-backup-check.service" in restored_timer
    assert "bad-stale-value" not in restored_timer
    assert_no_dummy_secrets(combined(second))


def test_install_does_not_enable_or_start_systemd_timers_by_default(tmp_path):
    calls = tmp_path / "systemctl-calls.log"
    body = f"""#!/bin/sh
printf '%s\n' "$*" >> {calls}
case "$*" in
  "--user list-unit-files"*) exit 0 ;;
  "--user daemon-reload") exit 0 ;;
esac
exit 42
"""
    result, _home, _config_dir, _state_home = run_install(tmp_path, systemctl_body=body)
    assert result.returncode == 0, combined(result)
    calls_text = calls.read_text()
    assert "--user list-unit-files" in calls_text
    assert "--user daemon-reload" in calls_text
    assert "enable" not in calls_text
    assert "start" not in calls_text
    assert "restart" not in calls_text
    assert_no_dummy_secrets(combined(result))


def test_install_enable_timers_requires_rendered_verified_units(tmp_path):
    calls = tmp_path / "systemctl-calls.log"
    expected_home = tmp_path / "home" / "agent"
    body = f"""#!/bin/sh
printf '%s\n' "$*" >> {calls}
case "$*" in
  "--user list-unit-files"*) exit 0 ;;
  "--user daemon-reload") exit 0 ;;
  "--user enable hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer")
    grep -F "ExecStart={ROOT}/scripts/backup.sh --config-env {expected_home}/.config/hermes-backup/hermes-backup.env" {expected_home}/.config/systemd/user/hermes-backup-backup.service >/dev/null || exit 44
    grep -F "ExecStart={ROOT}/scripts/restic-check.sh --config-env {expected_home}/.config/hermes-backup/hermes-backup.env" {expected_home}/.config/systemd/user/hermes-backup-check.service >/dev/null || exit 45
    grep -F "OnCalendar=*-*-* 03:30:00" {expected_home}/.config/systemd/user/hermes-backup-backup.timer >/dev/null || exit 46
    grep -F "OnCalendar=Sun *-*-* 08:30:00" {expected_home}/.config/systemd/user/hermes-backup-check.timer >/dev/null || exit 47
    grep -F "ExecStart={ROOT}/scripts/restore-drill.sh --config-env {expected_home}/.config/hermes-backup/hermes-backup.env" {expected_home}/.config/systemd/user/hermes-backup-restore-drill.service >/dev/null || exit 48
    grep -F "OnCalendar=Sun *-*-01..07 10:30:00" {expected_home}/.config/systemd/user/hermes-backup-restore-drill.timer >/dev/null || exit 49
    exit 0 ;;
esac
exit 42
"""
    result, home, _config_dir, _state_home = run_install(tmp_path, systemctl_body=body, extra_args=["--enable-timers"])
    assert result.returncode == 0, combined(result)
    calls_lines = calls.read_text().splitlines()
    assert calls_lines[-2:] == [
        "--user daemon-reload",
        "--user enable hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer",
    ]
    unit_dir = home / ".config" / "systemd" / "user"
    assert all((unit_dir / unit).is_file() for unit in UNIT_NAMES)
    assert "Enabled user timers for next user-manager activation: hermes-backup-backup.timer hermes-backup-check.timer hermes-backup-restore-drill.timer" in combined(result)
    assert_no_dummy_secrets(combined(result))


def test_install_rejects_enable_timers_with_custom_systemd_dir(tmp_path):
    custom_unit_dir = tmp_path / "custom-systemd-user"
    result, _home, _config_dir, _state_home = run_install(tmp_path, extra_args=["--systemd-user-dir", str(custom_unit_dir), "--enable-timers"])
    assert result.returncode != 0
    output = combined(result)
    assert "--enable-timers cannot be combined with --systemd-user-dir" in output
    assert "Step 1/5" not in output
    assert not custom_unit_dir.exists()
    assert_no_dummy_secrets(output)


def test_install_custom_systemd_dir_renders_without_daemon_reload(tmp_path):
    calls = tmp_path / "systemctl-calls.log"
    body = f"""#!/bin/sh
printf '%s\n' "$*" >> {calls}
case "$*" in
  "--user list-unit-files"*) exit 0 ;;
esac
exit 42
"""
    custom_unit_dir = tmp_path / "custom-systemd-user"
    result, _home, _config_dir, _state_home = run_install(tmp_path, systemctl_body=body, extra_args=["--systemd-user-dir", str(custom_unit_dir)])
    assert result.returncode == 0, combined(result)
    assert all((custom_unit_dir / unit).is_file() for unit in UNIT_NAMES)
    calls_text = calls.read_text()
    assert "--user list-unit-files" in calls_text
    assert "daemon-reload" not in calls_text
    assert "enable" not in calls_text
    assert "Custom systemd user dir render requested; skipped systemctl --user daemon-reload." in combined(result)
    assert_no_dummy_secrets(combined(result))
