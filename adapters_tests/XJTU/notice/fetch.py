from __future__ import annotations

from urllib.parse import urljoin

from bs4 import BeautifulSoup

from ..common import request_text


NOTICE_URLS = {
    "dean": "https://dean.xjtu.edu.cn/jxxx/jxtz2.htm",
    "graduate": "https://gs.xjtu.edu.cn/tzgg/pygz.htm",
    "software": "https://se.xjtu.edu.cn/xwgg/tzgg.htm",
}


def get_notice_page(session, source: str = "dean") -> list[dict]:
    html = request_text(session, "GET", NOTICE_URLS[source])
    soup = BeautifulSoup(html, "html.parser")
    result = []
    for link in soup.select("a[href]"):
        title = link.get_text(" ", strip=True)
        if not title:
            continue
        result.append({"title": title, "url": urljoin(NOTICE_URLS[source], link["href"])})
    return result
