from __future__ import annotations

from ..common import request_json, request_text


MY_FUDAN = "https://my.fudan.edu.cn"


def dining_page(session) -> str:
    return request_text(session, "GET", f"{MY_FUDAN}/simple_list/stqk")


def exam_scores(session, start: int = 0, length: int = 100) -> dict:
    return request_json(session, "POST", f"{MY_FUDAN}/data_tables/bks_xx_cj.json",
                        data={"start": start, "length": length})


def card_info(session) -> dict:
    return request_json(session, "POST", f"{MY_FUDAN}/data_tables/ykt_xx.json")


def electricity_history(session, offset: int = 0, size: int = 20) -> dict:
    return request_json(
        session, "POST", f"{MY_FUDAN}/data_tables/ykt_xszsqyydqk.json",
        data={"draw": 2, "start": offset, "length": size},
    )
