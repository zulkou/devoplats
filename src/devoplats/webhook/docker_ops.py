from __future__ import annotations

import logging
import os
import subprocess

from .config import Settings

log = logging.getLogger(__name__)


def local_docker_env() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("DOCKER_HOST", None)
    env.pop("DOCKER_CONTEXT", None)
    return env


def ensure_image(settings: Settings) -> bool:
    proc = subprocess.run(
        ["docker", "image", "inspect", settings.runner_image],
        capture_output=True,
        timeout=30,
        env=local_docker_env(),
    )
    if proc.returncode == 0:
        log.info("Image found locally: %s", settings.runner_image)
        return True

    log.info("Pulling runner image: %s", settings.runner_image)
    proc = subprocess.run(
        ["docker", "pull", settings.runner_image],
        capture_output=True,
        timeout=300,
        env=local_docker_env(),
    )
    if proc.returncode != 0:
        log.error("docker pull failed: %s", proc.stderr.decode(errors="replace").strip())
        return False
    log.info("Image pulled: %s", settings.runner_image)
    return True
