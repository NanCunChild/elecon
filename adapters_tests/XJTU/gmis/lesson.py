from ..common import request_text


def get_lesson_detail(session, lesson_id: str, year: str) -> str:
    url = f"https://gmis.xjtu.edu.cn/pyxx/pygl/kckk/view/new/{lesson_id}/{year}"
    return request_text(session, "GET", url)
