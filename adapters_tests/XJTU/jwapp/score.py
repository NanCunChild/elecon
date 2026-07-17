from __future__ import annotations

from ..common import request_json


BASE_URL = "http://jwapp.xjtu.edu.cn/api/biz/v410/score"


def get_term_scores(session, term: str = "*") -> dict:
    return request_json(session, "POST", f"{BASE_URL}/termScore",
                        json={"termCode": term})


def get_score_detail(session, course_id: str) -> dict:
    return request_json(session, "POST", f"{BASE_URL}/scoreDetail",
                        json={"id": course_id})


def get_score_analysis(session, course_id: str) -> dict:
    return request_json(session, "POST", f"{BASE_URL}/scoreAnalyze",
                        json={"id": course_id})
