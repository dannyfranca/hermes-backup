import os
import re
import stat
import subprocess
from pathlib import Path

from test_stage import make_executable

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "promote.sh"
MARKER = '{"tool":"restore.sh","mode":"non-live-inspection-only","snapshot":"latest","promote":"false","schema_version":1}\n'
SECRETS=["DUMMY_PROMOTE_B2_APPLICATION_KEY_NOT_REAL", "DUMMY_PROMOTE_RESTIC_PASSWORD_NOT_REAL", "DUMMY_PROMOTE_TELEGRAM_TOKEN_NOT_REAL", "RAW_BACKUP_CONTENT_SHOULD_NOT_PRINT"]
INCLUDES = ["/home/agent/.hermes", "/home/agent/shared", "/home/agent/shared-assets", "/home/agent/.config/systemd/user", "/home/agent/.config/containers/systemd"]


def combined(result) -> str:
    return result.stdout + result.stderr


def write(root: Path, live_path: str, body: str) -> Path:
    p = root / live_path.lstrip("/")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body)
    return p


def manifest(tmp_path: Path, paths=None) -> Path:
    d = tmp_path / "manifests"; d.mkdir()
    (d / "include.paths").write_text("\n".join(paths or INCLUDES) + "\n")
    (d / "exclude.patterns").write_text("/tmp/unused/**\n")
    return d


def fixture(tmp_path: Path, paths=None):
    paths = paths or INCLUDES
    live, restore, backup, man = tmp_path / "live", tmp_path / "restore/latest", tmp_path / "backups", manifest(tmp_path, paths)
    for i, p in enumerate(paths):
        write(live, f"{p}/current.txt", f"old {i} {SECRETS[i % len(SECRETS)]}\n")
        write(restore, f"{p}/restored.txt", f"new {i} {SECRETS[i % len(SECRETS)]}\n")
    (restore / ".hermes-backup-restore.json").write_text(MARKER)
    return live, restore, backup, man


def fake_systemctl(tmp_path: Path, active_units=None, unavailable=False, stubborn_stop=False, list_fail=False):
    active_units = active_units if active_units is not None else ["hermes-gateway.service"]
    bin_dir = tmp_path / "bin"; bin_dir.mkdir(exist_ok=True)
    log = tmp_path / "systemctl.log"
    state = tmp_path / "systemctl-state.txt"
    state.write_text("\n".join(active_units) + ("\n" if active_units else ""))
    make_executable(bin_dir / "systemctl", r'''
        #!/usr/bin/env python3
        import fnmatch, os, sys
        from pathlib import Path
        args = sys.argv[1:]
        Path(os.environ["FAKE_SYSTEMCTL_LOG"]).open("a").write(" ".join(args) + "\n")
        if os.environ.get("FAKE_SYSTEMCTL_UNAVAILABLE") == "1":
            sys.exit(1)
        state = Path(os.environ["FAKE_SYSTEMCTL_STATE"])
        active = [line.strip() for line in state.read_text().splitlines() if line.strip()]
        if args[:2] == ["--user", "list-units"]:
            if os.environ.get("FAKE_SYSTEMCTL_LIST_FAIL") == "1" and any(arg.startswith("hermes") for arg in args[2:]):
                sys.exit(41)
            pattern = next((arg for arg in reversed(args) if "*" in arg or arg.endswith(".service")), "*")
            for unit in active:
                if fnmatch.fnmatch(unit, pattern):
                    print(f"{unit} loaded active running fake")
            sys.exit(0)
        if args[:3] == ["--user", "is-active", "--quiet"]:
            sys.exit(0 if args[3] in active else 3)
        if args[:2] == ["--user", "stop"]:
            unit = args[2]
            if os.environ.get("FAKE_SYSTEMCTL_STUBBORN_STOP") != "1":
                active = [u for u in active if u != unit]
                state.write_text("\n".join(active) + ("\n" if active else ""))
            sys.exit(0)
        if args[:2] == ["--user", "daemon-reload"]:
            sys.exit(0)
        sys.exit(2)
    ''')
    ps_log = tmp_path / "ps.log"
    termination_log = tmp_path / "termination.log"
    make_executable(
        bin_dir / "ps",
        "#!/usr/bin/env python3\n"
        "from pathlib import Path\n"
        "import os\n"
        "Path(os.environ['FAKE_PS_LOG']).open('a').write('ps called\\n')\n",
    )
    for command in ["kill", "pkill", "killall"]:
        make_executable(
            bin_dir / command,
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "import os, sys\n"
            "Path(os.environ['FAKE_TERMINATION_LOG']).open('a').write(sys.argv[0] + ' ' + ' '.join(sys.argv[1:]) + '\\n')\n"
            "sys.exit(98)\n",
        )
    env = {"FAKE_SYSTEMCTL_LOG": str(log), "FAKE_SYSTEMCTL_STATE": str(state), "FAKE_PS_LOG": str(ps_log), "FAKE_TERMINATION_LOG": str(termination_log)}
    if unavailable:
        env["FAKE_SYSTEMCTL_UNAVAILABLE"] = "1"
    if stubborn_stop:
        env["FAKE_SYSTEMCTL_STUBBORN_STOP"] = "1"
    if list_fail:
        env["FAKE_SYSTEMCTL_LIST_FAIL"] = "1"
    return bin_dir, log, env


