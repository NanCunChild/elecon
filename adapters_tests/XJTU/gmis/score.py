from __future__ import annotations

from bs4 import BeautifulSoup

from ..common import request_text


SCORE_URL = "https://gmis.xjtu.edu.cn/pyxx/pygl/xscjcx/index"


def get_scores(session) -> list[dict]:
    """获取研究生教务系统成绩页并转换为统一的课程记录。"""
    html = request_text(session, "GET", SCORE_URL)
    soup = BeautifulSoup(html, "html.parser")
    result = []
    types = ("学位课程", "选修课程", "必修环节")
    for table_index, table in enumerate(soup.select("table#sample-table-1")):
        course_type = types[table_index] if table_index < len(types) else "未知"
        for row in table.select("tr")[1:]:
            cells = row.find_all("td", recursive=False)
            if not cells:
                continue
            texts = [cell.get_text("", strip=True) for cell in cells]
            score_index = 2 if course_type == "必修环节" else 3
            if len(texts) <= score_index or not texts[0] or not texts[score_index]:
                continue
            result.append({
                "name": texts[0],
                "credit": texts[1] if len(texts) > 1 else "",
                "score": texts[score_index],
                "type": course_type,
                "exam_date": texts[score_index + 1] if len(texts) > score_index + 1 else "",
            })
    return result
