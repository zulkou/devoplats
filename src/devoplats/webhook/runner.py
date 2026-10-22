from __future__ import annotations

import logging
import subprocess

from .config import Settings
from .docker_ops import local_docker_env

log = logging.getLogger(__name__)


def start_runner(settings: Settings, job_id: int, labels: str) -> bool:
    container_name = f"runner-{job_id}"
    try:
        log.info("Starting runner for job %s labels=%s", job_id, labels)

        runner_env = [
            "-e",
            f"ACCESS_TOKEN={settings.access_token}",
            "-e",
            f"RUNNER_SCOPE={settings.runner_scope}",
            "-e",
            f"RUNNER_LABELS={labels}",
            "-e",
            "EPHEMERAL=1",
        ]
        if settings.runner_scope == "org" or settings.org_name:
            runner_env += ["-e", f"ORG_NAME={settings.org_name}"]
        if settings.runner_scope == "repo" or settings.repo_url:
            runner_env += ["-e", f"REPO_URL={settings.repo_url}"]

        dns_args: list[str] = []
        for dns in settings.dns_servers.split(","):
            dns = dns.strip()
            if dns:
                dns_args += ["--dns", dns]

        ssh_mount: list[str] = []
        if settings.runner_ssh_dir:
            ssh_mount = ["-v", f"{settings.runner_ssh_dir}:/root/.ssh:ro"]

        proc = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "-d",
                f"--name={container_name}",
                *runner_env,
                "-v",
                "/var/run/docker.sock:/var/run/docker.sock",
                "-v",
                f"{settings.root}:{settings.root}",
                "-v",
                f"{settings.apps_root}:{settings.apps_root}",
                *ssh_mount,
                *dns_args,
                settings.runner_image,
            ],
            capture_output=True,
            timeout=300,
            env=local_docker_env(),
        )

        if proc.returncode != 0:
            log.error(
                "Failed to start runner for job %s: %s",
                job_id,
                proc.stderr.decode(errors="replace").strip(),
            )
            return False
        log.info("Runner %s started successfully", container_name)
        return True
    except Exception as exc:
        log.error("start_runner crashed for job %s: %s", job_id, exc)
        return False
