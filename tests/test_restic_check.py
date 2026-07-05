import os
import shlex
import stat
import subprocess
from pathlib import Path

from test_backup import DUMMY_ENV, RESTIC_PASSWORD, write_local_config
from test_stage import fake_bin, make_executable

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "restic-check.sh"

def combined(result) -> str:
    return result.stdout + result.stderr

def add_fake_restic(bin_dir: Path, log_file: Path) -> None:
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
            f.write("ENV " + " ".join(
                f"{name}={'set' if os.environ.get(name) else 'missing'}"
                for name in [
                    "B2_ACCOUNT_ID",
                    "B2_ACCOUNT_KEY",
                    "RESTIC_REPOSITORY",
                    "RESTIC_PASSWORD_FILE",
                    "RESTIC_PASSWORD",
                    "RESTIC_PASSWORD_COMMAND",
                    "TELEGRAM_BOT_TOKEN",
                    "TELEGRAM_CHAT_ID",
                ]
            ) + "\n")
        if args[:1] == ["check"]:
            if os.environ.get("FAKE_RESTIC_CHECK_FAIL") == "1":
                print("repository broken but repairable", file=sys.stderr)
                print("secret echo " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
                print("repo echo " + os.environ.get("RESTIC_REPOSITORY", "missing"), file=sys.stderr)
                if os.environ.get("TELEGRAM_BOT_TOKEN"):
                    print("telegram token echo " + os.environ["TELEGRAM_BOT_TOKEN"], file=sys.stderr)
                if os.environ.get("TELEGRAM_CHAT_ID"):
                    print("telegram chat echo " + os.environ["TELEGRAM_CHAT_ID"], file=sys.stderr)
                if os.environ.get("FAKE_RESTIC_STDERR_SECRET"):
                    print("configured secret echo " + os.environ["FAKE_RESTIC_STDERR_SECRET"], file=sys.stderr)
                sys.exit(37)
            print("check ok")
            sys.exit(0)
        sys.exit(2)
        ''',
    )

def fake_check_env(tmp_path: Path, bin_dir: Path, log_file: Path, **extra: str) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(tmp_path / "home"),
            "FAKE_RESTIC_LOG": str(log_file),
            **extra,
        }
    )
    return env

def run_check(tmp_path: Path, *, extra_env: dict[str, str] | None = None, mode_bits: int = 0o600):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env_file, _ = write_local_config(tmp_path, mode_bits=mode_bits)
    env = fake_check_env(tmp_path, bin_dir, log_file)
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--config-env", str(env_file)],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, log_file

def assert_no_secret_values(output: str) -> None:
    for value in [*DUMMY_ENV.values(), RESTIC_PASSWORD]:
        assert value not in output

def test_restic_check_script_has_valid_bash_syntax_and_is_executable():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=ROOT, text=True, capture_output=True, check=False)

    assert result.returncode == 0, combined(result)
    assert SCRIPT.stat().st_mode & stat.S_IXUSR

def test_restic_check_refuses_missing_local_env_file_before_restic(tmp_path):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_check_env(tmp_path, bin_dir, log_file)
    missing_env = tmp_path / "missing.env"

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(missing_env)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode == 64
    output = combined(result)
    assert "local env file not found" in output
    assert not log_file.exists()
    assert_no_secret_values(output)

def test_restic_check_refuses_unsafe_local_env_permissions(tmp_path):
    result, log_file = run_check(tmp_path, mode_bits=0o644)

    assert result.returncode == 64
    output = combined(result)
    assert "local env file permissions are unsafe" in output
    assert "chmod 600" in output
    assert not log_file.exists()
    assert_no_secret_values(output)

def test_restic_check_redacts_restic_password_file_path_on_config_error(tmp_path):
    env_file, password_file = write_local_config(tmp_path)
    password_file.chmod(0o400)
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_check_env(tmp_path, bin_dir, log_file)

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = combined(result)

    assert result.returncode == 64
    assert "local restic password file permissions are unsafe" in output
    assert "[redacted:RESTIC_PASSWORD_FILE]" in output
    assert str(password_file) not in output
    assert not log_file.exists()

def test_restic_check_missing_restic_is_dependency_error_not_config_error(tmp_path):
    env_file, _ = write_local_config(tmp_path)
    bin_dir = fake_bin(tmp_path)
    make_executable(
        bin_dir / "stat",
        r'''
        #!/usr/bin/bash
        /usr/bin/stat "$@"
        ''',
    )
    env = fake_check_env(tmp_path, bin_dir, tmp_path / "restic.log")
    env["PATH"] = str(bin_dir)

    result = subprocess.run(["/usr/bin/bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = combined(result)

    assert result.returncode == 127
    assert "restic is required for check" in output

def test_restic_check_success_runs_restic_check_without_leaking_secrets(tmp_path):
    result, log_file = run_check(
        tmp_path,
        extra_env={"RESTIC_PASSWORD": "INHERITED_PASSWORD_MUST_NOT_BE_USED", "RESTIC_PASSWORD_COMMAND": "echo inherited"},
    )
    output = combined(result)

    assert result.returncode == 0, output
    assert "Hermes backup restic check" in output
    assert "check=ok repository=configured" in output
    assert "No B2 keys, restic passwords, Telegram tokens, repository URLs, file contents, or backup archives were printed." in output
    assert_no_secret_values(output)

    log = log_file.read_text().splitlines()
    check_args = log[0].split(" ", 1)[1].split("\0")
    assert check_args == ["check"]
    assert "B2_ACCOUNT_KEY=set" in log[1]
    assert "RESTIC_PASSWORD_FILE=set" in log[1]
    assert "RESTIC_PASSWORD=missing" in log[1]
    assert "RESTIC_PASSWORD_COMMAND=missing" in log[1]

def test_restic_check_failure_propagates_exit_and_redacts_status_text(tmp_path):
    result, log_file = run_check(tmp_path, extra_env={"FAKE_RESTIC_CHECK_FAIL": "1"})
    output = combined(result)

    assert result.returncode == 37
    assert "check=failed exit=37 repository=configured" in output
    assert "repository broken but repairable" in output
    assert "secret echo [redacted:B2_ACCOUNT_KEY]" in output
    assert "repo echo [redacted:RESTIC_REPOSITORY]" in output
    assert_no_secret_values(output)
    assert any(line.startswith("ARGS check") for line in log_file.read_text().splitlines())

def test_restic_check_redacts_repository_values_with_glob_characters(tmp_path):
    env_file, _ = write_local_config(tmp_path)
    raw_repository = "b2:dummy-[repo]:backup-test-fixture"
    env_file.write_text(env_file.read_text().replace(DUMMY_ENV["RESTIC_REPOSITORY"], raw_repository))
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_check_env(tmp_path, bin_dir, log_file, FAKE_RESTIC_CHECK_FAIL="1")

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = combined(result)

    assert result.returncode == 37
    assert raw_repository not in output
    assert "repo echo [redacted:RESTIC_REPOSITORY]" in output

def test_restic_check_redacts_repository_values_when_extglob_enabled(tmp_path):
    env_file, _ = write_local_config(tmp_path)
    raw_repository = "b2:@(repo):backup-test-fixture"
    env_file.write_text(
        "\n".join(
            f"RESTIC_REPOSITORY={shlex.quote(raw_repository)}" if line.startswith("RESTIC_REPOSITORY=") else line
            for line in env_file.read_text().splitlines()
        )
        + "\n"
    )
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_check_env(tmp_path, bin_dir, log_file, FAKE_RESTIC_CHECK_FAIL="1")

    result = subprocess.run(["bash", "-O", "extglob", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = combined(result)

    assert result.returncode == 37
    assert raw_repository not in output
    assert "repo echo [redacted:RESTIC_REPOSITORY]" in output

def test_restic_check_redacts_longer_values_before_substrings(tmp_path):
    env_file, _ = write_local_config(tmp_path)
    raw_repository = "b2:foo:backup-test-fixture"
    text = env_file.read_text()
    text = text.replace(DUMMY_ENV["B2_ACCOUNT_ID"], "foo")
    text = text.replace(DUMMY_ENV["RESTIC_REPOSITORY"], raw_repository)
    env_file.write_text(text)
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_check_env(tmp_path, bin_dir, log_file, FAKE_RESTIC_CHECK_FAIL="1")

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = combined(result)

    assert result.returncode == 37
    assert raw_repository not in output
    assert "repo echo [redacted:RESTIC_REPOSITORY]" in output

def test_restic_check_redacts_longest_value_first_for_any_config_key(tmp_path):
    env_file, _ = write_local_config(tmp_path)
    raw_key = "abcXYZ"
    text = env_file.read_text()
    text = text.replace(DUMMY_ENV["RESTIC_REPOSITORY"], "abc")
    text = text.replace(DUMMY_ENV["B2_ACCOUNT_KEY"], raw_key)
    env_file.write_text(text)
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_check_env(tmp_path, bin_dir, log_file, FAKE_RESTIC_CHECK_FAIL="1")

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = combined(result)

    assert result.returncode == 37
    assert raw_key not in output
    assert "secret echo [redacted:B2_ACCOUNT_KEY]" in output

def test_restic_check_does_not_pass_ambient_telegram_credentials_to_restic(tmp_path):
    telegram_token = "DUMMY_TELEGRAM_TOKEN_NOT_REAL"
    telegram_chat = "-1001234567890"
    result, log_file = run_check(
        tmp_path,
        extra_env={
            "FAKE_RESTIC_CHECK_FAIL": "1",
            "TELEGRAM_BOT_TOKEN": telegram_token,
            "TELEGRAM_CHAT_ID": telegram_chat,
        },
    )
    output = combined(result)

    assert result.returncode == 37
    assert telegram_token not in output
    assert telegram_chat not in output
    log = log_file.read_text()
    assert "TELEGRAM_BOT_TOKEN=missing" in log
    assert "TELEGRAM_CHAT_ID=missing" in log

def test_restic_check_redacts_configured_telegram_values_from_restic_output(tmp_path):
    result, _ = run_check(
        tmp_path,
        extra_env={
            "FAKE_RESTIC_CHECK_FAIL": "1",
            "FAKE_RESTIC_STDERR_SECRET": DUMMY_ENV["TELEGRAM_BOT_TOKEN"],
        },
    )
    output = combined(result)

    assert result.returncode == 37
    assert DUMMY_ENV["TELEGRAM_BOT_TOKEN"] not in output
    assert "configured secret echo [redacted:TELEGRAM_BOT_TOKEN]" in output

def test_restic_check_accepts_explicit_config_without_home(tmp_path):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env_file, _ = write_local_config(tmp_path)
    env = fake_check_env(tmp_path, bin_dir, log_file)
    env.pop("HOME", None)

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode == 0, combined(result)
    assert "check=ok repository=configured" in combined(result)

def test_restic_check_uses_xdg_config_home_without_home(tmp_path):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    config_home = tmp_path / "xdg-config"
    config_dir = config_home / "hermes-backup"
    config_dir.mkdir(parents=True)
    source_root = tmp_path / "source-config"
    source_root.mkdir()
    source_env, source_password = write_local_config(source_root)
    password_file = config_dir / "restic-password"
    password_file.write_text(source_password.read_text())
    password_file.chmod(0o600)
    env_file = config_dir / "hermes-backup.env"
    env_file.write_text(source_env.read_text().replace(str(source_password), str(password_file)))
    env_file.chmod(0o600)
    env = fake_check_env(tmp_path, bin_dir, log_file, XDG_CONFIG_HOME=str(config_home))
    env.pop("HOME", None)
    env.pop("HERMES_BACKUP_ENV", None)

    result = subprocess.run(["bash", str(SCRIPT)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode == 0, combined(result)
    assert "check=ok repository=configured" in combined(result)

def test_restic_check_reports_missing_home_as_config_error_before_default_expansion(tmp_path):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env = fake_check_env(tmp_path, bin_dir, log_file)
    env.pop("HOME", None)
    env.pop("HERMES_BACKUP_ENV", None)
    env.pop("XDG_CONFIG_HOME", None)

    result = subprocess.run(["bash", str(SCRIPT)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode == 64
    assert "HOME must be set" in combined(result)
    assert not log_file.exists()
