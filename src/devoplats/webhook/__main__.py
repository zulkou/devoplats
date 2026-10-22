from __future__ import annotations

import logging
import sys

from .app import create_app
from .config import ConfigError, Settings
from .docker_ops import ensure_image

log = logging.getLogger(__name__)


def main(argv: list[str] | None = None) -> int:
    try:
        settings = Settings.load()
    except (ConfigError, RuntimeError) as exc:
        print(f"devoplats-webhook: {exc}", file=sys.stderr)
        return 1

    settings.webhook_log.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=settings.webhook_log,
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    log.info("Loading platform settings from %s", settings.env_file)
    ensure_image(settings)

    app = create_app(settings)
    app.run(host=settings.webhook_host, port=settings.webhook_port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
