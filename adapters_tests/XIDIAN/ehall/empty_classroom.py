"""
空教室查询 — E-Hall 教学楼列表 + 按日期查询教室占用

转化自: traintime_pda/lib/repository/xidian_ids/empty_classroom_session.dart

依赖: ehall/session.py
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ehall.session import EhallSession

EMPTY_CLASSROOM_APP_ID = "4768402106681759"
BASE_URL = "https://ehall.xidian.edu.cn/jwapp/sys/kxjas/modules/kxjas"


def get_building_list(ehall: EhallSession) -> list[dict]:
    """
    获取教学楼列表

    Returns:
        [{code, name}, ...]
    """
    ehall.use_app(EMPTY_CLASSROOM_APP_ID)

    resp = ehall.session.post(
        f"{BASE_URL}/jxlcx.do",
        data={"*order": "+XXXQDM,+PX,+JXLDM"},
    )
    data = resp.json()
    rows = data["datas"]["jxlcx"]["rows"]
    return [{"code": r["JXLDM"], "name": r["JXLJC"]} for r in rows]


def get_date_info(ehall: EhallSession, date: str, semester_range: str, semester_part: str) -> tuple:
    """
    将日期转换为周次+星期几

    Args:
        date: yyyy-MM-dd
        semester_range: 如 '2024-2025'
        semester_part: '1' 或 '2'

    Returns:
        (week_count, weekday)
    """
    resp = ehall.session.post(
        f"{BASE_URL}/rqzhzcjc.do",
        data={"RQ": date, "XN": semester_range, "XQ": semester_part},
    )
    data = resp.json()["datas"]["rqzhzcjc"]
    return data["ZC"], data["XQJ"]


def search_classrooms(
    ehall: EhallSession,
    building_code: str,
    date: str,
    semester_range: str,
    semester_part: str,
) -> list[dict]:
    """
    查询指定教学楼在指定日期的教室占用情况

    Args:
        building_code: 教学楼代码 (从 get_building_list 获取)
        date: yyyy-MM-dd
        semester_range: 如 '2024-2025'
        semester_part: '1' 或 '2'

    Returns:
        [{name, sections: [bool * 11]}, ...]
        sections[i] = True 表示第 i+1 节课被占用
    """
    week_count, weekday = get_date_info(ehall, date, semester_range, semester_part)
    semester_code = f"{semester_range}-{semester_part}"

    query_setting = json.dumps([
        {"name": "JXLDM", "caption": "教学楼代码", "builder": "equal", "linkOpt": "AND", "value": building_code},
        {"name": "XNXQDM", "value": semester_code, "linkOpt": "AND", "builder": "equal"},
        {"name": "ZC", "value": week_count, "linkOpt": "AND", "builder": "equal"},
        {"name": "ZC", "value": weekday, "linkOpt": "AND", "builder": "equal"},
    ])

    resp = ehall.session.post(
        f"{BASE_URL}/cxjsqk.do",
        data={
            "XNXQDM": semester_code,
            "ZC": week_count,
            "XQ": weekday,
            "querySetting": query_setting,
            "*order": "+LC,+JASMC",
            "pageSize": 999,
            "pageNumber": 1,
        },
    )
    data = resp.json()
    rows = data["datas"]["cxjsqk"]["rows"]

    classrooms = []
    for row in rows:
        name = row.get("JASMC", "")
        # 每节课是否被占用: JC1~JC11, 值含 "1_" 表示被占用
        sections = [
            "1_" in str(row.get(f"JC{i}", ""))
            for i in range(1, 12)
        ]
        classrooms.append({"name": name, "sections": sections})
    return classrooms


if __name__ == "__main__":
    import getpass
    from datetime import date

    print("=== XIDIAN Empty Classroom Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    ehall = EhallSession(user, pwd)
    buildings = get_building_list(ehall)
    print(f"\n[OK] 教学楼列表 ({len(buildings)} 栋):")
    for b in buildings:
        print(f"  {b['code']} | {b['name']}")

    if buildings:
        today = date.today().strftime("%Y-%m-%d")
        print(f"\n查询 {buildings[0]['name']} 在 {today} 的教室情况...")
        rooms = search_classrooms(
            ehall,
            building_code=buildings[0]["code"],
            date=today,
            semester_range="2024-2025",
            semester_part="2",
        )
        print(f"[OK] 共 {len(rooms)} 间教室:")
        for r in rooms[:10]:
            free = sum(1 for s in r["sections"] if not s)
            print(f"  {r['name']} | 空闲 {free}/11 节")