def fake_ps(tmp_path: Path, rows):
    bin_dir = tmp_path / "bin"; bin_dir.mkdir(exist_ok=True)
    log = tmp_path / "ps.log"
    ps_output = "\n".join(rows) + ("\n" if rows else "")
    make_executable(
        bin_dir / "ps",
        "#!/usr/bin/env python3\n"
        "from pathlib import Path\n"
        "import os\n"
        "Path(os.environ['FAKE_PS_LOG']).open('a').write('ps called\\n')\n"
        f"print({ps_output!r}, end='')\n",
    )
    termination_log = tmp_path / "termination.log"
    for command in ["kill", "pkill", "killall"]:
        make_executable(
            bin_dir / command,
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "import os, sys\n"
            "Path(os.environ['FAKE_TERMINATION_LOG']).open('a').write(sys.argv[0] + ' ' + ' '.join(sys.argv[1:]) + '\\n')\n"
            "sys.exit(98)\n",
        )
    return bin_dir, log, {"FAKE_PS_LOG": str(log), "FAKE_TERMINATION_LOG": str(termination_log)}


def run(*args, env=None):
    e = os.environ.copy(); e.update(env or {})
    return subprocess.run(["bash", str(SCRIPT), *map(str, args)], cwd=ROOT, env=e, text=True, capture_output=True, check=False)


def args(live, backup, man, restore, *extra):
    return ["--manifest-dir", man, "--live-root", live, "--backup-root", backup, *extra, restore]


def no_secrets(output: str):
    for s in SECRETS:
        assert s not in output


def backup_dir(output: str) -> Path:
    m = re.search(r"^pre_promotion_backup=(.+)$", output, re.MULTILINE)
    assert m, output
    return Path(m.group(1))


def test_promote_has_valid_bash_syntax_and_is_executable():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=ROOT, text=True, capture_output=True, check=False)
    assert result.returncode == 0, combined(result)
    assert SCRIPT.stat().st_mode & stat.S_IXUSR


def test_promote_requires_explicit_restore_path_and_confirmation(tmp_path):
    result = run()
    assert result.returncode != 0 and "RESTORE_DIR is required" in combined(result)
    live, restore, backup, man = fixture(tmp_path)
    result = run(*args(live, backup, man, restore))
    output = combined(result)
    assert result.returncode != 0
    assert "requires --yes --confirm PROMOTE-HERMES-RESTORE" in output
    assert not backup.exists(); no_secrets(output)


