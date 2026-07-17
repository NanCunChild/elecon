from __future__ import annotations

from ..common import request_json, request_text


def dorm_electricity(session) -> dict:
    return request_json(session, "GET", "https://zlapp.fudan.edu.cn/fudanelec/wap/default/info")


def bus_list(session, holiday: bool = False) -> dict:
    return request_json(
        session, "POST", "https://zlapp.fudan.edu.cn/fudanbus/wap/default/lists",
        data={"holiday": "1" if holiday else "0"},
    )


def library_crowdedness(session) -> dict:
    return request_json(session, "POST", "https://mlibrary.fudan.edu.cn/api/common/h5/getspaceseat")


def qr_code_page(session) -> str:
    return request_text(session, "GET", "https://ecard.fudan.edu.cn/epay/wxpage/fudan/zfm/qrcode")
