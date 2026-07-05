import os
import re
import shlex
import shutil
import sqlite3
import subprocess
from pathlib import Path

from test_logs_alerts import add_fake_curl, alert_message_payload
from test_stage import fake_bin, make_executable

ROOT = Path(__file__).resolve().parents[1]
RESTORE_SCRIPT = ROOT / "scripts" / "restore.sh"
PROMOTE_SCRIPT = ROOT / "scripts" / "promote.sh"
DRILL_SCRIPT = ROOT / "scripts" / "restore-drill.sh"

INCLUDES = [
    "/home/agent/.hermes",
    "/home/agent/shared",
    "/home/agent/shared-assets",
    "/home/agent/.config/systemd/user",
    "/home/agent/.config/containers/systemd",
]
RESTIC_REPOSITORY_VALUE = "b2:dummy-hermes-backup:e2e-test-fixture"
TELEGRAM_CHAT_ID_VALUE = "-1001234567890"
SECRETS = [
    "DUMMY_E2E_B2_KEY_ID_NOT_REAL",
    "DUMMY_E2E_B2_APPLICATION_KEY_NOT_REAL",
    "DUMMY_E2E_RESTIC_PASSWORD_NOT_REAL",
    "DUMMY_E2E_TELEGRAM_TOKEN_NOT_REAL",
    "AMBIENT_E2E_TELEGRAM_TOKEN_MUST_NOT_LEAK",
    "AMBIENT_E2E_B2_KEY_MUST_NOT_LEAK",
    "RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT",
    RESTIC_REPOSITORY_VALUE,
    TELEGRAM_CHAT_ID_VALUE,
]


def combined(result) -> str:
    return result.stdout + result.stderr


def assert_no_secret_values(text: str) -> None:
    for secret in SECRETS:
        assert secret not in text


