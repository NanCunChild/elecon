from __future__ import annotations

from ..common import post_form, request_text


CR = (
    "https://webvpn.tsinghua.edu.cn/https/"
    "77726476706e69737468656265737421eaff4b8b3f3b2653770bc7b88b5c2d320506b1aec738590a49ba"
)


def login_home(session) -> str:
    return request_text(session, "GET", f"{CR}/xklogin.do")


def search_undergraduate(session, form: dict[str, str]) -> str:
    return post_form(session, f"{CR}/xkBks.vxkBksJxjhBs.do", form)


def search_postgraduate(session, form: dict[str, str]) -> str:
    return post_form(session, f"{CR}/xkYjs.vxkYjsJxjhBs.do", form)


def main_page(session, graduate: bool = False) -> str:
    path = "xkYjs.vxkYjsXkbBs.do?m=main" if graduate else "xkBks.vxkBksXkbBs.do?m=main"
    return request_text(session, "GET", f"{CR}/{path}")


def tree(session, semester: str, graduate: bool = False) -> str:
    path = "xkYjs.vxkYjsXkbBs.do" if graduate else "xkBks.vxkBksXkbBs.do"
    return request_text(session, "GET", f"{CR}/{path}",
                        params={"m": "showTree", "p_xnxq": semester})


def select_course(session, form: dict[str, str], graduate: bool = False) -> str:
    path = "xkYjs.vxkYjsXkbBs.do" if graduate else "xkBks.vxkBksXkbBs.do"
    return post_form(session, f"{CR}/{path}", form)
