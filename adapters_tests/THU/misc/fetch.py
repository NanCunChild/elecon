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
APP = "https://app.cs.tsinghua.edu.cn"
GITLAB = "https://git.tsinghua.edu.cn"


def news_list(session, source: str = "") -> str:
    """获取门户新闻 HTML；source 对应源项目的 `lydw` 来源字段。"""
    return request_text(session, "GET", f"{INFO}/b/info/xxfb_fg/xnzx/template/more",
                        params={"oType": "xs", "lydw": source})


def news_search(session, payload: dict) -> dict:
    # 搜索接口字段由网页分页控件产生，保留原 JSON 结构，不擅自改名。
    return request_json(session, "POST", f"{INFO}/b/xnzx/search/info/xxfb_fg/teacher/getMobilePageList",
                        json=payload)


def news_detail(session, payload: dict) -> dict:
    return request_json(session, "POST", f"{INFO}/b/info/xxfb_fg/xnzx/template/detail",
                        json=payload)


def add_favorite(session, item_id: str) -> str:
    return request_text(session, "GET", f"{INFO}/b/info/gxfw_fg/common/addFavorite/XXFB/{item_id}")


def remove_favorite(session, item_id: str) -> str:
    return request_text(session, "GET", f"{INFO}/b/info/gxfw_fg/common/delFavorite/XXFB/{item_id}")


def favorite_list(session, payload: dict) -> dict:
    return request_json(session, "POST", f"{INFO}/b/info/gxfw_fg/common/queryFavoriteXxfbPageList",
                        json=payload)


def invoice_list(session, payload: dict) -> dict:
    url = (
        "https://webvpn.tsinghua.edu.cn/https/"
        "77726476706e69737468656265737421f4ed519669247b59700f81b9991b2631aee63c51/invoiceSys/getList.do"
    )
    return request_json(session, "POST", url, data=payload)


def invoice_pdf(session, uuid: str) -> bytes:
    url = (
        "https://webvpn.tsinghua.edu.cn/https/"
        "77726476706e69737468656265737421f4ed519669247b59700f81b9991b2631aee63c51/invoice/showInvPdf.do"
    )
    response = session.get(url, params={"uuid": uuid}, timeout=20)
    response.raise_for_status()
    return response.content


def program_completion(session) -> str:
    url = (
        "https://webvpn.tsinghua.edu.cn/http/"
        "77726476706e69737468656265737421eaff4b8b69336153301c9aa596522b20e6e559a9b290"
        "/jhBks.by_fascjgmxb_gr.do"
    )
    return request_text(session, "GET", url,
                        params={"m": "queryFaScjgmx_gr", "xsViewFlag": "pyfa",
                                "pathContent": "培养方案完成情况"})


def program_list(session) -> str:
    return request_text(session, "GET", f"{CJ}/jhBks.vjhBksPyfabBs.do",
                        params={"m": "grPyfabks", "theRole": "", "theModule": "pyfa",
                                "pathContent": "个人培养方案"})


def gitlab_sign_in(session) -> str:
    return request_text(session, "GET", f"{GITLAB}/users/sign_in")


def gitlab_thuid_auth(session, payload: dict) -> str:
    return request_text(session, "POST", f"{GITLAB}/users/auth/thuid", data=payload)


def reserves_search(session, payload: dict) -> str:
    url = (
        "https://webvpn.tsinghua.edu.cn/http/"
        "77726476706e69737468656265737421e2f2529935266d43300480aed641303c455d43259619a3eaf6eebb99"
        "/Search/ResBooks"
    )
    return request_text(session, "POST", url, data=payload)


def reserves_detail(session, payload: dict) -> str:
    url = (
        "https://webvpn.tsinghua.edu.cn/http/"
        "77726476706e69737468656265737421e2f2529935266d43300480aed641303c455d43259619a3eaf6eebb99"
        "/Search/BookDetail"
    )
    return request_text(session, "POST", url, data=payload)
