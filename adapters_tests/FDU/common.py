from __future__ import annotations

from typing import Any

import requests


def request_json(session: requests.Session, method: str, url: str, **kwargs) -> Any:
    response = session.request(method, url, timeout=15, **kwargs)
    response.raise_for_status()
    return response.json()


def request_text(session: requests.Session, method: str, url: str, **kwargs) -> str:
    response = session.request(method, url, timeout=15, **kwargs)
    response.raise_for_status()
    response.encoding = response.apparent_encoding or response.encoding
    return response.text