def test_dry_run_validates_layout_without_changing_live_paths(tmp_path):
    live, restore, backup, man = fixture(tmp_path)
    bin_dir, _, probe_env = fake_systemctl(tmp_path, active_units=[])
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **probe_env}
    before = (live / "home/agent/.hermes/current.txt").read_text()
    result = run(*args(live, backup, man, restore, "--dry-run"), env=env)
    output = combined(result)
    assert result.returncode == 0, output
    assert "mode=dry-run promote=false" in output and "dry_run=ok no_live_paths_changed=true" in output
    assert (live / "home/agent/.hermes/current.txt").read_text() == before
    assert not backup.exists(); no_secrets(output)


def test_refuses_unmarked_arbitrary_and_live_overlapping_restore_paths(tmp_path):
    live, restore, backup, man = fixture(tmp_path)
    arbitrary = tmp_path / "arbitrary"; arbitrary.mkdir()
    output = combined(run(*args(live, backup, man, arbitrary, "--dry-run")))
    assert "missing restore provenance marker" in output; no_secrets(output)
    live_overlap = live / "home/agent/.hermes"
    (live_overlap / ".hermes-backup-restore.json").write_text(MARKER)
    output = combined(run(*args(live, backup, man, live_overlap, "--dry-run")))
    assert "refusing promote from restore path overlapping live include path" in output; no_secrets(output)


def test_confirmed_promote_backs_up_before_replacing_and_reloads_systemd(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes", "/home/agent/shared"])
    (restore / "home/agent/.hermes").chmod(0o700)
    bin_dir, log, systemctl_env = fake_systemctl(tmp_path)
    ps_seen = tmp_path / "ps-seen"
    make_executable(
        bin_dir / "ps",
        "#!/usr/bin/env python3\n"
        "from pathlib import Path\n"
        "import os\n"
        "seen = Path(os.environ['FAKE_PS_SEEN'])\n"
        "if not seen.exists():\n"
        "    seen.write_text('1')\n"
        "    print('4321 hermes-gateway /usr/bin/hermes-gateway --serve')\n",
    )
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env, "FAKE_PS_SEEN": str(ps_seen)}
    result = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    output = combined(result)
    assert result.returncode == 0, output; no_secrets(output)
    b = backup_dir(output)
    assert (b / "home/agent/.hermes/current.txt").read_text().startswith("old 0")
    assert (b / "home/agent/shared/current.txt").read_text().startswith("old 1")
    assert (live / "home/agent/.hermes/restored.txt").read_text().startswith("new 0")
    assert stat.S_IMODE((live / "home/agent/.hermes").stat().st_mode) == 0o700
    assert output.index("backup live_path=/home/agent/.hermes") < output.index("promote live_path=/home/agent/.hermes")
    assert "quiesce process_class=hermes-gateway pid=4321 command=hermes-gateway status=active action=covered-by-reviewed-service-stop" in output
    assert "--user stop hermes-gateway.service" in log.read_text() and "--user daemon-reload" in log.read_text()

def test_dry_run_reports_quiesce_plan_without_stopping_services_or_mutating(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    bin_dir, log, systemctl_env = fake_systemctl(tmp_path, active_units=["hermes-gateway.service", "hermes-worker.service"])
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env}
    before = (live / "home/agent/.hermes/current.txt").read_text()
    result = run(*args(live, backup, man, restore, "--dry-run"), env=env)
    output = combined(result)
    assert result.returncode == 0, output; no_secrets(output)
    assert "quiesce service=hermes-gateway.service status=active action=stop-reviewed-before-promote" in output
    assert "quiesce service=hermes-worker.service status=active action=manual-stop-or-ack" in output
    assert "systemd_user=stop unit=" not in output
    assert (live / "home/agent/.hermes/current.txt").read_text() == before
    assert not backup.exists()
    assert "--user stop" not in log.read_text()


