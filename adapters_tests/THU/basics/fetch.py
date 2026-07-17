from __future__ import annotations

import re

from ..common import request_json, request_text


WEBVPN_INFO = (
    "https://webvpn.tsinghua.edu.cn/https/"
    "77726476706e69737468656265737421f9f9479369247b59700f81b9991b2631506205de"
)
WEBVPN_CJ = (
    "https://webvpn.tsinghua.edu.cn/http/"
    "77726476706e69737468656265737421eaff4b8b69336153301c9aa596522b20"
    "e6e559a9b290"
)


def user_info(session) -> str:
    return request_text(session, "GET", f"{WEBVPN_INFO}/b/info/gxfw_fg/common/grjbxx")


def parse_user_info(html: str) -> dict[str, str]:
    """提取源项目使用的 name 和校内邮箱前缀，并丢弃未匹配字段。"""
    name = re.search(r"'name':'(.+?)'", html)
    email = re.search(r"'addr':'(.+?)@mails\.tsinghua\.edu\.cn'", html)
    return {"full_name": name.group(1) if name else "",
            "email_name": email.group(1) if email else ""}


def calendar(session) -> str:
    return request_text(session, "GET", f"{WEBVPN_INFO}/b/info/gxfw_fg/common/xl")


def calendar_years(session) -> list[dict]:
    return request_json(session, "GET", "https://app.cs.tsinghua.edu.cn/Api/SchoolCalendarYear")


def scores(session, graduate: bool = False, improvement: bool = False,
           flag: int = 1) -> str:
    """获取成绩原始 HTML；parse_scores 再负责列号和 GPA 转换。"""
    mode = "yjs_cjdcx" if graduate else "bks_cjdcx"
    if improvement:
        mode = "yjs_yxkccj" if graduate else "bks_yxkccj"
    url = f"{WEBVPN_CJ}/cj.cjCjbAll.do?m={mode}"
    if not improvement:
        url += "&cjdlx=zw"
        if not graduate:
            url += f"&flag=di{flag}"
    return request_text(session, "GET", url)


OLD_GPA = {"A-": 3.7, "B+": 3.3, "B": 3.0, "B-": 2.7,
           "C+": 2.3, "C": 2.0, "C-": 1.7, "D+": 1.3, "D": 1.0}


def parse_scores(html: str, graduate: bool = False, new_gpa: bool = True) -> list[dict]:
    """按源项目成绩表列号读取课程，并解释为统一字段。"""
    rows = re.findall(r"<tr[^>]*>(.*?)</tr>", html, flags=re.I | re.S)
    result = []
    grade_index = 9 if graduate else 7
    point_index = 11 if graduate else 9
    semester_index = 13 if graduate else 11
    for row in rows[1:]:
        cells = [re.sub(r"<[^>]+>", "", cell).strip()
                 for cell in re.findall(r"<td[^>]*>(.*?)</td>", row, flags=re.I | re.S)]
        if len(cells) <= semester_index:
            continue
        grade = cells[grade_index]
        try:
            point = float(cells[point_index])
        except ValueError:
            point = OLD_GPA.get(grade, 0.0) if not new_gpa else None
        try:
            credit = float(cells[5])
        except ValueError:
            continue
        result.append({"name": cells[3], "credit": credit, "grade": grade,
                       "point": point, "semester": cells[semester_index]})
    return result


def classroom_list(session) -> str:
    return request_text(session, "GET", f"{WEBVPN_CJ}/portal3rd.do?url=/portal3rd.do&m=jasJy_Xs_Js_index")


def classroom_state(session, classroom: str, week_number: int) -> str:
    return request_text(session, "GET", f"{WEBVPN_CJ}/pk.classroomctrl.do",
                        params={"m": "qyClassroomState", "classroom": classroom,
                                "weeknumber": week_number})
