from __future__ import annotations

import hashlib
import hmac

from devoplats.webhook.security import verify_signature


def signature(secret: str, payload: bytes) -> str:
    digest = hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


def test_accepts_valid_signature() -> None:
    assert verify_signature("s3cret", b'{"ok":true}', signature("s3cret", b'{"ok":true}'))


def test_rejects_wrong_secret() -> None:
    assert not verify_signature("s3cret", b"{}", signature("other", b"{}"))


def test_rejects_missing_header() -> None:
    assert not verify_signature("s3cret", b"{}", "")


def test_rejects_other_algorithm() -> None:
    digest = hmac.new(b"s3cret", b"{}", hashlib.sha1).hexdigest()
    assert not verify_signature("s3cret", b"{}", f"sha1={digest}")


def test_rejects_malformed_header() -> None:
    assert not verify_signature("s3cret", b"{}", "not-a-signature")


def test_rejects_empty_secret() -> None:
    assert not verify_signature("", b"{}", signature("", b"{}"))
