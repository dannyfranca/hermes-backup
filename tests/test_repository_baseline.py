import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def tracked_text_files():
    tracked = subprocess.check_output(
        ["git", "ls-files"],
        cwd=ROOT,
        text=True,
    ).splitlines()
    for name in tracked:
        path = ROOT / name
        if not path.is_file():
            continue
        yield path


def test_required_foundation_files_exist():
    required = [
        ".gitignore",
        "README.md",
        "SECURITY.md",
        "docs/bootstrap.md",
        "config/hermes-backup.env.example",
        "systemd/user/hermes-backup-backup.service",
        "systemd/user/hermes-backup-backup.timer",
    ]
    missing = [name for name in required if not (ROOT / name).is_file()]
    assert missing == []


def test_gitignore_blocks_local_secrets_and_outputs():
    text = (ROOT / ".gitignore").read_text()
    patterns = [
        ".env",
        "config/*.local",
        "secrets/",
        "logs/",
        "staging/",
        "restore/",
        "archives/",
        ".review/",
        "*.tar",
        ".venv/",
        ".cache/",
        "cache/",
        "restic-cache/",
        "node_modules/",
        "models/",
        "media/",
    ]
    missing = [pattern for pattern in patterns if pattern not in text]
    assert missing == []


def test_docs_mark_behavior_as_downstream():
    combined = "\n".join(
        (ROOT / path).read_text()
        for path in ["README.md", "docs/bootstrap.md", "SECURITY.md"]
    ).lower()
    assert "downstream" in combined
    assert "not implemented here" in combined or "current foundation ticket only" in combined
    assert "hermes cron" in combined
    assert "systemd" in combined
    assert "raw telegram bot api" in combined
    assert "explicit promote" in combined


def test_committed_examples_are_placeholder_only():
    forbidden_fragments = [
        "b2" + "_live_",
        "xox" + "b-",
        "gh" + "p_",
        "gh" + "s_",
        "-----begin " + "private key-----",
    ]
    telegram_token = re.compile(r"\b\d{7,}:[a-z0-9_-]{20,}\b", re.IGNORECASE)
    for path in tracked_text_files():
        text = path.read_text(errors="ignore").lower()
        hits = [fragment for fragment in forbidden_fragments if fragment in text]
        assert hits == [], f"{path.relative_to(ROOT)} contains suspicious fragments: {hits}"
        assert not telegram_token.search(text), f"{path.relative_to(ROOT)} contains a token-shaped Telegram credential"

    example = (ROOT / "config/hermes-backup.env.example").read_text()
    for line in example.splitlines():
        if not line or line.startswith("#"):
            continue
        _, value = line.split("=", 1)
        assert value.startswith(("PLACEHOLDER_", "EXAMPLE_")), line
