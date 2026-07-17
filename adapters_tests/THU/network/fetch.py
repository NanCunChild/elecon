from __future__ import annotations

from ..common import request_json, request_text


BASE = (
    "https://webvpn.tsinghua.edu.cn/https/"
    "77726476706e69737468656265737421e5e4448e223726446d0187ab9040227b54b6c80fcd73"
)


def captcha(session) -> bytes:
    response = session.get(f"{BASE}/site/captcha", timeout=20)
    response.raise_for_status()
    return response.content


def login(session, form: dict[str, str]) -> str:
    # 验证码、用户名等字段由调用方提供，避免在脚本中形成凭证存储。
    return request_text(session, "POST", f"{BASE}/login", data=form)


def validate_user(session) -> dict:
    return request_json(session, "GET", f"{BASE}/site/validate-user")


def home(session) -> str:
    return request_text(session, "GET", f"{BASE}/home")


def delete_device(session, device_id: str, mac: str) -> str:
    # id 和 user_mac 都是源页面返回的设备字段，不在这里重新推导。
    return request_text(session, "GET", f"{BASE}/home/delete",
                        params={"id": device_id, "user_mac": mac})


def user_info(session) -> dict:
    return request_json(session, "GET", f"{BASE}/users")