def test_confirmed_promote_refuses_unreviewed_active_service_without_quiesce_ack(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    bin_dir, _, systemctl_env = fake_systemctl(tmp_path, active_units=["hermes-worker.service"])
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env}
    before = (live / "home/agent/.hermes/current.txt").read_text()
    result = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    output = combined(result)
    assert result.returncode != 0
    assert "active or unverified Hermes services/processes remain" in output
    assert "backup live_path=" not in output and "promote live_path=" not in output
    assert not backup.exists()
    assert (live / "home/agent/.hermes/current.txt").read_text() == before


def test_confirmed_promote_refuses_mixed_blockers_before_stopping_reviewed_services(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    bin_dir, log, systemctl_env = fake_systemctl(tmp_path, active_units=["hermes-gateway.service", "hermes-worker.service"])
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env}
    result = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    output = combined(result)
    assert result.returncode != 0
    assert "quiesce service=hermes-worker.service status=active action=manual-stop-or-ack" in output
    assert "systemd_user=stop unit=" not in output
    assert "--user stop" not in log.read_text()
    assert not backup.exists()


def test_confirmed_promote_requires_ack_when_service_enumeration_fails(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    bin_dir, _, systemctl_env = fake_systemctl(tmp_path, active_units=[], list_fail=True)
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env}
    result = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    output = combined(result)
    assert result.returncode != 0
    assert "quiesce service_probe=systemd_user_list_units pattern=hermes*.service status=failed action=manual-check-or-ack" in output
    assert "backup live_path=" not in output
    assert not backup.exists()


def test_confirmed_promote_refuses_reviewed_service_that_remains_active_after_stop(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    bin_dir, log, systemctl_env = fake_systemctl(tmp_path, active_units=["hermes-gateway.service"], stubborn_stop=True)
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env}
    result = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    output = combined(result)
    assert result.returncode != 0
    assert "quiesce service=hermes-gateway.service status=active action=stop-reviewed-before-promote" in output
    assert "reviewed Hermes services remain active after stop" in output
    assert "backup live_path=" not in output and "promote live_path=" not in output
    assert not backup.exists()
    assert "--user stop hermes-gateway.service" in log.read_text()


def test_confirmed_promote_requires_ack_when_process_probe_fails(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    bin_dir, _, systemctl_env = fake_systemctl(tmp_path, active_units=[])
    make_executable(bin_dir / "ps", "#!/usr/bin/env python3\nimport sys\nsys.exit(42)\n")
    env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env}
    result = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    output = combined(result)
    assert result.returncode != 0
    assert "quiesce process_probe=ps status=failed action=manual-check-or-ack" in output
    assert "backup live_path=" not in output
    assert not backup.exists()


