from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from ..paths import find_devops_root, resolve_path


class ConfigError(ValueError):
    pass


def load_env_from_text(text: str) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key.startswith("export "):
            key = key[len("export ") :].strip()
        if not key:
            continue
        env[key] = value.strip().strip('"').strip("'")
    return env


def load_env(filepath: Path) -> dict[str, str]:
    if not filepath.exists():
        return {}
    return load_env_from_text(filepath.read_text())


@dataclass(frozen=True)
class Settings:
    root: Path
    env_file: Path
    environ: Mapping[str, str]
    dotenv: Mapping[str, str]

    @classmethod
    def load(
        cls,
        root: Path | None = None,
        environ: Mapping[str, str] | None = None,
    ) -> "Settings":
        resolved_root = Path(root).expanduser().resolve() if root else find_devops_root()
        values = dict(os.environ) if environ is None else dict(environ)
        env_file = resolved_root / ".env"
        dotenv = load_env(env_file)
        settings = cls(
            root=resolved_root,
            env_file=env_file,
            environ=values,
            dotenv=dotenv,
        )
        if not settings.webhook_secret:
            raise ConfigError(
                "GITHUB_WEBHOOK_SECRET is missing; refusing to run with signature verification disabled"
            )
        try:
            settings.webhook_port
        except ValueError as exc:
            raise ConfigError(str(exc)) from exc
        return settings

    def get(self, key: str, default: str = "") -> str:
        return self.environ.get(key) or self.dotenv.get(key) or default

    def path(self, key: str, default: str) -> Path:
        return resolve_path(self.root, self.get(key, default))

    @property
    def webhook_secret(self) -> str:
        return self.get("GITHUB_WEBHOOK_SECRET")

    @property
    def access_token(self) -> str:
        return self.get("ACCESS_TOKEN")

    @property
    def runner_image(self) -> str:
        return self.get("RUNNER_IMAGE", "myoung34/github-runner:latest")

    @property
    def runner_scope(self) -> str:
        return self.get("RUNNER_SCOPE", "org")

    @property
    def org_name(self) -> str:
        return self.get("ORG_NAME")

    @property
    def repo_url(self) -> str:
        url = self.get("REPO_URL")
        if url and "://" not in url:
            url = "https://github.com/" + url
        return url

    @property
    def apps_root(self) -> Path:
        return self.path("APPS_ROOT", "/opt/apps")

    @property
    def runner_ssh_dir(self) -> str:
        return self.get("RUNNER_SSH_DIR")

    @property
    def dns_servers(self) -> str:
        return self.get("DNS_SERVERS", "1.1.1.1,8.8.8.8")

    @property
    def webhook_log(self) -> Path:
        return self.path("WEBHOOK_LOG", str(self.root / "logs" / "webhook.log"))

    @property
    def webhook_host(self) -> str:
        return self.get("WEBHOOK_HOST", "0.0.0.0")

    @property
    def webhook_port(self) -> int:
        raw = self.get("WEBHOOK_PORT", "10000")
        try:
            return int(raw)
        except ValueError as exc:
            raise ValueError(f"WEBHOOK_PORT must be an integer (got {raw!r})") from exc
