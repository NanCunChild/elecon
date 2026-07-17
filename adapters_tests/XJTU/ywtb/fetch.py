from __future__ import annotations

import random

from ..common import request_json


USER_URL = "https://authx-service.xjtu.edu.cn/personal/api/v1/personal/me/user"
WEEK_URL = "https://ywtb.xjtu.edu.cn/portal-api/v1/calendar/share/schedule/getWeekOfTeaching"


def get_user(session):
    data = request_json(session, "GET", USER_URL,
                        headers={"Referer": "https://ywtb.xjtu.edu.cn/main.html"})
    return data["data"]


def get_teaching_weeks(session, dates: list[str]):
    data = request_json(session, "GET", WEEK_URL,
                        params={"today": ",".join(dates), "random_number": random.randint(100, 999)})
    return data["data"]["data"]