def test_confirmed_promote_requires_ack_for_active_hermes_processes_and_never_kills_them(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    systemctl_bin, _, systemctl_env = fake_systemctl(tmp_path, active_units=[])
    ps_bin, ps_log, ps_env = fake_ps(tmp_path, ["4321 hermes-worker /usr/bin/hermes-worker --once"])
    env = {"PATH": f"{ps_bin}{os.pathsep}{systemctl_bin}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env, **ps_env}
    before = (live / "home/agent/.hermes/current.txt").read_text()
    refused = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    refused_output = combined(refused)
    assert refused.returncode != 0
    assert "quiesce process_class=hermes-worker pid=4321 command=hermes-worker status=active action=manual-stop-or-ack" in refused_output
    assert (live / "home/agent/.hermes/current.txt").read_text() == before

    accepted = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE", "--quiesce-ack", "PROMOTE-HERMES-QUIESCE"), env=env)
    accepted_output = combined(accepted)
    assert accepted.returncode == 0, accepted_output; no_secrets(accepted_output)
    assert "quiesce=acknowledged" in accepted_output
    assert (live / "home/agent/.hermes/restored.txt").read_text().startswith("new 0")
    assert ps_log.read_text().count("ps called") >= 2
    assert not Path(ps_env["FAKE_TERMINATION_LOG"]).exists()
    assert "kill" not in accepted_output.lower()


def test_confirmed_promote_requires_ack_when_systemd_probe_unavailable(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    systemctl_bin, _, systemctl_env = fake_systemctl(tmp_path, unavailable=True)
    ps_bin, _, ps_env = fake_ps(tmp_path, [])
    env = {"PATH": f"{ps_bin}{os.pathsep}{systemctl_bin}{os.pathsep}{os.environ.get('PATH','')}", **systemctl_env, **ps_env}
    result = run(*args(live, backup, man, restore, "--yes", "--confirm", "PROMOTE-HERMES-RESTORE"), env=env)
    output = combined(result)
    assert result.returncode != 0
    assert "quiesce service_probe=systemd_user status=unavailable action=manual-check-or-ack" in output
    assert "backup live_path=" not in output
    assert not backup.exists()


def test_refuses_symlinked_live_restore_and_restored_path_components(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    live_target = live / "home/agent/.hermes"
    live_real = live / "home/agent/.hermes-real"
    live_target.rename(live_real); live_target.symlink_to(live_real, target_is_directory=True)
    output = combined(run(*args(live, backup, man, restore, "--dry-run")))
    assert "live include path must not contain symlinked path components" in output

    live_target.unlink(); live_real.rename(live_target)
    restored = restore / "home/agent/.hermes"
    restored_real = restore / "home/agent/.hermes-real"
    restored.rename(restored_real); restored.symlink_to(restored_real, target_is_directory=True)
    output = combined(run(*args(live, backup, man, restore, "--dry-run")))
    assert "restored include path must not contain symlinked path components" in output
    assert not backup.exists(); no_secrets(output)


def test_refuses_file_restored_include_root(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    restored = restore / "home/agent/.hermes"
    for child in restored.iterdir(): child.unlink()
    restored.rmdir(); restored.write_text("not a directory\n")
    output = combined(run(*args(live, backup, man, restore, "--dry-run")))
    assert "restored include path must be a directory" in output
    assert not backup.exists(); no_secrets(output)


def test_refuses_restore_dir_argument_symlink_and_symlinked_restore_ancestor(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    link = tmp_path / "restore-link"; link.symlink_to(restore, target_is_directory=True)
    output = combined(run(*args(live, backup, man, link, "--dry-run")))
    assert "RESTORE_DIR must not contain symlinked path components" in output
    restored_home = restore / "home"
    outside = tmp_path / "outside-home"
    restored_home.rename(outside); restored_home.symlink_to(live / "home", target_is_directory=True)
    output = combined(run(*args(live, backup, man, restore, "--dry-run")))
    assert "restored include path must not contain symlinked path components" in output
    assert not backup.exists(); no_secrets(output)


def test_refuses_symlinked_live_root_argument(tmp_path):
    live, restore, backup, man = fixture(tmp_path, ["/home/agent/.hermes"])
    live_link = tmp_path / "live-link"
    live_link.symlink_to(live, target_is_directory=True)
    output = combined(run(*args(live_link, backup, man, restore, "--dry-run")))
    assert "live root must not contain symlinked path components" in output
    assert not backup.exists(); no_secrets(output)


def test_refuses_backup_root_overlapping_restore_or_live_paths(tmp_path):
    live, restore, _, man = fixture(tmp_path, ["/home/agent/.hermes"])
    cases = [(restore / "backup", "--backup-root must not overlap RESTORE_DIR"), (live / "home/agent/.hermes/backup", "--backup-root must not overlap live include path")]
    for unsafe, expected in cases:
        output = combined(run(*args(live, unsafe, man, restore, "--dry-run")))
        assert expected in output
        assert not unsafe.exists(); no_secrets(output)
    unsafe_real = live / "home/agent/.hermes/real-backup"
    unsafe_link = tmp_path / "backup-link"
    unsafe_link.symlink_to(unsafe_real, target_is_directory=True)
    output = combined(run(*args(live, unsafe_link, man, restore, "--dry-run")))
    assert "backup root must not contain symlinked path components" in output
    assert not unsafe_real.exists(); no_secrets(output)
