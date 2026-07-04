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


def make_executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def fake_bin(tmp_path: Path, *, systemctl_body=None) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in ["restic", "sqlite3", "rsync", "curl"]:
        make_executable(bin_dir / command, "#!/bin/sh\nexit 0\n")
    body = systemctl_body or "#!/bin/sh\nif [ \"${1:-}\" = --user ] && [ \"${2:-}\" = list-unit-files ]; then exit 0; fi\nexit 1\n"
    make_executable(bin_dir / "systemctl", body)
    return bin_dir


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def combined(result) -> str:
    return result.stdout + result.stderr


def assert_no_dummy_secrets(output: str) -> None:
    for value in DUMMY_ENV.values():
        assert value not in output


def run_install(tmp_path: Path, *, systemctl_body=None, extra_env=None):
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
    result = subprocess.run(
        ["bash", str(INSTALL), "--config-dir", str(config_dir), "--non-interactive"],
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
    assert "step 1/4: running offline preflight" in output
    assert "fail: systemctl --user is not available" in output
    assert "step 2/4" not in output
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
    assert "step 2/4" not in output
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
    assert "Step 1/4" not in combined(result)
    assert not repo_config.exists()
    assert_no_dummy_secrets(combined(result))


def test_install_rejects_unsafe_template_destination_before_config_prompt(tmp_path):
    home = tmp_path / "home" / "agent"
    template_dir = home / ".config" / "hermes-backup" / "systemd-templates"
    bad_dest = template_dir / "hermes-backup-backup.service.template"
    bad_dest.mkdir(parents=True)
    (home / ".config" / "hermes-backup").chmod(0o700)
    template_dir.chmod(0o700)
    result, _home, config_dir, _state_home = run_install(tmp_path)
    assert result.returncode != 0
    assert "refusing unsafe inert systemd template destination" in combined(result).lower()
    assert "step 3/4" not in combined(result).lower()
    assert not (config_dir / "hermes-backup.env").exists()
    assert_no_dummy_secrets(combined(result))


def test_install_bootstraps_temp_home_with_expected_local_files_only(tmp_path):
    result, home, config_dir, state_home = run_install(tmp_path)
    assert result.returncode == 0, combined(result)
    env_file = config_dir / "hermes-backup.env"
    password_file = config_dir / "restic-password"
    log_dir = state_home / "hermes-backup" / "logs"
    staging_dir = state_home / "hermes-backup" / "staging"
    restore_dir = home / "restore" / "hermes-vm-backup"
    template_dir = config_dir / "systemd-templates"
    for path in [config_dir, log_dir, staging_dir, restore_dir, template_dir]:
        assert path.is_dir()
        assert mode(path) == 0o700
    for path in [env_file, password_file, *template_dir.iterdir()]:
        assert path.is_file()
        assert mode(path) == 0o600
    env_text = env_file.read_text()
    assert f"HERMES_BACKUP_LOG_DIR='{log_dir}'" in env_text
    assert f"HERMES_BACKUP_STAGING_DIR='{staging_dir}'" in env_text
    assert sorted(path.name for path in template_dir.iterdir()) == [
        "hermes-backup-backup.service.template",
        "hermes-backup-backup.timer.template",
    ]
    output = combined(result)
    assert_no_dummy_secrets(output)
    assert "Backup execution is NOT implemented or active" in output
    assert "No restic init" in output
    assert "Hermes cron" in output


def test_install_does_not_enable_or_start_systemd_timers(tmp_path):
    calls = tmp_path / "systemctl-calls.log"
    body = f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {calls}\nif [ \"${{1:-}}\" = --user ] && [ \"${{2:-}}\" = list-unit-files ]; then exit 0; fi\nexit 42\n"
    result, _home, _config_dir, _state_home = run_install(tmp_path, systemctl_body=body)
    assert result.returncode == 0, combined(result)
    calls_text = calls.read_text()
    assert "--user list-unit-files" in calls_text
    assert all(word not in calls_text for word in ["enable", "start", "restart"])
    assert "timer" not in calls_text.lower()
    assert_no_dummy_secrets(combined(result))
