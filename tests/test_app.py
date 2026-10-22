from __future__ import annotations

import hashlib
import hmac
import json

from flask import Flask

from devoplats.webhook.app import create_app


class ImmediateThread:
    def __init__(self, target=None, args=(), daemon=False, **kwargs):
        self.target = target
        self.args = args
        self.daemon = daemon

    def start(self) -> None:
        self.target(*self.args)


class NullTimer:
    daemon = False

    def __init__(self, *args, **kwargs) -> None:
        pass

    def start(self) -> None:
        pass


def build_app(settings, dispatched):
    return create_app(
        settings,
        dispatch=lambda *args: dispatched.append(args),
        thread_factory=ImmediateThread,
        timer_factory=NullTimer,
    )


def post_webhook(client: Flask.testing.FlaskClient, secret: str, payload: dict, event: str = "workflow_job"):
    body = json.dumps(payload).encode()
    signature = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return client.post(
        "/webhooks/github",
        data=body,
        headers={
            "X-GitHub-Event": event,
            "X-Hub-Signature-256": f"sha256={signature}",
            "Content-Type": "application/json",
        },
    )


def queued_job(job_id: int = 42, labels: list[str] | None = None) -> dict:
    return {
        "action": "queued",
        "workflow_job": {
            "id": job_id,
            "labels": labels if labels is not None else ["self-hosted", "linux"],
        },
    }


def test_healthz(settings_factory) -> None:
    settings = settings_factory(env_text="GITHUB_WEBHOOK_SECRET=secret\n")
    client = build_app(settings, []).test_client()
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_rejects_invalid_signature(settings_factory) -> None:
    settings = settings_factory(env_text="GITHUB_WEBHOOK_SECRET=secret\n")
    client = build_app(settings, []).test_client()
    body = json.dumps(queued_job()).encode()
    response = client.post(
        "/webhooks/github",
        data=body,
        headers={
            "X-GitHub-Event": "workflow_job",
            "X-Hub-Signature-256": "sha256=deadbeef",
            "Content-Type": "application/json",
        },
    )
    assert response.status_code == 403


def test_queued_self_hosted_dispatches_once(settings_factory) -> None:
    settings = settings_factory(env_text="GITHUB_WEBHOOK_SECRET=secret\n")
    dispatched: list = []
    client = build_app(settings, dispatched).test_client()

    payload = queued_job()
    first = post_webhook(client, "secret", payload)
    second = post_webhook(client, "secret", payload)

    assert first.status_code == 200
    assert second.status_code == 200
    assert len(dispatched) == 1
    assert dispatched[0][1] == 42
    assert dispatched[0][2] == "self-hosted,linux"


def test_hosted_job_is_ignored(settings_factory) -> None:
    settings = settings_factory(env_text="GITHUB_WEBHOOK_SECRET=secret\n")
    dispatched: list = []
    client = build_app(settings, dispatched).test_client()
    response = post_webhook(client, "secret", queued_job(labels=["ubuntu-latest"]))
    assert response.status_code == 200
    assert dispatched == []


def test_completed_is_ignored(settings_factory) -> None:
    settings = settings_factory(env_text="GITHUB_WEBHOOK_SECRET=secret\n")
    dispatched: list = []
    client = build_app(settings, dispatched).test_client()
    payload = {
        "action": "completed",
        "workflow_job": {"id": 7, "labels": ["self-hosted"]},
    }
    assert post_webhook(client, "secret", payload).status_code == 200
    assert dispatched == []


def test_non_workflow_event_is_ignored(settings_factory) -> None:
    settings = settings_factory(env_text="GITHUB_WEBHOOK_SECRET=secret\n")
    client = build_app(settings, []).test_client()
    assert post_webhook(client, "secret", {}, event="push").status_code == 200


def test_payload_without_job_id_is_ignored(settings_factory) -> None:
    settings = settings_factory(env_text="GITHUB_WEBHOOK_SECRET=secret\n")
    client = build_app(settings, []).test_client()
    payload = {"action": "queued", "workflow_job": {}}
    assert post_webhook(client, "secret", payload).status_code == 200
