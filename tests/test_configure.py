import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "configure.sh"

DUMMY_ENV = {
    "B2_ACCOUNT_ID": "DUMMY_B2_KEY_ID_NOT_REAL",
    "B2_ACCOUNT_KEY": "DUMMY_B2_APPLICATION_KEY_NOT_REAL",
    "RESTIC_REPOSITORY": "b2:dummy-hermes-backup:test-fixture",
    "RESTIC_PASSWORD": "DUMMY_RESTIC_PASSWORD_NOT_REAL",
    "TELEGRAM_BOT_TOKEN": "DUMMY_TELEGRAM_BOT_TOKEN_NOT_REAL",
    "TELEGRAM_CHAT_ID": "DUMMY_TELEGRAM_CHAT_ID_NOT_REAL",
}


def run_configure(tmp_path, extra_env=None, args=None):
    home = tmp_path / "home"
    config_dir = tmp_path / "xdg" / "hermes-backup"
    home.mkdir()
    env = os.environ.copy()
    env.update(DUMMY_ENV)
    env.update({"HOME": str(home), "XDG_CONFIG_HOME": str(tmp_path / "xdg")})
    if extra_env:
        env.update(extra_env)

    cmd = ["bash", str(SCRIPT), "--config-dir", str(config_dir), "--non-interactive"]
    if args:
        cmd = ["bash", str(SCRIPT), *args]
    result = subprocess.run(
        cmd,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, config_dir


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def combined_output(result):
    return result.stdout + result.stderr


def test_configure_writes_local_files_with_owner_only_permissions(tmp_path):
    result, config_dir = run_configure(tmp_path)

    assert result.returncode == 0, result.stderr
    env_file = config_dir / "hermes-backup.env"
    password_file = config_dir / "restic-password"

    assert mode(config_dir) == 0o700
    assert mode(env_file) == 0o600
    assert mode(password_file) == 0o600

    env_text = env_file.read_text()
    assert "B2_ACCOUNT_ID='DUMMY_B2_KEY_ID_NOT_REAL'" in env_text
    assert "B2_ACCOUNT_KEY='DUMMY_B2_APPLICATION_KEY_NOT_REAL'" in env_text
    assert "RESTIC_REPOSITORY='b2:dummy-hermes-backup:test-fixture'" in env_text
    assert f"RESTIC_PASSWORD_FILE='{password_file}'" in env_text
    assert "TELEGRAM_BOT_TOKEN='DUMMY_TELEGRAM_BOT_TOKEN_NOT_REAL'" in env_text
    assert "TELEGRAM_CHAT_ID='DUMMY_TELEGRAM_CHAT_ID_NOT_REAL'" in env_text
    assert password_file.read_text() == "DUMMY_RESTIC_PASSWORD_NOT_REAL\n"


def test_configure_output_redacts_dummy_secret_values(tmp_path):
    result, _ = run_configure(tmp_path)

    assert result.returncode == 0, result.stderr
    output = combined_output(result)
    for value in DUMMY_ENV.values():
        assert value not in output
    assert "Created local env file" in output
    assert "Secret values will not be printed" in output


def test_configure_output_redacts_dummy_secret_values_with_xtrace(tmp_path):
    home = tmp_path / "home"
    config_dir = tmp_path / "xdg" / "hermes-backup"
    home.mkdir()
    env = os.environ.copy()
    env.update(DUMMY_ENV)
    env.update({"HOME": str(home), "XDG_CONFIG_HOME": str(tmp_path / "xdg")})

    result = subprocess.run(
        [
            "bash",
            "-x",
            str(SCRIPT),
            "--config-dir",
            str(config_dir),
            "--non-interactive",
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    output = combined_output(result)
    for value in DUMMY_ENV.values():
        assert value not in output


def test_configure_rejects_empty_required_values(tmp_path):
    result, _ = run_configure(tmp_path, extra_env={"RESTIC_PASSWORD": ""})

    assert result.returncode != 0
    output = combined_output(result)
    assert "RESTIC_PASSWORD is required" in output
    assert "DUMMY_B2_APPLICATION_KEY_NOT_REAL" not in output


def test_configure_refuses_to_write_inside_repository(tmp_path):
    inside_repo_config = ROOT / "config" / "local-test-config"
    result, _ = run_configure(
        tmp_path,
        args=["--config-dir", str(inside_repo_config), "--non-interactive"],
    )

    assert result.returncode != 0
    assert "refusing to write local secret config inside the repository" in combined_output(result)
    assert not inside_repo_config.exists()


def test_configure_refuses_symlinked_path_into_repository(tmp_path):
    repo_link = tmp_path / "repo-link"
    repo_link.symlink_to(ROOT, target_is_directory=True)
    linked_config = repo_link / "config" / "symlink-local-test-config"

    result, _ = run_configure(
        tmp_path,
        args=["--config-dir", str(linked_config), "--non-interactive"],
    )

    assert result.returncode != 0
    assert "refusing to write local secret config inside the repository" in combined_output(result)
    assert not (ROOT / "config" / "symlink-local-test-config").exists()


def test_configure_rejects_relative_config_dir(tmp_path):
    result, _ = run_configure(
        tmp_path,
        args=["--config-dir", "relative-config", "--non-interactive"],
    )

    assert result.returncode != 0
    assert "config directory must be an absolute path" in combined_output(result)
