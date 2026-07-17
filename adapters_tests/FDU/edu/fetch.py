from __future__ import annotations

from ..common import request_json, request_text


JWGL = "https://fdjwgl.fudan.edu.cn"


def course_table(session, semester_id: str | None = None) -> str:
    url = f"{JWGL}/student/for-std/course-table"
    if semester_id:
        url += f"/semester/{semester_id}/print-data"
    return request_text(session, "GET", url)


def lesson_search(session) -> str:
    return request_text(session, "GET", f"{JWGL}/student/for-all/lesson-search")


def exam_arrange(session, student_id: str) -> str:
    return request_text(session, "GET", f"{JWGL}/student/for-std/exam-arrange/info/{student_id}")


def grade_sheet(session, student_id: str, semester: str) -> dict:
    return request_json(
        session, "GET", f"{JWGL}/student/for-std/grade/sheet/info/{student_id}",
        params={"semester": semester},
    )


def gpa_search_index(session, student_id: str) -> str:
    return request_text(session, "GET", f"{JWGL}/student/for-std/grade/my-gpa/search-index/{student_id}")


def gpa_search(session, student_id: str, grade: str, department: str) -> dict:
    params = {"studentAssoc": student_id, "grade": grade,
              "departmentAssoc": department, "majorAssoc": ""}
    return request_json(session, "GET", f"{JWGL}/student/for-std/grade/my-gpa/search", params=params)
