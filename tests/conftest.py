from __future__ import annotations

from pathlib import Path

import pytest

from devoplats.webhook.config import Settings


@pytest.fixture
def settings_factory(tmp_path: Path):
    def make(env_text: str = "", environ: dict[str, str] | None = None) -> Settings:
        (tmp_path / ".env").write_text(env_text)
        return Settings.load(root=tmp_path, environ=environ or {})
    return make
