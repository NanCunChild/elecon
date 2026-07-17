from __future__ import annotations

from ..common import request_json, request_text


CARD = "https://card.tsinghua.edu.cn"
APP = "https://app.cs.tsinghua.edu.cn"


def app_card_version(session) -> dict:
    return request_json(session, "GET", f"{APP}/api/CardIVersion")


def user_from_token(session, token: str) -> dict:
    """token 仅作为调用时的输入，不在本模块保存；响应转换由上层决定。"""
    return request_json(session, "GET", f"{CARD}/login/getUserInfoFromToken",
                        params={"token": token})


def card_user_info(session) -> dict:
    return request_json(session, "GET", f"{CARD}/business/getCardUserinfo")


def card_photo(session, idserial: str) -> bytes:
    response = session.get(f"{CARD}/myaccount/showDbImage", params={"idserial": idserial}, timeout=20)
    response.raise_for_status()
    return response.content


def transactions(session, form: dict[str, str]) -> str:
    """查询消费记录；form 中的分页/日期字段保持校园卡页面原命名。"""
    return request_text(session, "POST", f"{CARD}/business/querySelfTradeList", data=form)


def recharge_from_bank(session, form: dict[str, str]) -> str:
    return request_text(session, "POST", f"{CARD}/business/moblieRecharge", data=form)


def report_loss(session, form: dict[str, str]) -> str:
    return request_text(session, "POST", f"{CARD}/business/cardReportLoss", data=form)
