from __future__ import annotations

import json
import re
from datetime import date

from ..common import request_text


BASE = "http://10.64.130.6"
STATUS_RE = re.compile(r'"status"\s*:\s*(\[.*?\])', re.DOTALL)


def room_ids(session, building: str, day: date) -> list[dict]:
    html = request_text(session, "GET", f"{BASE}/daystatus.asp",
                        params={"b": building, "day": day.isoformat()})
    match = STATUS_RE.search(html)
    if not match:
        raise ValueError("空教室接口未返回 status 列表")
    return json.loads(match.group(1))


def room_status(session, building: str, day: date) -> str:
    return request_text(session, "GET", f"{BASE}/",
                        params={"b": building, "c": "", "p": "", "day": day.isoformat()})
