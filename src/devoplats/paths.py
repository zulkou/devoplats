from __future__ import annotations

import os
from pathlib import Path


def resolve_path(root: Path, value: str) -> Path:
    path = Path(value).expanduser()
    return path if path.is_absolute() else (root / path)


def find_devops_root() -> Path:
    configured = os.environ.get("DEVOPS_ROOT")
    if configured:
        return Path(configured).expanduser().resolve()

    cwd = Path.cwd().resolve()
    for candidate in (cwd, *cwd.parents):
        if (candidate / "bin" / "devops").is_file() and (candidate / "platform").is_dir():
            return candidate

    package = Path(__file__).resolve()
    for candidate in (package, *package.parents):
        if (candidate / "bin" / "devops").is_file() and (candidate / "platform").is_dir():
            return candidate

    raise RuntimeError(
        "cannot locate the devoplats install root; set DEVOPS_ROOT or run from inside the repository"
    )