def write_local_config(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    config_dir = tmp_path / "config"
    config_dir.mkdir(mode=0o700, parents=True)
    password_file = config_dir / "restic-password"
    password_file.write_text(SECRETS[2] + "\n")
    password_file.chmod(0o600)
    log_dir = tmp_path / "state" / "logs"
    drill_root = tmp_path / "state" / "drills"
    env_file = config_dir / "hermes-backup.env"
    env_file.write_text(
        "\n".join(
            [
                f"B2_ACCOUNT_ID={shlex.quote(SECRETS[0])}",
                f"B2_ACCOUNT_KEY={shlex.quote(SECRETS[1])}",
                f"RESTIC_REPOSITORY={shlex.quote(RESTIC_REPOSITORY_VALUE)}",
                f"RESTIC_PASSWORD_FILE={shlex.quote(str(password_file))}",
                f"TELEGRAM_BOT_TOKEN={shlex.quote(SECRETS[3])}",
                f"TELEGRAM_CHAT_ID={shlex.quote(TELEGRAM_CHAT_ID_VALUE)}",
                f"HERMES_BACKUP_LOG_DIR={shlex.quote(str(log_dir))}",
                f"HERMES_BACKUP_DRILL_DIR={shlex.quote(str(drill_root))}",
                "",
            ]
        )
    )
    env_file.chmod(0o600)
    return env_file, password_file, log_dir, drill_root


def write_manifest(tmp_path: Path, paths: list[str] | None = None) -> Path:
    manifest_dir = tmp_path / "manifests"
    manifest_dir.mkdir()
    (manifest_dir / "include.paths").write_text("\n".join(paths or INCLUDES) + "\n")
    (manifest_dir / "exclude.patterns").write_text("/home/agent/git/**\nnode_modules/**\n")
    return manifest_dir


def add_fake_restic(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "restic",
        r'''
        #!/usr/bin/env python3
        import os, sqlite3, sys
        from pathlib import Path
        args = sys.argv[1:]
        log = Path(os.environ["FAKE_RESTIC_LOG"])
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
        if args[:1] != ["restore"]:
            sys.exit(2)
        expected_b2_key = os.environ.get("EXPECTED_B2_ACCOUNT_KEY")
        ambient_b2_key = os.environ.get("AMBIENT_B2_ACCOUNT_KEY_SENTINEL")
        if expected_b2_key and os.environ.get("B2_ACCOUNT_KEY") != expected_b2_key:
            print("unexpected B2_ACCOUNT_KEY source", file=sys.stderr)
            sys.exit(65)
        if ambient_b2_key and os.environ.get("B2_ACCOUNT_KEY") == ambient_b2_key:
            print("ambient B2_ACCOUNT_KEY leaked into fake restic", file=sys.stderr)
            sys.exit(66)
        if os.environ.get("RESTIC_REPOSITORY") != os.environ.get("EXPECTED_RESTIC_REPOSITORY"):
            print("unexpected RESTIC_REPOSITORY source", file=sys.stderr)
            sys.exit(67)
        if os.environ.get("FAKE_RESTIC_RESTORE_FAIL") == "1":
            print("restore failed " + os.environ.get("B2_ACCOUNT_KEY", "missing"), file=sys.stderr)
            sys.exit(44)
        target = Path(args[args.index("--target") + 1])
        target.mkdir(parents=True, exist_ok=True)
        base = target
        if os.environ.get("FAKE_RESTIC_LAYOUT") == "staged":
            base = target / "tmp" / "state" / "hermes-backup" / "staging" / "snapshot"
        include_paths = os.environ.get(
            "FAKE_RESTIC_INCLUDE_PATHS",
            "/home/agent/.hermes|/home/agent/shared|/home/agent/shared-assets|/home/agent/.config/systemd/user|/home/agent/.config/containers/systemd",
        ).split("|")
        for include in include_paths:
            include = include.strip()
            if not include:
                continue
            rel_root = include.lstrip("/")
            root = base / rel_root
            root.mkdir(parents=True, exist_ok=True)
            if include.endswith("/.hermes"):
                (root / "config.yaml").write_text("restored config\n")
                db = root / "kanban.db"
                if os.environ.get("FAKE_RESTIC_CORRUPT_SQLITE") == "1":
                    db.write_bytes(b"not a sqlite database")
                else:
                    conn = sqlite3.connect(db)
                    conn.execute("create table tasks(id text primary key, title text)")
                    conn.execute("insert into tasks values ('t_e2e', 'offline e2e restore')")
                    conn.commit()
                    conn.close()
            elif include.endswith("/shared"):
                if os.environ.get("FAKE_RESTIC_MISSING_SHARED") == "1":
                    continue
                report = root / "reports" / "status.html"
                report.parent.mkdir(parents=True, exist_ok=True)
                report.write_text("<p>restored</p>\n")
            elif include.endswith("/shared-assets"):
                asset = root / "mermaid" / "mermaid.min.js"
                asset.parent.mkdir(parents=True, exist_ok=True)
                asset.write_text("// restored\n")
            elif include.endswith("/.config/systemd/user"):
                (root / "hermes-gateway.service").write_text("[Service]\nExecStart=/bin/true\n")
            elif include.endswith("/.config/containers/systemd"):
                (root / "home-stream.container").write_text("[Container]\nImage=example.invalid/home-stream\n")
            else:
                (root / "restored.txt").write_text("restored fixture\n")
        print("restore ok")
        sys.exit(0)
        ''',
    )


def add_fake_systemctl(bin_dir: Path, log_file: Path) -> None:
    make_executable(
        bin_dir / "systemctl",
        r'''
        #!/usr/bin/env python3
        import os, sys
        from pathlib import Path
        args = sys.argv[1:]
        Path(os.environ["FAKE_SYSTEMCTL_LOG"]).open("a").write(" ".join(args) + "\n")
        if args[:2] == ["--user", "list-units"]:
            sys.exit(0)
        if args[:3] == ["--user", "is-active", "--quiet"]:
            sys.exit(3)
        if args[:2] in (["--user", "stop"], ["--user", "daemon-reload"]):
            sys.exit(0)
        sys.exit(2)
        ''',
    )
    make_executable(
        bin_dir / "ps",
        "#!/usr/bin/env python3\n",
    )


def add_forbidden_command_fakes(bin_dir: Path) -> None:
    for command in ["b2", "crontab", "hermes", "kill", "pkill", "killall"]:
        make_executable(
            bin_dir / command,
            r'''
            #!/usr/bin/env python3
            import os, sys
            from pathlib import Path
            log = os.environ.get("FAKE_FORBIDDEN_COMMAND_LOG")
            if log:
                Path(log).open("a").write(Path(sys.argv[0]).name + " " + " ".join(sys.argv[1:]) + "\n")
            sys.exit(98)
            ''',
        )


def make_env(tmp_path: Path, bin_dir: Path, restic_log: Path, curl_log: Path, systemctl_log: Path) -> dict[str, str]:
    return {
        "PATH": f"{bin_dir}{os.pathsep}/usr/local/bin:/usr/bin:/bin",
        "HOME": str(tmp_path / "home" / "agent"),
        "FAKE_RESTIC_LOG": str(restic_log),
        "FAKE_CURL_LOG": str(curl_log),
        "FAKE_SYSTEMCTL_LOG": str(systemctl_log),
        "FAKE_FORBIDDEN_COMMAND_LOG": str(tmp_path / "forbidden-commands.log"),
        "B2_ACCOUNT_KEY": SECRETS[5],
        "AMBIENT_B2_ACCOUNT_KEY_SENTINEL": SECRETS[5],
        "EXPECTED_B2_ACCOUNT_KEY": SECRETS[1],
        "EXPECTED_RESTIC_REPOSITORY": RESTIC_REPOSITORY_VALUE,
    }


def target_from_restore_output(output: str) -> Path:
    match = re.search(r"^restore_target=(.+)$", output, re.MULTILINE)
    assert match, output
    return Path(match.group(1))


def target_from_drill_output(output: str) -> Path:
    match = re.search(r"^drill_target=(.+)$", output, re.MULTILINE)
    assert match, output
    return Path(match.group(1))


def write_live_fixture(live_paths: list[str]) -> None:
    for index, live_path in enumerate(live_paths):
        target = Path(live_path) / "current.txt"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"old live {index} {SECRETS[-3]}\n")


