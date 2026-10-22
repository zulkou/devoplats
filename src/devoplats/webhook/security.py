from __future__ import annotations

import hashlib
import hmac


def verify_signature(secret: str, payload: bytes, signature_header: str) -> bool:
    if not secret or not signature_header:
        return False
    algorithm, separator, signature = signature_header.partition("=")
    if separator != "=" or algorithm != "sha256":
        return False
    expected = hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)
