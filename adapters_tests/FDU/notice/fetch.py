from __future__ import annotations

import html
import re
from urllib.parse import urljoin

from ..common import request_text


def _list_url(base: str, category: str, page: int) -> str:
    suffix = "" if page <= 1 else str(page)
    return f"{base}/{category}/list{suffix}.htm"


def _parse(session, url: str, selector: str, base: str) -> list[dict]:
    page = request_text(session, "GET", url)
    result = []
    for match in re.finditer(r'<a[^>]+href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', page, re.I | re.S):
        title = re.sub(r"<[^>]+>", "", match.group(2))
        title = html.unescape(re.sub(r"\s+", " ", title)).strip()
        if not title:
            continue
        result.append({
            "title": title,
            "url": urljoin(base, match.group(1)),
            "date": "",
        })
    return result


def undergraduate(session, category: str = "9397", page: int = 1) -> list[dict]:
    base = "https://jwc.fudan.edu.cn"
    return _parse(session, _list_url(base, category, page),
                  ".wp_article_list_table > tbody > tr > td > table > tbody", base)


def postgraduate(session, category: str = "tzgg", page: int = 1) -> list[dict]:
    base = "https://gs.fudan.edu.cn"
    return _parse(session, _list_url(base, category, page), ".wp_article_list > li", base)
