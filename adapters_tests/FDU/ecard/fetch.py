from __future__ import annotations

from datetime import date, timedelta
import re

from ..common import request_text


BASE = "https://ecard.fudan.edu.cn/epay"
CONSUME_HEADERS = {
    "Accept": "text/xml",
    "Content-Type": "application/x-www-form-urlencoded",
    "Origin": "https://ecard.fudan.edu.cn",
    "Referer": f"{BASE}/consume/index",
}


def card_home(session) -> str:
    return request_text(session, "GET", f"{BASE}")


def card_user_page(session) -> str:
    return request_text(session, "GET", f"{BASE}/myepay/index")


def consume_csrf_page(session) -> str:
    return request_text(session, "GET", f"{BASE}/consume/index")


def consume_page(session, page: int = 1, days: int = 30, csrf: str = "") -> str:
    end = date.today()
    start = end - timedelta(days=days)
    payload = {
        "aaxmlrequest": "true", "pageNo": str(page), "tabNo": "1",
        "pager.offset": "10", "tradename": "",
        "starttime": start.isoformat(), "endtime": end.isoformat(),
        "timetype": "1", "_tradedirect": "on", "_csrf": csrf,
    }
    return request_text(session, "POST", f"{BASE}/consume/query",
                        data=payload, headers=CONSUME_HEADERS)


def parse_csrf(html: str) -> str | None:
    match = re.search(
        r'<meta[^>]+name=["\']_csrf["\'][^>]+content=["\']([^"\']+)',
        html,
        re.IGNORECASE,
    )
    return match.group(1) if match else None
