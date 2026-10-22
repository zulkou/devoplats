from __future__ import annotations

from pathlib import Path

import pytest

from devoplats.paths import find_devops_root, resolve_path


def test_env_override(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DEVOPS_ROOT", str(tmp_path))
    assert find_devops_root() == tmp_path.resolve()


def test_cwd_walk_up(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "devops").write_text("#!/bin/sh\n")
    (tmp_path / "platform").mkdir()
    nested = tmp_path / "apps" / "myapp"
    nested.mkdir(parents=True)

    monkeypatch.delenv("DEVOPS_ROOT", raising=False)
    monkeypatch.chdir(nested)
    assert find_devops_root() == tmp_path.resolve()


def test_resolve_path(tmp_path: Path) -> None:
    assert resolve_path(tmp_path, "logs/webhook.log") == tmp_path / "logs" / "webhook.log"
    assert resolve_path(tmp_path, "/var/log/webhook.log") == Path("/var/log/webhook.log")
