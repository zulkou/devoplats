from __future__ import annotations

from types import SimpleNamespace

from devoplats.webhook import runner
from devoplats.webhook.config import Settings


def run_runner(tmp_path, monkeypatch, environ: dict[str, str], **kwargs) -> list[str]:
    settings = Settings.load(
        root=tmp_path,
        environ={"GITHUB_WEBHOOK_SECRET": "secret", **environ},
    )
    calls = []

    def fake_run(cmd, **run_kwargs):
        calls.append(cmd)
        return SimpleNamespace(returncode=0, stderr=b"")

    monkeypatch.setattr(runner.subprocess, "run", fake_run)

    assert runner.start_runner(settings, 42, "self-hosted,linux", **kwargs) is True
    return calls[0]


def env_value(cmd: list[str], key: str) -> str | None:
    for i, arg in enumerate(cmd):
        if arg == "-e" and cmd[i + 1].startswith(f"{key}="):
            return cmd[i + 1].split("=", 1)[1]
    return None


def test_repo_scope_uses_payload_repo(tmp_path, monkeypatch) -> None:
    cmd = run_runner(tmp_path, monkeypatch, {"RUNNER_SCOPE": "repo"}, repo_name="zulkou/app2")
    assert env_value(cmd, "REPO_URL") == "https://github.com/zulkou/app2"


def test_repo_scope_falls_back_to_global_repo_url(tmp_path, monkeypatch) -> None:
    cmd = run_runner(
        tmp_path,
        monkeypatch,
        {"RUNNER_SCOPE": "repo", "REPO_URL": "owner/app1"},
    )
    assert env_value(cmd, "REPO_URL") == "https://github.com/owner/app1"


def test_org_scope_ignores_payload_repo(tmp_path, monkeypatch) -> None:
    cmd = run_runner(
        tmp_path,
        monkeypatch,
        {"RUNNER_SCOPE": "org", "ORG_NAME": "acme"},
        repo_name="zulkou/app2",
    )
    assert env_value(cmd, "ORG_NAME") == "acme"
    assert env_value(cmd, "REPO_URL") is None
