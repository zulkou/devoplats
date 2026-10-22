from __future__ import annotations

from pathlib import Path

import pytest

from devoplats.webhook.config import ConfigError, Settings, load_env_from_text


def test_env_overrides_dotenv(settings_factory) -> None:
    settings = settings_factory(
        env_text="GITHUB_WEBHOOK_SECRET=from-file\nRUNNER_IMAGE=from-file\n",
        environ={"RUNNER_IMAGE": "from-shell"},
    )
    assert settings.webhook_secret == "from-file"
    assert settings.runner_image == "from-shell"


def test_defaults(tmp_path: Path) -> None:
    settings = Settings.load(root=tmp_path, environ={"GITHUB_WEBHOOK_SECRET": "s"})
    assert settings.apps_root == Path("/opt/apps")
    assert settings.webhook_port == 10000
    assert settings.runner_image == "myoung34/github-runner:latest"
    assert settings.root == tmp_path.resolve()


def test_missing_secret_raises(tmp_path: Path) -> None:
    with pytest.raises(ConfigError):
        Settings.load(root=tmp_path, environ={})


def test_invalid_port_raises(settings_factory) -> None:
    with pytest.raises(ConfigError):
        settings_factory(env_text="GITHUB_WEBHOOK_SECRET=s\nWEBHOOK_PORT=not-a-port\n")


def test_repo_url_normalization(settings_factory) -> None:
    settings = settings_factory(
        env_text="GITHUB_WEBHOOK_SECRET=s\nREPO_URL=owner/repo\n",
    )
    assert settings.repo_url == "https://github.com/owner/repo"


def test_load_env_from_text_ignores_noise() -> None:
    parsed = load_env_from_text(
        "# comment\n\nexport FOO=bar\nBAZ = 'quoted'\nINVALID\n"
    )
    assert parsed == {"FOO": "bar", "BAZ": "quoted"}
