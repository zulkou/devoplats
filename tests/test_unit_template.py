from __future__ import annotations

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_install_dry_run_renders_unit() -> None:
    env = {**os.environ, "DEVOPS_ROOT": str(REPO_ROOT)}
    result = subprocess.run(
        [str(REPO_ROOT / "bin" / "devops"), "webhook", "install", "--dry-run"],
        capture_output=True,
        text=True,
        env=env,
        cwd=REPO_ROOT,
    )
    assert result.returncode == 0, result.stderr
    assert f"WorkingDirectory={REPO_ROOT}" in result.stdout
    assert f"Environment=DEVOPS_ROOT={REPO_ROOT}" in result.stdout
    assert f"ExecStart={REPO_ROOT}/.venv/bin/devoplats-webhook" in result.stdout
    assert "@DEVOPS_ROOT@" not in result.stdout
    assert "@WEBHOOK_BIN@" not in result.stdout
