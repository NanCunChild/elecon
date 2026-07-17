from __future__ import annotations

from typing import Any

import requests


def request_json(session: requests.Session, method: str, url: str, **kwargs) -> Any:
    """执行一个已认证请求，并统一处理 HTTP 和 JSON 错误。"""
    response = session.request(method, url, timeout=15, **kwargs)
    response.raise_for_status()
    return response.json()


def request_text(session: requests.Session, method: str, url: str, **kwargs) -> str:
    """执行一个已认证请求并返回文本。"""
    response = session.request(method, url, timeout=15, **kwargs)
    response.raise_for_status()
    response.encoding = response.apparent_encoding or response.encoding
    return response.text
