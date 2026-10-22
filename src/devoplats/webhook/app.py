from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from typing import Any

from flask import Flask, request

from .config import Settings
from .runner import start_runner
from .security import verify_signature

log = logging.getLogger(__name__)
RECENT_TTL = 300


def create_app(
    settings: Settings,
    dispatch: Callable[[Settings, int, str], bool] | None = None,
    thread_factory: Callable[..., Any] | None = None,
    timer_factory: Callable[..., Any] | None = None,
) -> Flask:
    dispatch = dispatch or start_runner
    thread_factory = thread_factory or threading.Thread
    timer_factory = timer_factory or threading.Timer

    app = Flask(__name__)
    recent_jobs: set[int] = set()
    app.extensions["devoplats_settings"] = settings
    app.extensions["devoplats_recent_jobs"] = recent_jobs

    def remember(job_id: int) -> None:
        recent_jobs.add(job_id)
        timer = timer_factory(RECENT_TTL, recent_jobs.discard, [job_id])
        timer.daemon = True
        timer.start()

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/webhooks/github")
    def webhook() -> tuple[str, int]:
        signature = request.headers.get("X-Hub-Signature-256", "")
        if not verify_signature(settings.webhook_secret, request.data, signature):
            log.warning("Invalid webhook signature")
            return "Invalid signature", 403

        event = request.headers.get("X-GitHub-Event", "")
        if event != "workflow_job":
            return "Ignored", 200

        data = request.get_json(silent=True) or {}
        action = data.get("action")
        job = data.get("workflow_job", {})
        job_id = job.get("id")
        if not job_id:
            return "Ignored", 200

        if action == "queued":
            if job_id in recent_jobs:
                log.info("Job %s already handled, skipping", job_id)
                return "OK", 200

            remember(job_id)
            labels = job.get("labels", ["self-hosted", "linux"])
            label_str = ",".join(str(label) for label in labels)

            if "self-hosted" not in labels:
                log.info("Job %s is hosted (labels=%s), no runner needed", job_id, label_str)
                return "OK", 200

            worker = thread_factory(
                target=dispatch,
                args=(settings, job_id, label_str),
                daemon=True,
            )
            worker.start()
            return "OK", 200

        if action == "completed":
            log.info("Job %s completed; runner self-terminates (ephemeral)", job_id)
            return "OK", 200

        return "Ignored", 200

    return app
