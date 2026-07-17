from __future__ import annotations

from ..common import request_json, request_text


INFO = (
    "https://webvpn.tsinghua.edu.cn/https/"
    "77726476706e69737468656265737421f9f9479369247b59700f81b9991b2631506205de"
)
CJ = (
    "https://webvpn.tsinghua.edu.cn/http/"
    "77726476706e69737468656265737421eaff4b8b69336153301c9aa596522b20"
    "e6e559a9b290"
)


def deadline(session) -> str:
    return request_text(session, "GET", f"{INFO}/b/info/gxfw_fg/common/deadline/list")


def dorm_login(session) -> str:
    return request_text(session, "GET", f"{CJ}/weixin/weixin_user_authenticate.aspx")


def dorm_score(session) -> str:
    return request_text(session, "GET", f"{CJ}/weixin/weixin_health_linechart.aspx",
                        params={"id": 0})


def physical_exam(session) -> dict:
    return request_json(session, "GET", f"{CJ}/tyjx.tyjx_tc_xscjb.do",
                        params={"m": "jsonCj"})


def graduate_income(session, form: dict[str, str]) -> dict:
    url = (
        "https://webvpn.tsinghua.edu.cn/http/"
        "77726476706e69737468656265737421eaed4b9069377a517a1d88b89d1b37269c624d2b1c6925f37faea82b8d"
        "/b/yjsjzxt/v_yjszzjl_yjscwdfmx_cx/pageList"
    )
    return request_json(session, "POST", url, data=form)
