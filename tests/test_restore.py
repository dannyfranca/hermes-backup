import os
import re
import shlex
import stat
import subprocess
import textwrap
from pathlib import Path

from test_stage import fake_bin, make_executable

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "restore.sh"

DUMMY_ENV = {
    "B2_ACCOUNT_ID": "DUMMY_RESTORE_B2_KEY_ID_NOT_REAL",
    "B2_ACCOUNT_KEY": "DUMMY_RESTORE_B2_APPLICATION_KEY_NOT_REAL",
    "RESTIC_REPOSITORY": "b2:dummy-hermes-backup:restore-test-fixture",
    "TELEGRAM_BOT_TOKEN": "DUMMY_RESTORE_TELEGRAM_TOKEN_NOT_REAL",
}
RESTIC_PASSWORD = "DUMMY_RESTORE_RESTIC_PASSWORD_NOT_REAL"


def combined(result) -> str:
    return result.stdout + result.stderr


def write_local_config(tmp_path: Path, *, mode_bits: int = 0o600, restore_dir: Path | None = None) -> tuple[Path, Path]:
    config_dir = tmp_path / "config"
    config_dir.mkdir(mode=0o700, parents=True)
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
                *( [f"HERMES_BACKUP_RESTORE_DIR={shlex.quote(str(restore_dir))}"] if restore_dir is not None else [] ),
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
        import os, sys
        from pathlib import Path
        log = Path(os.environ["FAKE_RESTIC_LOG"])
        args = sys.argv[1:]
        with log.open("a") as f:
            f.write("ARGS " + "\0".join(args) + "\n")
            f.write("ENV " + " ".join(f"{name}={'set' if os.environ.get(name) else 'missing'}" for name in ["B2_ACCOUNT_ID", "B2_ACCOUNT_KEY", "RESTIC_REPOSITORY", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD", "RESTIC_PASSWORD_COMMAND"]) + "\n")
        if args[:1] == ["restore"]:
            if os.environ.get("FAKE_RESTIC_RESTORE_FAIL") == "1":
                sys.exit(44)
            target = Path(args[args.index("--target") + 1])
            target.mkdir(parents=True, exist_ok=True)
            base = target
            if os.environ.get("FAKE_RESTIC_LAYOUT") == "staged":
                base = target / "tmp" / "state" / "hermes-backup" / "staging" / "stage-fixture"
            for rel in os.environ.get("FAKE_RESTIC_CREATE", "home/agent/.hermes/config.yaml,home/agent/shared/reports/status.html,home/agent/shared-assets/mermaid/mermaid.min.js,home/agent/.config/systemd/user/hermes-gateway.service,home/agent/.config/containers/systemd/home-stream.container").split(","):
                rel = rel.strip()
                if not rel:
                    continue
                p = base / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("restored fixture\n")
            print("restore ok")
            sys.exit(0)
        sys.exit(2)
        ''',
    )


def fake_restore_env(tmp_path: Path, bin_dir: Path, log_file: Path, **extra: str) -> dict[str, str]:
    env = os.environ.copy()
    env.update({"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "HOME": str(tmp_path / "home" / "agent"), "FAKE_RESTIC_LOG": str(log_file), **extra})
    return env


def run_restore(tmp_path: Path, *args: str, extra_env: dict[str, str] | None = None, restore_dir: Path | None = None):
    tmp_path.mkdir(parents=True, exist_ok=True)
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env_file, _ = write_local_config(tmp_path, restore_dir=restore_dir)
    env = fake_restore_env(tmp_path, bin_dir, log_file)
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
    return result, log_file


def assert_no_secret_values(output: str) -> None:
    for value in [*DUMMY_ENV.values(), RESTIC_PASSWORD]:
        assert value not in output


def target_from_output(output: str) -> Path:
    match = re.search(r"^restore_target=(.+)$", output, re.MULTILINE)
    assert match, output
    return Path(match.group(1))


def test_restore_has_valid_bash_syntax_and_is_executable():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=ROOT, text=True, capture_output=True, check=False)
    assert result.returncode == 0, combined(result)
    assert SCRIPT.stat().st_mode & stat.S_IXUSR


def test_restore_latest_defaults_to_non_live_safe_restore_root_and_verifies_paths(tmp_path):
    result, log_file = run_restore(tmp_path)
    output = combined(result)

    assert result.returncode == 0, output
    assert_no_secret_values(output)
    target = target_from_output(output)
    assert target == tmp_path / "home" / "agent" / "restore" / "hermes-vm-backup" / "latest"
    marker = target / ".hermes-backup-restore.json"
    assert marker.is_file()
    marker_text = marker.read_text()
    assert '"tool":"restore.sh"' in marker_text
    assert '"mode":"non-live-inspection-only"' in marker_text
    assert '"promote":"false"' in marker_text
    assert "snapshot=latest" in output
    assert "verify path=/home/agent/.hermes status=present" in output
    assert "verify path=/home/agent/shared status=present" in output
    assert "verification=ok present=5 missing=0" in output

    log = log_file.read_text().splitlines()
    restore_args = log[0].split(" ", 1)[1].split("\0")
    assert restore_args == ["restore", "latest", "--tag", "hermes-vm-backup", "--target", str(target / ".restic-restore-raw")]
    assert "B2_ACCOUNT_KEY=set" in log[1]
    assert "RESTIC_PASSWORD_FILE=set" in log[1]
    assert "RESTIC_PASSWORD=missing" in log[1]
    assert "RESTIC_PASSWORD_COMMAND=missing" in log[1]


def test_restore_explicit_snapshot_defaults_to_snapshot_named_safe_directory(tmp_path):
    result, log_file = run_restore(tmp_path, "--snapshot", "abc123def456")
    output = combined(result)

    assert result.returncode == 0, output
    assert_no_secret_values(output)
    target = target_from_output(output)
    assert target == tmp_path / "home" / "agent" / "restore" / "hermes-vm-backup" / "abc123def456"
    restore_args = log_file.read_text().splitlines()[0].split(" ", 1)[1].split("\0")
    assert restore_args == ["restore", "abc123def456", "--target", str(target / ".restic-restore-raw")]


def test_restore_refuses_snapshot_values_that_escape_default_restore_root(tmp_path):
    for index, snapshot in enumerate(["../../.ssh", "nested/snapshot", "..", "-unsafe"]):
        result, log_file = run_restore(tmp_path / f"bad-snapshot-{index}", "--snapshot", snapshot)
        output = combined(result)
        assert result.returncode != 0, snapshot
        assert "snapshot must be 'latest' or a single safe snapshot id" in output
        assert not log_file.exists()
        assert_no_secret_values(output)


def test_restore_refuses_destination_equal_inside_or_parent_overlapping_live_paths(tmp_path):
    live_root = tmp_path / "fixture-live"
    live_hermes = live_root / "home" / "agent" / ".hermes"
    live_hermes.mkdir(parents=True)
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text(str(live_hermes) + "\n")
    (manifest_dir / "exclude.patterns").write_text("/tmp/unused/**\n")

    for index, unsafe_target in enumerate([live_hermes, live_hermes / "profiles", live_hermes.parent]):
        result, log_file = run_restore(tmp_path / f"case-{index}", "--manifest-dir", str(manifest_dir), "--target", str(unsafe_target))
        output = combined(result)
        assert result.returncode != 0, unsafe_target
        assert "refusing restore target overlapping live include path" in output
        assert str(live_hermes) in output
        assert not log_file.exists()
        assert_no_secret_values(output)


def test_restore_target_guard_cannot_be_overridden_by_ambient_test_env(tmp_path):
    live_root = tmp_path / "fixture-live"
    live_hermes = live_root / "home" / "agent" / ".hermes"
    live_hermes.mkdir(parents=True)
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text(str(live_hermes) + "\n")
    (manifest_dir / "exclude.patterns").write_text("/tmp/unused/**\n")

    result, log_file = run_restore(
        tmp_path,
        "--manifest-dir",
        str(manifest_dir),
        "--target",
        str(live_hermes),
        extra_env={"HERMES_BACKUP_ALLOW_LIVE_RESTORE_TARGET_FOR_TESTS": "I_UNDERSTAND_THIS_IS_TEST_ONLY"},
    )
    output = combined(result)

    assert result.returncode != 0
    assert "refusing restore target overlapping live include path" in output
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_restore_flattens_layout_produced_by_staged_backup_snapshots(tmp_path):
    result, _ = run_restore(tmp_path, extra_env={"FAKE_RESTIC_LAYOUT": "staged"})
    output = combined(result)

    assert result.returncode == 0, output
    target = target_from_output(output)
    assert (target / "home/agent/.hermes/config.yaml").is_file()
    assert (target / "home/agent/shared/reports/status.html").is_file()
    assert not (target / ".restic-restore-raw").exists()
    assert "layout=flattened source_prefix=" in output
    assert "verification=ok present=5 missing=0" in output
    assert_no_secret_values(output)


def test_restore_resolves_symlinked_target_ancestors_before_live_overlap_check(tmp_path):
    live_hermes = tmp_path / "live" / "home" / "agent" / ".hermes"
    live_hermes.mkdir(parents=True)
    link_parent = tmp_path / "safe-looking"
    link_parent.mkdir()
    restore_link = link_parent / "restore-link"
    restore_link.symlink_to(live_hermes)
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text(str(live_hermes) + "\n")
    (manifest_dir / "exclude.patterns").write_text("/tmp/unused/**\n")

    result, log_file = run_restore(tmp_path, "--manifest-dir", str(manifest_dir), "--target", str(restore_link / "latest"))
    output = combined(result)

    assert result.returncode != 0
    assert "refusing restore target overlapping live include path" in output
    assert str(live_hermes) in output
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_restore_honors_configured_restore_dir_by_default(tmp_path):
    configured_restore_dir = tmp_path / "configured-safe-restore"
    result, _ = run_restore(tmp_path, restore_dir=configured_restore_dir)
    output = combined(result)

    assert result.returncode == 0, output
    assert target_from_output(output) == configured_restore_dir / "latest"
    assert_no_secret_values(output)


def test_restore_reports_missing_expected_paths_as_warnings_without_secret_values(tmp_path):
    result, _ = run_restore(tmp_path, extra_env={"FAKE_RESTIC_CREATE": "home/agent/.hermes/config.yaml"})
    output = combined(result)

    assert result.returncode == 0, output
    assert "verify path=/home/agent/.hermes status=present" in output
    assert "verify path=/home/agent/shared status=missing" in output
    assert "verification=warnings present=1 missing=4" in output
    assert_no_secret_values(output)


def test_restore_refuses_missing_or_unsafe_config_before_restic(tmp_path):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    missing_env = tmp_path / "missing.env"
    env = fake_restore_env(tmp_path, bin_dir, log_file)

    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(missing_env)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode != 0
    output = combined(result)
    assert "local env file not found" in output
    assert not log_file.exists()
    assert_no_secret_values(output)

    env_file, _ = write_local_config(tmp_path, mode_bits=0o644)
    result = subprocess.run(["bash", str(SCRIPT), "--config-env", str(env_file)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    assert result.returncode != 0
    output = combined(result)
    assert "local env file permissions are unsafe" in output
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_restore_refuses_empty_include_manifest_before_restic(tmp_path):
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text("# no live roots\n\n")
    (manifest_dir / "exclude.patterns").write_text("/tmp/unused/**\n")
    result, log_file = run_restore(tmp_path, "--manifest-dir", str(manifest_dir), "--target", str(tmp_path / "target"))
    output = combined(result)

    assert result.returncode != 0
    assert "include manifest is empty" in output
    assert not log_file.exists()
    assert_no_secret_values(output)


def test_restore_honors_hermes_backup_env_override(tmp_path):
    bin_dir = fake_bin(tmp_path)
    log_file = tmp_path / "restic.log"
    add_fake_restic(bin_dir, log_file)
    env_file, _ = write_local_config(tmp_path / "custom-config")
    env = fake_restore_env(tmp_path, bin_dir, log_file, HERMES_BACKUP_ENV=str(env_file))

    result = subprocess.run(["bash", str(SCRIPT)], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = combined(result)

    assert result.returncode == 0, output
    assert "restore=ok" in output
    assert log_file.exists()
    assert_no_secret_values(output)


def test_restore_failure_does_not_print_secret_values(tmp_path):
    result, _ = run_restore(
        tmp_path,
        extra_env={"FAKE_RESTIC_RESTORE_FAIL": "1", "RESTIC_PASSWORD": "INHERITED_PASSWORD_MUST_NOT_BE_USED", "RESTIC_PASSWORD_COMMAND": "echo inherited"},
    )
    output = combined(result)

    assert result.returncode != 0
    assert "restic restore failed" in output
    assert_no_secret_values(output)
    assert "INHERITED_PASSWORD_MUST_NOT_BE_USED" not in output
