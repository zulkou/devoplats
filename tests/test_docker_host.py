"""Matrix for resolve_docker_host() in platform/lib/common.sh.

The resolver is shell code, so each case runs it in a clean bash subprocess:
DEVOPS_ROOT points at an empty tmp dir (the repo's real .env is never read)
and every DOCKER_HOST*/DOCKER_CONTEXT value inherited from the test runner is
scrubbed before the case's own variables are applied.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
COMMON_SH = REPO_ROOT / "platform" / "lib" / "common.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None or shutil.which("yq") is None,
    reason="the platform scripts need bash and yq",
)

_RESOLVE_SCRIPT = (
    "set -euo pipefail\n"
    f'source "{COMMON_SH}"\n'
    "resolve_docker_host\n"
    'printf "HOST=%s\\n" "${DOCKER_HOST:-local}"\n'
    'printf "CONTEXT=%s\\n" "${DOCKER_CONTEXT:-<unset>}"\n'
)

MAP_DEV_PROD = "docker:\n  host:\n    dev: ssh://dev-a\n    prod: ssh://prod-a\n"


def _clean_env(tmp_path: Path) -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if key != "DOCKER_HOST"
        and key != "DOCKER_CONTEXT"
        and not key.startswith("DOCKER_HOST_")
    }
    for key in ("APP", "CONFIG_FILE", "ENVIRONMENT"):
        env.pop(key, None)
    env["DEVOPS_ROOT"] = str(tmp_path / "root")
    return env


def run_resolver(
    tmp_path: Path,
    config: str | None = None,
    environment: str | None = None,
    environ: dict[str, str] | None = None,
    config_path: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    env = _clean_env(tmp_path)
    if config is not None:
        path = tmp_path / "config.yml"
        path.write_text(config, encoding="utf-8")
        env["CONFIG_FILE"] = str(path)
    elif config_path is not None:
        env["CONFIG_FILE"] = str(config_path)
    if environment is not None:
        env["ENVIRONMENT"] = environment
    env.update(environ or {})
    return subprocess.run(
        ["bash", "-c", _RESOLVE_SCRIPT],
        env=env,
        capture_output=True,
        text=True,
    )


def _resolved(run: subprocess.CompletedProcess[str]) -> tuple[str, str]:
    assert run.returncode == 0, run.stderr
    values = dict(
        line.split("=", 1) for line in run.stdout.splitlines() if "=" in line
    )
    return values["HOST"], values["CONTEXT"]


OUTCOME_CASES = [
    # A — resolves to the local daemon (DOCKER_HOST ends unset)
    pytest.param(None, None, None, False, "local", id="A1-nothing-configured"),
    pytest.param(
        "docker:\n  host: local\n",
        "dev",
        {"DOCKER_HOST": "ssh://global"},
        False,
        "local",
        id="A2-scalar-local-beats-global",
    ),
    pytest.param(
        "docker:\n  host:\n    dev: local\n",
        "dev",
        {"DOCKER_HOST_DEV": "ssh://dev-a", "DOCKER_HOST": "ssh://global"},
        False,
        "local",
        id="A3-map-local-beats-env-rungs",
    ),
    pytest.param(
        "healthcheck:\n  url: http://app:80/\n",
        "dev",
        {"DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="A4-host-key-absent-falls-through",
    ),
    pytest.param(
        "docker:\n  host: null\n",
        "dev",
        {"DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="A5-host-null-falls-through",
    ),
    pytest.param(
        MAP_DEV_PROD,
        "staging",
        {"DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="A6-map-missing-env-falls-through",
    ),
    pytest.param(
        MAP_DEV_PROD,
        None,
        {"DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="A7-map-without-env-uses-global",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST_DEV": "local"},
        False,
        "local",
        id="A8-env-rung-local",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST": "local"},
        False,
        "local",
        id="A9-global-local",
    ),
    # B — resolves to a remote daemon
    pytest.param(
        "docker:\n  host: ssh://devoplats-remote\n",
        "dev",
        None,
        False,
        "ssh://devoplats-remote",
        id="B1-scalar-ssh",
    ),
    pytest.param(MAP_DEV_PROD, "dev", None, False, "ssh://dev-a", id="B2-map-dev"),
    pytest.param(MAP_DEV_PROD, "prod", None, False, "ssh://prod-a", id="B3-map-prod"),
    pytest.param(
        "docker:\n  host: unix:///run/docker.sock\n",
        "dev",
        None,
        False,
        "unix:///run/docker.sock",
        id="B4-scalar-unix",
    ),
    pytest.param(
        "docker:\n  host: tcp://10.0.0.5:2375\n",
        "dev",
        None,
        False,
        "tcp://10.0.0.5:2375",
        id="B5-scalar-tcp",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST_DEV": "ssh://env-dev"},
        False,
        "ssh://env-dev",
        id="B6-env-rung",
    ),
    pytest.param(
        None,
        "staging-eu",
        {"DOCKER_HOST_STAGING_EU": "ssh://stg"},
        False,
        "ssh://stg",
        id="B7-env-rung-normalized-name",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="B8-global-fallback",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST_DEV": "", "DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="B9-empty-env-rung-falls-to-global",
    ),
    pytest.param(
        'docker:\n  host:\n    dev: ""\n',
        "dev",
        {"DOCKER_HOST_DEV": "ssh://env-dev"},
        False,
        "ssh://env-dev",
        id="B10-empty-map-value-falls-to-env",
    ),
    # C — precedence and fall-through
    pytest.param(
        "docker:\n  host: ssh://app\n",
        "dev",
        {"DOCKER_HOST_DEV": "ssh://env-dev", "DOCKER_HOST": "ssh://global"},
        False,
        "ssh://app",
        id="C1-scalar-beats-env-and-global",
    ),
    pytest.param(
        "docker:\n  host:\n    dev: ssh://app-dev\n",
        "dev",
        {"DOCKER_HOST_DEV": "ssh://env-dev"},
        False,
        "ssh://app-dev",
        id="C2-map-beats-env-rung",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST_DEV": "ssh://env-dev", "DOCKER_HOST": "ssh://global"},
        False,
        "ssh://env-dev",
        id="C3-env-rung-beats-global",
    ),
    pytest.param(
        "docker:\n  host: local\n",
        "dev",
        {"DOCKER_HOST_DEV": "ssh://env-dev"},
        False,
        "local",
        id="C4-scalar-local-beats-env-rung",
    ),
    pytest.param(
        'docker:\n  host: ""\n',
        "dev",
        {"DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="C5-empty-scalar-falls-through",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST_DEV": "ssh://env-dev"},
        True,
        "ssh://env-dev",
        id="C6-config-file-missing-falls-to-env",
    ),
    pytest.param(
        None,
        "dev",
        {"DOCKER_HOST": "ssh://global"},
        False,
        "ssh://global",
        id="C7-config-file-unset-falls-to-global",
    ),
    # E — context / ambient environment hygiene
    pytest.param(
        "docker:\n  host: ssh://app\n",
        "dev",
        {"DOCKER_CONTEXT": "lab"},
        False,
        "ssh://app",
        id="E1-ambient-context-dropped",
    ),
    pytest.param(
        "docker:\n  host: local\n",
        "dev",
        {"DOCKER_HOST": "ssh://ambient"},
        False,
        "local",
        id="E2-ambient-host-cleared-by-local",
    ),
    pytest.param(
        "docker:\n  host: ssh://app\n",
        "dev",
        {"DOCKER_HOST": "ssh://ambient"},
        False,
        "ssh://app",
        id="E3-ambient-host-overridden",
    ),
]

REJECT_CASES = [
    pytest.param(
        "docker:\n  host: ssh://a,ssh://b\n",
        None,
        "comma lists are not supported",
        id="D1-comma-scalar-config",
    ),
    pytest.param(
        "docker:\n  host:\n    dev: ssh://a,ssh://b\n",
        None,
        "comma lists are not supported",
        id="D2-comma-map-value",
    ),
    pytest.param(
        None,
        {"DOCKER_HOST_DEV": "ssh://a,ssh://b"},
        "comma lists are not supported",
        id="D3-comma-env-rung",
    ),
    pytest.param(
        None,
        {"DOCKER_HOST": "ssh://a, ssh://b"},
        "comma lists are not supported",
        id="D4-comma-global",
    ),
    pytest.param(
        "docker:\n  host: ssh://my host\n",
        None,
        "comma lists are not supported",
        id="D5-whitespace-in-host",
    ),
    pytest.param(
        "docker:\n  host: devoplats-remote\n",
        None,
        "use local, ssh://, unix:// or tcp://",
        id="D6-bare-hostname",
    ),
    pytest.param(
        "docker:\n  host: foo://x\n",
        None,
        "use local, ssh://, unix:// or tcp://",
        id="D7-unknown-scheme",
    ),
]


@pytest.mark.parametrize(
    "config,environment,environ,missing_config,expected", OUTCOME_CASES
)
def test_resolver_outcome(
    tmp_path: Path,
    config: str | None,
    environment: str | None,
    environ: dict[str, str] | None,
    missing_config: bool,
    expected: str,
) -> None:
    run = run_resolver(
        tmp_path,
        config=config,
        environment=environment,
        environ=environ,
        config_path=tmp_path / "missing.yml" if missing_config else None,
    )
    host, context = _resolved(run)
    assert host == expected
    assert context == "<unset>"


@pytest.mark.parametrize("config,environ,message", REJECT_CASES)
def test_resolver_rejects(
    tmp_path: Path,
    config: str | None,
    environ: dict[str, str] | None,
    message: str,
) -> None:
    run = run_resolver(tmp_path, config=config, environment="dev", environ=environ)
    assert run.returncode == 1
    assert "Invalid Docker host" in run.stderr
    assert message in run.stderr


def test_init_environment_applies_app_config(tmp_path: Path) -> None:
    config_dir = tmp_path / "configs" / "hello-world"
    config_dir.mkdir(parents=True)
    (config_dir / "config.yml").write_text(
        "docker:\n  host: ssh://app-host\n", encoding="utf-8"
    )
    (tmp_path / "apps" / "hello-world").mkdir(parents=True)

    env = _clean_env(tmp_path)
    env.update(
        {
            "APP": "hello-world",
            "ENVIRONMENT": "dev",
            "APPS_ROOT": str(tmp_path / "apps"),
            "CONFIGS_ROOT": str(tmp_path / "configs"),
        }
    )
    script = (
        "set -euo pipefail\n"
        f'source "{COMMON_SH}"\n'
        "init_environment\n"
        'printf "HOST=%s\\n" "${DOCKER_HOST:-local}"\n'
    )
    run = subprocess.run(
        ["bash", "-c", script], env=env, capture_output=True, text=True
    )
    assert run.returncode == 0, run.stderr
    assert "HOST=ssh://app-host" in run.stdout
