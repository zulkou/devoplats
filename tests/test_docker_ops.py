from __future__ import annotations

from types import SimpleNamespace

from devoplats.webhook import docker_ops
from devoplats.webhook.config import Settings


def test_ensure_image_pulls_upstream_when_missing(tmp_path, monkeypatch) -> None:
    settings = Settings.load(
        root=tmp_path,
        environ={"GITHUB_WEBHOOK_SECRET": "secret"},
    )
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return SimpleNamespace(returncode=0 if cmd[1] == "pull" else 1, stderr=b"")

    monkeypatch.setattr(docker_ops.subprocess, "run", fake_run)

    assert docker_ops.ensure_image(settings) is True
    assert calls[0][:2] == ["docker", "image"]
    assert calls[1] == ["docker", "pull", "myoung34/github-runner:latest"]
