import os
import pwd
import shutil
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") or "/usr/bin/bash"
PREFLIGHT = ROOT / "scripts" / "preflight.sh"
REQUIRED_COMMANDS = ["restic", "sqlite3", "rsync", "curl", "systemctl"]


def make_executable(path: Path, body: str = "#!/bin/sh\necho \"${0##*/}\" >> \"$HERMES_BACKUP_FAKE_COMMAND_LOG\"\nexit 97\n") -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def make_fake_path(tmp_path: Path, commands=REQUIRED_COMMANDS, *, systemctl_ok=True) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in commands:
        if command == "systemctl":
            if systemctl_ok:
                body = "#!/bin/sh\nif [ \"${1:-}\" = --user ] && [ \"${2:-}\" = list-unit-files ]; then exit 0; fi\nexit 1\n"
            else:
                body = "#!/bin/sh\nexit 1\n"
            make_executable(bin_dir / command, body)
        else:
            make_executable(bin_dir / command)
    return bin_dir


def run_preflight(
    tmp_path: Path,
    *,
    commands=REQUIRED_COMMANDS,
    systemctl_ok=True,
    xdg_config_home=None,
    existing_config_home=False,
    env_overrides=None,
):
    fake_home = tmp_path / "home" / "agent"
    fake_home.mkdir(parents=True)
    fake_config_home = xdg_config_home or (fake_home / ".config")
    if existing_config_home:
        fake_config_home.mkdir(parents=True)
    fake_bin = make_fake_path(tmp_path, commands=commands, systemctl_ok=systemctl_ok)
    command_log = tmp_path / "fake-command-executions.log"
    current_user = pwd.getpwuid(os.geteuid()).pw_name
    env = {
        **os.environ,
        "PATH": str(fake_bin),
        "HOME": str(fake_home),
        "XDG_CONFIG_HOME": str(fake_config_home),
        "HERMES_BACKUP_EXPECTED_HOME": str(fake_home),
        "HERMES_BACKUP_EXPECTED_USER": current_user,
        "HERMES_BACKUP_EXPECTED_EUID": str(os.geteuid()),
        "HERMES_BACKUP_FAKE_COMMAND_LOG": str(command_log),
        "B2_APPLICATION_KEY": "SHOULD_NOT_APPEAR_IN_PREFLIGHT_OUTPUT",
        "RESTIC_PASSWORD": "SHOULD_NOT_APPEAR_IN_PREFLIGHT_OUTPUT",
        "TELEGRAM_BOT_TOKEN": "123456789:***",
    }
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        [BASH, str(PREFLIGHT), "--check"],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def assert_no_secret_values(output: str) -> None:
    assert "SHOULD_NOT_APPEAR" not in output
    assert "123456789:" not in output


def test_preflight_script_has_valid_bash_syntax():
    result = subprocess.run(
        [BASH, "-n", str(PREFLIGHT)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    assert result.returncode == 0, result.stdout


def test_preflight_passes_with_fixture_commands_and_writable_config_parent(tmp_path):
    result = run_preflight(tmp_path)

    assert result.returncode == 0, result.stdout
    output = result.stdout.lower()
    for command in REQUIRED_COMMANDS:
        assert f"ok: command available: {command}" in output
    assert "ok: systemctl --user available" in output
    assert "ok: user config directory parent is writable" in output
    assert "preflight passed" in output
    assert not (tmp_path / "fake-command-executions.log").exists()
    assert_no_secret_values(result.stdout)


def test_preflight_reports_all_missing_required_commands_without_printing_secrets(tmp_path):
    result = run_preflight(tmp_path, commands=["systemctl"])

    assert result.returncode != 0
    output = result.stdout.lower()
    for command in ["restic", "sqlite3", "rsync", "curl"]:
        assert f"missing: required command not found: {command}" in output
    assert "install missing tools locally" in output
    assert_no_secret_values(result.stdout)


def test_preflight_reports_systemctl_user_unavailable(tmp_path):
    result = run_preflight(tmp_path, systemctl_ok=False)

    assert result.returncode != 0
    assert "fail: systemctl --user is not available" in result.stdout.lower()
    assert_no_secret_values(result.stdout)


def test_preflight_accepts_existing_writable_config_home(tmp_path):
    result = run_preflight(tmp_path, existing_config_home=True)

    assert result.returncode == 0, result.stdout
    assert "ok: user config directory parent is writable" in result.stdout.lower()
    assert_no_secret_values(result.stdout)


def test_preflight_rejects_config_home_that_is_a_file(tmp_path):
    config_file = tmp_path / "config-file"
    config_file.write_text("not a directory")
    result = run_preflight(tmp_path, xdg_config_home=config_file)

    assert result.returncode != 0
    assert "fail: user config directory path exists but is not a directory" in result.stdout.lower()
    assert_no_secret_values(result.stdout)


def test_preflight_requires_writable_config_parent(tmp_path):
    read_only_parent = tmp_path / "readonly-parent"
    read_only_parent.mkdir()
    read_only_parent.chmod(0o500)
    try:
        result = run_preflight(tmp_path, xdg_config_home=read_only_parent / "hermes-backup")
    finally:
        read_only_parent.chmod(0o700)

    assert result.returncode != 0
    assert "fail: user config directory parent is not writable" in result.stdout.lower()
    assert_no_secret_values(result.stdout)


def test_preflight_requires_expected_owner_user(tmp_path):
    result = run_preflight(
        tmp_path,
        env_overrides={"HERMES_BACKUP_EXPECTED_USER": "definitely-not-the-current-user"},
    )

    assert result.returncode != 0
    assert "fail: current user does not match expected hermes vm owner" in result.stdout.lower()
    assert_no_secret_values(result.stdout)
