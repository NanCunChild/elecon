from __future__ import annotations

from ..common import request_text


SCHEDULE_URL = "https://gmis.xjtu.edu.cn/pyxx/pygl/xskbcx"


def get_schedule_page(session, term_value: str | None = None) -> str:
    """获取当前课表，或按页面中的学期 value 获取指定学期课表。"""
    url = SCHEDULE_URL if term_value is None else f"{SCHEDULE_URL}/index/{term_value}"
    return request_text(session, "GET", url)


def get_term_starts(session) -> dict[str, str]:
    """获取一网通办公开校历中的学期开始日期。"""
    data = session.post(
        "http://one2020.xjtu.edu.cn/EIP/schoolcalendar/terms.htm",
        headers={"Referer": "http://one2020.xjtu.edu.cn/EIP/edu/education/schoolcalendar/showCalendar.htm"},
        timeout=15,
    )
    data.raise_for_status()
    result = {}
    for item in data.json().get("data", []):
        if "第一学期" in item.get("term_num", ""):
            result[f"{item['year_num']}-1"] = item["start_date"]
        elif "第二学期" in item.get("term_num", ""):
            result[f"{item['year_num']}-2"] = item["start_date"]
    return result
