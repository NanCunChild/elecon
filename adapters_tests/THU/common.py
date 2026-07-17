from __future__ import annotations

from typing import Any

import requests


def request_text(session: requests.Session, method: str, url: str, **kwargs) -> str:
    """请求文本页面；不主动改写 WebVPN 返回的编码内容。"""
    response = session.request(method, url, timeout=20, **kwargs)
    response.raise_for_status()
    return response.text


def request_json(session: requests.Session, method: str, url: str, **kwargs) -> Any:
    response = session.request(method, url, timeout=20, **kwargs)
    response.raise_for_status()
    return response.json()


def post_form(session: requests.Session, url: str, data: dict[str, Any], **kwargs) -> str:
    """提交传统表单，并保留调用方传入的隐藏字段和 CSRF 字段。"""
    return request_text(session, "POST", url, data=data, **kwargs)
