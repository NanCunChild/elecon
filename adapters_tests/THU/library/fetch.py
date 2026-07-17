from __future__ import annotations

from ..common import request_json, request_text


WEBVPN_LIBRARY = (
    "https://webvpn.tsinghua.edu.cn/https/"
    "77726476706e69737468656265737421e3f24088693c6152301c9aa596522b204c02212b859d0a19"
)
BOOKING = (
    "https://webvpn.tsinghua.edu.cn/https/"
    "77726476706e69737468656265737421f3f643d22b396a1e6a1b80a29f5d363409e413829737d1"
)


def library_home(session) -> str:
    return request_text(session, "GET", f"{WEBVPN_LIBRARY}/home/web/f_second")


def areas(session) -> dict:
    return request_json(session, "GET", f"{WEBVPN_LIBRARY}/api.php/areas/1/tree/1")


def area_children(session, area_id: str) -> dict:
    return request_json(session, "GET", f"{WEBVPN_LIBRARY}/api.php/areas/{area_id}")


def seats(session, form: dict[str, str]) -> dict:
    # spaces_old 的筛选字段由页面表单产生，直接透传可避免字段名漂移。
    return request_json(session, "POST", f"{WEBVPN_LIBRARY}/api.php/spaces_old", data=form)


def room_booking_user(session) -> dict:
    return request_json(session, "GET", f"{BOOKING}/ic-web/auth/userInfo")


def room_infos(session, form: dict[str, str]) -> dict:
    return request_json(session, "POST", f"{BOOKING}/ic-web/roomDevice/roomInfos", data=form)


def booking_records(session) -> dict:
    return request_json(session, "GET", f"{BOOKING}/ic-web/reserve/resvInfo",
                        params={"needStatus": 8454, "orderKey": "gmt_create", "orderModel": "desc"})


def cancel_booking(session, form: dict[str, str]) -> dict:
    return request_json(session, "POST", f"{BOOKING}/ic-web/reserve/delete", data=form)
