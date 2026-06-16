"""
考试安排查询 — E-Hall 本科 + 研究生

转化自: traintime_pda/lib/repository/xidian_ids/exam_session.dart

依赖: ehall/session.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ehall.session import EhallSession

EXAM_APP_ID = "4768687067472349"


def get_exams_ehall(ehall: EhallSession, semester: str) -> list[dict]:
    """
    本科生考试安排查询

    Args:
        semester: 学年学期代码

    Returns:
        [{name, date, time, room, seat, ...}, ...]
    """
    ehall.use_app(EXAM_APP_ID)

    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/studentWdksapApp/modules/wdksap/wdksap.do",
        data={"XNXQDM": semester, "pageSize": 100, "pageNumber": 1},
    )
    data = resp.json()
    result = data["datas"]["wdksap"]
    if result["extParams"]["code"] != 1:
        raise ExamQueryException(result["extParams"].get("msg", "查询失败"))

    exams = []
    for row in result["rows"]:
        exams.append({
            "name": row.get("KCM", ""),
            "date": row.get("KSRQ_DISPLAY", ""),
            "time": row.get("KSSJMS", ""),
            "room": row.get("JASMC", ""),
            "seat": row.get("ZWH", ""),
            "campus": row.get("XXXQMC", ""),
            "building": row.get("JXLMC", ""),
        })
    return exams


def get_pending_exams(ehall: EhallSession, semester: str) -> list[dict]:
    """获取待安排考试的课程"""
    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/studentWdksapApp/modules/wdksap/cxyxkwapkwdkc.do",
        data={"XNXQDM": semester, "pageSize": 100, "pageNumber": 1},
    )
    data = resp.json()
    rows = data.get("datas", {}).get("cxyxkwapkwdkc", {}).get("rows", [])
    return [{"name": row.get("KCM", ""), "credit": row.get("XF")} for row in rows]


class ExamQueryException(Exception):
    pass


if __name__ == "__main__":
    import getpass
    from ehall.session import EhallSession
    from ehall.schedule import get_current_semester

    print("=== XIDIAN Exam Query Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    ehall = EhallSession(user, pwd)
    semester = get_current_semester(ehall)
    exams = get_exams_ehall(ehall, semester)
    print(f"\n[OK] 获取到 {len(exams)} 场考试:")
    for e in exams:
        print(f"  {e['name']} | {e['date']} {e['time']} | {e['room']} 座位{e['seat']}")
