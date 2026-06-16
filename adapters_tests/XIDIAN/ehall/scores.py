"""
成绩查询 — E-Hall 本科成绩 + 研究生平台成绩

转化自: traintime_pda/lib/repository/xidian_ids/score_session.dart

依赖: ehall/session.py
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ehall.session import EhallSession

SCORE_APP_ID = "4768574631264620"


def get_scores_ehall(ehall: EhallSession) -> list[dict]:
    """
    本科生成绩查询 (E-Hall)

    Returns:
        [{name, score, semester, credit, class_status, class_type, score_status, level, passed, class_id}, ...]
    """
    ehall.use_app(SCORE_APP_ID)

    query_setting = json.dumps({
        "name": "SFYX",
        "value": "1",
        "linkOpt": "and",
        "builder": "m_value_equal",
    })

    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/cjcx/modules/cjcx/xscjcx.do",
        data={
            "*json": 1,
            "querySetting": query_setting,
            "*order": "+XNXQDM,KCH,KXH",
            "pageSize": 1000,
            "pageNumber": 1,
        },
    )
    data = resp.json()

    result_data = data["datas"]["xscjcx"]
    if result_data["extParams"]["code"] != 1:
        raise ScoreQueryException(result_data["extParams"].get("msg", "查询失败"))

    scores = []
    for row in result_data["rows"]:
        class_status = row.get("XGXKLBDM_DISPLAY", "")
        if not class_status:
            class_status = row.get("KCXZDM_DISPLAY", "")
        else:
            class_status = f"选修 {class_status}"

        scores.append({
            "name": row.get("XSKCM", ""),
            "score": row.get("ZCJ"),
            "semester": row.get("XNXQDM", ""),
            "credit": row.get("XF"),
            "class_status": class_status,
            "class_type": row.get("KCLBDM_DISPLAY", ""),
            "score_status": row.get("CXCKDM_DISPLAY", ""),
            "score_type_code": row.get("DJCJLXDM"),
            "level": row.get("DJCJMC"),
            "passed": row.get("SFJG"),
            "class_id": row.get("JXBID"),
        })
    return scores


def get_score_detail(ehall: EhallSession, class_id: str, semester: str, student_id: str) -> list[dict]:
    """
    成绩组成详情查询

    Args:
        class_id: JXBID (教学班编号)
        semester: XNXQDM (学年学期代码)
        student_id: 学号

    Returns:
        [{content, ratio, score}, ...]
    """
    if not class_id:
        return [{"content": "教学班编号", "ratio": "未知", "score": "无法查询"}]

    resp = ehall.session.post(
        "https://ehall.xidian.edu.cn/jwapp/sys/cjcx/modules/cjcx/cxkckgcxlrcj.do",
        data={
            "JXBID": class_id,
            "XH": student_id,
            "XNXQDM": semester,
            "CKLY": 1,
        },
    )
    data = resp.json()

    rows = data.get("datas", {}).get("cxkckgcxlrcj", {}).get("rows", [])
    if not rows or not rows[0].get("GCXKHLRCJGS"):
        return []

    formula_str = rows[0]["GCXKHLRCJGS"]
    detail_str = rows[0].get("KCGCXKHLRCJ", "")

    import re
    formula_parts = re.split(r" \+ |\*| = ", formula_str)
    detail_map = {}
    if detail_str:
        for item in detail_str.split(","):
            parts = item.split(":")
            if len(parts) == 2:
                detail_map[parts[0]] = parts[1]

    details = []
    i = 0
    while i < len(formula_parts):
        if formula_parts[i] == "总评成绩":
            i += 1
            continue
        if i + 1 < len(formula_parts):
            content = formula_parts[i]
            try:
                ratio = f"{float(formula_parts[i + 1]) * 100}%"
            except ValueError:
                ratio = formula_parts[i + 1]
            score = detail_map.get(content, "未登记")
            details.append({"content": content, "ratio": ratio, "score": score})
            i += 2
        else:
            i += 1
    return details


def get_scores_yjspt(ehall: EhallSession) -> list[dict]:
    """
    研究生成绩查询 (研究生平台)

    Returns:
        同 get_scores_ehall 格式
    """
    target = "https://yjspt.xidian.edu.cn/gsapp/sys/wdcjapp/*default/index.do"
    location = ehall.ids.check_and_login(target, ehall.username, ehall.password)

    while True:
        resp = ehall.session.get(location, allow_redirects=False)
        if resp.status_code in (301, 302) and "Location" in resp.headers:
            location = resp.headers["Location"]
        else:
            break

    resp = ehall.session.post(
        "https://yjspt.xidian.edu.cn/gsapp/sys/wdcjapp/modules/wdcj/xscjcx.do",
        data={"querySetting": "[]", "pageSize": 1000, "pageNumber": 1},
    )
    data = resp.json()

    result_data = data["datas"]["xscjcx"]
    if result_data["extParams"]["code"] != 1:
        raise ScoreQueryException(result_data["extParams"].get("msg", "查询失败"))

    scores = []
    for row in result_data["rows"]:
        scores.append({
            "name": row.get("KCMC", ""),
            "score": row.get("DYBFZCJ"),
            "semester": row.get("XNXQDM_DISPLAY", ""),
            "credit": row.get("XF"),
            "class_status": row.get("KCLBMC", ""),
            "class_type": row.get("KCLBMC", ""),
            "score_status": row.get("KSXZDM_DISPLAY", ""),
            "score_type_code": row.get("CJFZDM"),
            "level": row.get("CJXSZ") if row.get("CJFZDM") != "0" else None,
            "passed": row.get("SFJG"),
            "class_id": row.get("KCDM"),
        })
    return scores


class ScoreQueryException(Exception):
    pass


if __name__ == "__main__":
    import getpass

    print("=== XIDIAN Score Query Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    ehall = EhallSession(user, pwd)
    scores = get_scores_ehall(ehall)
    print(f"\n[OK] 获取到 {len(scores)} 门成绩:")
    for s in scores[:5]:
        print(f"  {s['name']} | {s['score']} | {s['credit']}学分 | {s['semester']}")
    if len(scores) > 5:
        print(f"  ... 共 {len(scores)} 条")