def assert_sqlite_ok(db_path: Path) -> None:
    conn = sqlite3.connect(db_path)
    try:
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert conn.execute("select title from tasks where id='t_e2e'").fetchone()[0] == "offline e2e restore"
    finally:
        conn.close()


def snapshot_tree(paths: list[str]) -> dict[str, tuple[str, int, int, int, bytes | None]]:
    snapshot: dict[str, tuple[str, int, int, int, bytes | None]] = {}
    for root_name in paths:
        root = Path(root_name)
        entries = [root, *sorted(root.rglob("*"))]
        for path in entries:
            stat_result = path.lstat()
            if path.is_symlink():
                kind = "symlink"
                payload = os.readlink(path).encode()
            elif path.is_file():
                kind = "file"
                payload = path.read_bytes()
            elif path.is_dir():
                kind = "dir"
                payload = None
            else:
                kind = "other"
                payload = None
            rel = "." if path == root else str(path.relative_to(root))
            key = f"{root_name}:{rel}"
            snapshot[key] = (kind, stat_result.st_mode, stat_result.st_size, stat_result.st_mtime_ns, payload)
    return snapshot


def test_end_to_end_fake_restore_drill_and_promote_safety_harness(tmp_path, request):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    curl_log = tmp_path / "curl.log"
    systemctl_log = tmp_path / "systemctl.log"
    add_fake_restic(bin_dir, restic_log)
    add_fake_curl(bin_dir, curl_log)
    add_fake_systemctl(bin_dir, systemctl_log)
    add_forbidden_command_fakes(bin_dir)
    env_file, _, log_dir, drill_root = write_local_config(tmp_path)
    env = make_env(tmp_path, bin_dir, restic_log, curl_log, systemctl_log)

    home_case_root = Path.home() / "tmp" / "hermes-backup-test-live" / tmp_path.name
    request.addfinalizer(lambda: shutil.rmtree(home_case_root, ignore_errors=True))
    shutil.rmtree(home_case_root, ignore_errors=True)
    live_root = home_case_root / "live-root"
    live_paths = [str(live_root / include.lstrip("/")) for include in INCLUDES]
    manifest_dir = write_manifest(tmp_path, live_paths)
    promote_guard_log = tmp_path / "implicit-promote.log"
    promote_guard = tmp_path / "fail-if-promote.sh"
    promote_guard.write_text(
        "case \"$0\" in */promote.sh) "
        "printf 'implicit promote: %s\\n' \"$0\" >>\"$PROMOTE_GUARD_LOG\"; "
        "exit 97;; esac\n"
    )
    restore_drill_env = {**env, "BASH_ENV": str(promote_guard), "PROMOTE_GUARD_LOG": str(promote_guard_log)}
    drill_env = {**restore_drill_env, "TELEGRAM_BOT_TOKEN": SECRETS[4]}
    env["FAKE_RESTIC_INCLUDE_PATHS"] = "|".join(live_paths)
    restore_drill_env["FAKE_RESTIC_INCLUDE_PATHS"] = env["FAKE_RESTIC_INCLUDE_PATHS"]
    drill_env["FAKE_RESTIC_INCLUDE_PATHS"] = env["FAKE_RESTIC_INCLUDE_PATHS"]
    write_live_fixture(live_paths)
    live_before = {path: (Path(path) / "current.txt").read_text() for path in live_paths}
    live_tree_before = snapshot_tree(live_paths)

    restore = subprocess.run(
        [
            "bash",
            str(RESTORE_SCRIPT),
            "--config-env",
            str(env_file),
            "--manifest-dir",
            str(manifest_dir),
        ],
        cwd=ROOT,
        env=restore_drill_env,
        text=True,
        capture_output=True,
        check=False,
    )
    restore_output = combined(restore)
    assert restore.returncode == 0, restore_output
    restore_target = target_from_restore_output(restore_output)
    assert restore_target.parent == Path(env["HOME"]) / "restore" / "hermes-vm-backup"
    assert re.fullmatch(r"latest-\d{8}T\d{6}Z(?:-\d+)?", restore_target.name)
    assert "mode=non-live-inspection-only promote=false" in restore_output
    assert "No live Hermes/shared/systemd paths were promoted or overwritten." in restore_output
    assert snapshot_tree(live_paths) == live_tree_before
    assert not promote_guard_log.exists()
    assert not curl_log.exists()
    assert not systemctl_log.exists()
    assert (restore_target / ".hermes-backup-restore.json").is_file()
    assert (restore_target / live_paths[1].lstrip("/") / "reports/status.html").is_file()
    assert_sqlite_ok(restore_target / live_paths[0].lstrip("/") / "kanban.db")
    assert_no_secret_values(restore_output)
    restic_after_restore = restic_log.read_text()

    dry_run = subprocess.run(
        [
            "bash",
            str(PROMOTE_SCRIPT),
            "--manifest-dir",
            str(manifest_dir),
            "--backup-root",
            str(tmp_path / "pre-promotion-backups"),
            "--dry-run",
            str(restore_target),
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    dry_output = combined(dry_run)
    assert dry_run.returncode == 0, dry_output
    assert "mode=dry-run promote=false" in dry_output
    assert "dry_run=ok no_live_paths_changed=true" in dry_output
    assert snapshot_tree(live_paths) == live_tree_before
    assert not curl_log.exists()
    dry_systemctl_lines = systemctl_log.read_text().splitlines()
    assert dry_systemctl_lines
    assert all(line.startswith("--user ") for line in dry_systemctl_lines)
    assert all(" stop " not in f" {line} " and " daemon-reload" not in line for line in dry_systemctl_lines)
    systemctl_log.unlink()
    assert restic_log.read_text() == restic_after_restore
    assert_no_secret_values(dry_output)

    unconfirmed = subprocess.run(
        [
            "bash",
            str(PROMOTE_SCRIPT),
            "--manifest-dir",
            str(manifest_dir),
            "--backup-root",
            str(tmp_path / "pre-promotion-backups"),
            str(restore_target),
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    unconfirmed_output = combined(unconfirmed)
    assert unconfirmed.returncode != 0
    assert "live promote requires --yes --confirm PROMOTE-HERMES-RESTORE" in unconfirmed_output
    assert snapshot_tree(live_paths) == live_tree_before
    assert not curl_log.exists()
    assert not systemctl_log.exists()
    assert restic_log.read_text() == restic_after_restore
    assert_no_secret_values(unconfirmed_output)

    confirmed = subprocess.run(
        [
            "bash",
            str(PROMOTE_SCRIPT),
            "--manifest-dir",
            str(manifest_dir),
            "--backup-root",
            str(tmp_path / "pre-promotion-backups"),
            "--yes",
            "--confirm",
            "PROMOTE-HERMES-RESTORE",
            str(restore_target),
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    confirmed_output = combined(confirmed)
    assert confirmed.returncode == 0, confirmed_output
    backup_match = re.search(r"^pre_promotion_backup=(.+)$", confirmed_output, re.MULTILINE)
    assert backup_match, confirmed_output
    backup_root = Path(backup_match.group(1))
    for live_path, before in live_before.items():
        rel = Path(live_path).relative_to("/")
        assert confirmed_output.index(f"backup live_path={live_path}") < confirmed_output.index(f"promote live_path={live_path}")
        assert (backup_root / rel / "current.txt").read_text() == before
        assert not (Path(live_path) / "current.txt").exists()
    backup_positions = [confirmed_output.index(f"backup live_path={live_path}") for live_path in live_paths]
    promote_positions = [confirmed_output.index(f"promote live_path={live_path}") for live_path in live_paths]
    assert max(backup_positions) < min(promote_positions)
    assert (Path(live_paths[0]) / "config.yaml").read_text() == "restored config\n"
    assert_sqlite_ok(Path(live_paths[0]) / "kanban.db")
    assert "--user daemon-reload" in systemctl_log.read_text()
    systemctl_lines = systemctl_log.read_text().splitlines()
    assert systemctl_lines
    assert all(line.startswith("--user ") for line in systemctl_lines)
    assert all(
        line in {
            "--user list-units",
            "--user list-units --type=service --state=active --all --no-legend --plain hermes*.service",
            "--user is-active --quiet hermes-gateway.service",
            "--user is-active --quiet hermes-dashboard.service",
            "--user daemon-reload",
        }
        for line in systemctl_lines
    )
    assert not curl_log.exists()
    assert restic_log.read_text() == restic_after_restore
    assert_no_secret_values(confirmed_output)

    systemctl_after_promote = systemctl_log.read_text()
    sentinel = Path(live_paths[0]) / "post-promote-sentinel.txt"
    sentinel.write_text("drill must not replace this live sentinel\n")
    after_promote = snapshot_tree(live_paths)
    drill = subprocess.run(
        [
            "bash",
            str(DRILL_SCRIPT),
            "--config-env",
            str(env_file),
            "--manifest-dir",
            str(manifest_dir),
            "--restore-command",
            str(RESTORE_SCRIPT),
            "--keep-artifacts",
        ],
        cwd=ROOT,
        env={**drill_env, "HERMES_BACKUP_DRILL_ID": "20260705T000000Z"},
        text=True,
        capture_output=True,
        check=False,
    )
    drill_output = combined(drill)
    assert drill.returncode == 0, drill_output
    drill_target = target_from_drill_output(drill_output)
    drill_target.resolve().relative_to(drill_root.resolve())
    assert "mode=temporary-safe-restore promote=false" in drill_output
    sqlite_rel = f"{live_paths[0].lstrip('/')}/kanban.db"
    assert f"sqlite path={sqlite_rel} status=ok" in drill_output
    assert "drill=ok present=5 missing=0 sqlite_checked=1 sqlite_failed=0" in drill_output
    assert "drill_report=sent transport=raw-telegram-api" in drill_output
    assert snapshot_tree(live_paths) == after_promote
    assert not promote_guard_log.exists()
    assert systemctl_log.read_text() == systemctl_after_promote
    curl_text = curl_log.read_text()
    assert curl_text.count("URL https://api.telegram.org/bot") == 1
    assert SECRETS[3] in curl_text
    assert SECRETS[4] not in curl_text
    assert "/sendMessage" in curl_text
    assert "gateway" not in curl_text.lower()
    payload = alert_message_payload(curl_text)
    assert "Hermes backup restore drill" in payload
    assert "status: PASS" in payload
    assert "sqlite_checked=1" in payload
    daily_logs = list(log_dir.glob("hermes-backup-*.log"))
    assert len(daily_logs) == 1
    assert "command=drill status=success exit=0" in daily_logs[0].read_text()
    assert_no_secret_values(drill_output + payload + daily_logs[0].read_text())

    restic_text = restic_log.read_text()
    assert "ARGS restore\0latest\0--tag\0hermes-vm-backup\0--host" in restic_text
    env_lines = [line for line in restic_text.splitlines() if line.startswith("ENV ")]
    assert env_lines
    assert all("RESTIC_PASSWORD=missing" in line for line in env_lines)
    assert all("RESTIC_PASSWORD_COMMAND=missing" in line for line in env_lines)
    assert all("TELEGRAM_BOT_TOKEN=missing" in line for line in env_lines)
    assert all("TELEGRAM_CHAT_ID=missing" in line for line in env_lines)
    assert_no_secret_values(restic_text)
    assert not Path(env["FAKE_FORBIDDEN_COMMAND_LOG"]).exists()
    shutil.rmtree(home_case_root, ignore_errors=True)


def test_harness_drill_fails_and_reports_corrupt_restored_sqlite(tmp_path, request):
    bin_dir = fake_bin(tmp_path)
    restic_log = tmp_path / "restic.log"
    curl_log = tmp_path / "curl.log"
    systemctl_log = tmp_path / "systemctl.log"
    add_fake_restic(bin_dir, restic_log)
    add_fake_curl(bin_dir, curl_log)
    add_fake_systemctl(bin_dir, systemctl_log)
    add_forbidden_command_fakes(bin_dir)
    env_file, _, log_dir, _ = write_local_config(tmp_path)
    home_case_root = Path.home() / "tmp" / "hermes-backup-test-live" / f"{tmp_path.name}-corrupt"
    request.addfinalizer(lambda: shutil.rmtree(home_case_root, ignore_errors=True))
    shutil.rmtree(home_case_root, ignore_errors=True)
    live_paths = [str(home_case_root / include.lstrip("/")) for include in INCLUDES]
    write_live_fixture(live_paths)
    live_tree_before = snapshot_tree(live_paths)
    manifest_dir = write_manifest(tmp_path, live_paths)
    env = make_env(tmp_path, bin_dir, restic_log, curl_log, systemctl_log)
    promote_guard_log = tmp_path / "corrupt-implicit-promote.log"
    promote_guard = tmp_path / "corrupt-fail-if-promote.sh"
    promote_guard.write_text(
        "case \"$0\" in */promote.sh) "
        "printf 'implicit promote: %s\\n' \"$0\" >>\"$PROMOTE_GUARD_LOG\"; "
        "exit 97;; esac\n"
    )
    env.update(
        {
            "FAKE_RESTIC_INCLUDE_PATHS": "|".join(live_paths),
            "FAKE_RESTIC_CORRUPT_SQLITE": "1",
            "TELEGRAM_BOT_TOKEN": SECRETS[4],
            "HERMES_BACKUP_DRILL_ID": "20260705T000002Z",
            "BASH_ENV": str(promote_guard),
            "PROMOTE_GUARD_LOG": str(promote_guard_log),
        }
    )

    drill = subprocess.run(
        [
            "bash",
            str(DRILL_SCRIPT),
            "--config-env",
            str(env_file),
            "--manifest-dir",
            str(manifest_dir),
            "--restore-command",
            str(RESTORE_SCRIPT),
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    output = combined(drill)
    assert drill.returncode == 1, output
    sqlite_rel = f"{live_paths[0].lstrip('/')}/kanban.db"
    assert f"sqlite path={sqlite_rel} status=failed reason=integrity-check" in output
    assert "sqlite_failed=1" in output
    assert snapshot_tree(live_paths) == live_tree_before
    assert not promote_guard_log.exists()
    assert not systemctl_log.exists()
    curl_text = curl_log.read_text()
    assert curl_text.count("URL https://api.telegram.org/bot") == 1
    assert SECRETS[3] in curl_text
    assert SECRETS[4] not in curl_text
    assert "/sendMessage" in curl_text
    assert "gateway" not in curl_text.lower()
    payload = alert_message_payload(curl_text)
    assert "status: FAIL" in payload
    assert "sqlite_failed=1" in payload
    daily_logs = list(log_dir.glob("hermes-backup-*.log"))
    assert len(daily_logs) == 1
    assert "command=drill status=failure exit=1" in daily_logs[0].read_text()
    assert_no_secret_values(output + payload + daily_logs[0].read_text())
    assert not Path(env["FAKE_FORBIDDEN_COMMAND_LOG"]).exists()
    shutil.rmtree(home_case_root, ignore_errors=True)
