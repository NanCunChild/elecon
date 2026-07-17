from __future__ import annotations

from datetime import datetime


BASE_URLS = {
    "undergraduate": "https://bkkq.xjtu.edu.cn",
    "graduate": "https://yjskq.xjtu.edu.cn",
}


def _post(session, endpoint: str, *, postgraduate: bool = False, **kwargs):
    domain = "graduate" if postgraduate else "undergraduate"
    response = session.post(BASE_URLS[domain] + endpoint, timeout=15, **kwargs)
    response.raise_for_status()
    data = response.json()
    if not data.get("success"):
        raise RuntimeError(data.get("msg", "考勤接口请求失败"))
    return data.get("data")


def get_student_info(session, *, postgraduate: bool = False):
    return _post(session, "/attendance-student/global/getStuInfo", postgraduate=postgraduate)


def get_near_term(session, *, postgraduate: bool = False):
    return _post(session, "/attendance-student/global/getNearTerm", postgraduate=postgraduate)


def get_by_time(session, start_date: str, end_date: str | None = None, *, postgraduate: bool = False):
    end_date = end_date or datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return _post(session, "/attendance-student/kqtj/getKqtjByTime", postgraduate=postgraduate,
                 json={"startDate": start_date, "endDate": end_date})


def get_number_by_time(session, start_date: str, end_date: str | None = None, *, postgraduate: bool = False):
    end_date = end_date or datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return _post(session, "/attendance-student/kqtj/getKqtjNumByTime", postgraduate=postgraduate,
                 json={"startDate": start_date, "endDate": end_date})


def get_terms(session, *, postgraduate: bool = False):
    return _post(session, "/attendance-student/global/getBeforeTodayTerm", postgraduate=postgraduate)


def get_week_schedule(session, week: int, term_no: int, *, postgraduate: bool = False):
    return _post(session, "/attendance-student/rankClass/getWeekSchedule2", postgraduate=postgraduate,
                 json={"week": week, "termNo": term_no})


def get_detail_page(session, start_date: str, end_date: str, term_no: int,
                    *, postgraduate: bool = False, current: int = 1, page_size: int = 10):
    return _post(session, "/attendance-student/classWater/getClassWaterPage", postgraduate=postgraduate,
                 json={"startDate": start_date, "endDate": end_date, "current": current,
                       "pageSize": page_size, "timeCondition": "", "subjectBean": {"sCode": ""},
                       "classWaterBean": {"status": ""}, "classBean": {"termNo": term_no}})


def get_water_page(session, payload: dict, *, postgraduate: bool = False):
    """查询打卡流水；payload 保持 XJTUToolBox 原接口字段结构。"""
    return _post(session, "/attendance-student/waterList/page", postgraduate=postgraduate,
                 json=payload)
