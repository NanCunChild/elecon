"""
课表查询 — E-Hall 本科课表 + 调停补课

转化自: traintime_pda/lib/repository/xidian_ids/classtable_session.dart

依赖: ehall/session.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ehall.session import EhallSession

SCHEDULE_APP_ID = "4770397878132218"


def get_current_semester(ehall: EhallSession) -> str:
    """获取当前学年学期代码 (如 '2024-2025-2')"""
    ehall.use_app(SCHEDULE_APP_ID)

    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do",
    )
    data = resp.json()
    return data["datas"]["dqxnxq"]["rows"][0]["DM"]


def get_semester_start(ehall: EhallSession, semester: str) -> str:
    """获取学期开学日期"""
    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/modules/jshkcb/cxjcs.do",
        data={"XN": semester[:9], "XQ": semester[-1]},
    )
    data = resp.json()
    rows = data["datas"]["cxjcs"]["rows"]
    if rows:
        return rows[0].get("XQKSRQ", "")
    return ""


def get_schedule(ehall: EhallSession, semester: str) -> list[dict]:
    """
    本科生课表查询

    Args:
        semester: 学年学期代码 (如 '2024-2025-2')

    Returns:
        课程列表 [{name, teacher, room, weeks, day, start_section, end_section, ...}, ...]
    """
    ehall.use_app(SCHEDULE_APP_ID)

    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/modules/xskcb/xskcb.do",
        data={"XNXQDM": semester},
    )
    data = resp.json()
    result = data["datas"]["xskcb"]
    if result["extParams"]["code"] != 1:
        raise ScheduleQueryException(result["extParams"].get("msg", "查询失败"))

    courses = []
    for row in result["rows"]:
        courses.append({
            "name": row.get("KCM", ""),
            "teacher": row.get("SKJS", ""),
            "room": row.get("JASMC", ""),
            "weeks": row.get("SKZC", ""),
            "day": row.get("SKXQ"),
            "start_section": row.get("KSJC"),
            "end_section": row.get("JSJC"),
            "credit": row.get("XF"),
            "course_id": row.get("KCH", ""),
            "class_id": row.get("JXBID", ""),
            "semester": semester,
        })
    return courses


def get_class_changes(ehall: EhallSession, semester: str) -> list[dict]:
    """获取调停补课信息"""
    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/modules/xskcb/xsdkkc.do",
        data={"XNXQDM": semester},
    )
    data = resp.json()
    rows = data.get("datas", {}).get("xsdkkc", {}).get("rows", [])
    changes = []
    for row in rows:
        changes.append({
            "name": row.get("KCM", ""),
            "type": row.get("DKBKLX_DISPLAY", ""),
            "original_date": row.get("YSKRQ", ""),
            "new_date": row.get("DKRQ", ""),
            "room": row.get("DKJASMC", ""),
            "sections": row.get("DKJC_DISPLAY", ""),
        })
    return changes


class ScheduleQueryException(Exception):
    pass


if __name__ == "__main__":
    import getpass

    print("=== XIDIAN Schedule Query Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    ehall = EhallSession(user, pwd)
    semester = get_current_semester(ehall)
    print(f"[OK] 当前学期: {semester}")

    start = get_semester_start(ehall, semester)
    print(f"[OK] 开学日期: {start}")

    courses = get_schedule(ehall, semester)
    print(f"\n[OK] 获取到 {len(courses)} 门课程:")
    for c in courses[:5]:
        print(f"  {c['name']} | {c['teacher']} | 周{c['day']} 第{c['start_section']}-{c['end_section']}节 | {c['room']}")
    if len(courses) > 5:
        print(f"  ... 共 {len(courses)} 条")
