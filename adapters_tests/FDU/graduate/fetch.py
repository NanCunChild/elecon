from __future__ import annotations

from ..common import request_json


def timetable(session, timestamp: str | None = None) -> dict:
    url = "http://yjsxktest.fudan.sh.cn/yjsxkapp/sys/xsxkappfudan/xsxkCourse/loadKbxx.do"
    return request_json(session, "GET", url, params={"_": timestamp or ""})


def scores(session) -> dict:
    return request_json(session, "GET",
                        "https://yzsfwapp.fudan.edu.cn/gsapp/sys/wdcjapp/modules/xscjcx/jdjscjcx.do")


def semester_index(session) -> dict:
    return request_json(session, "GET", "https://zlapp.fudan.edu.cn/fudanyjskb/wap/default/get-index")
