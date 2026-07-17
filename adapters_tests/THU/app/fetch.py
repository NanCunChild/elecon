from __future__ import annotations

from ..common import request_json, request_text


APP_API = "https://app.cs.tsinghua.edu.cn"


def announcements(session, version: str = "") -> dict:
    return request_json(session, "GET", f"{APP_API}/api/announce",
                        params={"page": 1, "version": version})


def latest_version(session) -> dict:
    return request_json(session, "GET", f"{APP_API}/api/version")


def qrcode(session) -> dict:
    return request_json(session, "GET", f"{APP_API}/api/qrcode")


def submit_feedback(session, payload: dict) -> dict:
    # payload 中的内容、版本等字段保持客户端原始 JSON 结构。
    return request_json(session, "POST", f"{APP_API}/api/feedback", json=payload)


def privacy(session) -> str:
    return request_text(session, "GET", f"{APP_API}/privacy")
