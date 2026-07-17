from __future__ import annotations

from datetime import date, timedelta

from ..basics.fetch import WEBVPN_CJ
from ..common import post_form, request_text


def _date_string(value: date) -> str:
    # 源项目使用 dayjs.format("YYYYMMDD")，这里明确补零。
    return value.strftime("%Y%m%d")


def primary_schedule(session, first_day: date, week_count: int,
                     graduate: bool = False) -> list[str]:
    """按每三周一个窗口请求主课表，返回每个窗口的 JSONP 文本。"""
    prefix = "yjs_jxrl_all" if graduate else "bks_jxrl_all"
    result = []
    for start_week in range(0, week_count, 3):
        start = first_day + timedelta(days=start_week * 7)
        end = first_day + timedelta(days=(start_week + 3) * 7 - 1)
        result.append(request_text(
            session, "GET", f"{WEBVPN_CJ}/jxmh_out.do",
            params={"m": prefix, "p_start_date": _date_string(start),
                    "p_end_date": _date_string(end), "jsoncallback": "m"},
        ))
    return result


def secondary_schedule(session) -> str:
    return request_text(session, "GET", f"{WEBVPN_CJ}/portal3rd.do?m=bks_ejkbSearch")


def save_custom_schedule(session, form: dict[str, str], name: str,
                         location: str, begin: date, start_time: str,
                         end_time: str) -> str:
    """提交自定义日历；role/token 等隐藏字段从上一次页面继承。"""
    data = dict(form)
    data.update({"m": "saveGrrl", "grrlID": "", "displayType": "",
                 "zt": name, "dd": location, "p_date": _date_string(begin),
                 "p_start_time": start_time, "p_end_time": end_time})
    return post_form(session, f"{WEBVPN_CJ}/jxmh.do", data)
