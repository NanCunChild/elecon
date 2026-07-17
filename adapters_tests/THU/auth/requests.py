from __future__ import annotations

from ..common import request_text


ID_HOST = "https://id.tsinghua.edu.cn"
WEBVPN = "https://webvpn.tsinghua.edu.cn"


def open_id_login(session, service: str | None = None) -> str:
    """打开统一认证登录页；service 用于登录后回跳业务系统。"""
    params = {"service": service} if service else None
    return request_text(session, "GET", f"{ID_HOST}/f/login", params=params)


def submit_id_login(session, form: dict[str, str]) -> str:
    """提交认证表单；form 应来自登录页，避免丢失动态隐藏字段。"""
    return request_text(session, "POST", f"{ID_HOST}/security_check", data=form)


def open_webvpn_login(session, oauth: bool = False) -> str:
    path = "/login?oauth_login=true" if oauth else "/login"
    return request_text(session, "GET", WEBVPN + path)


def get_webvpn_cookie(session) -> str:
    """获取 info.tsinghua.edu.cn 入口的 WebVPN cookie 页面。"""
    return request_text(
        session, "GET", f"{WEBVPN}/wengine-vpn/cookie",
        params={"method": "get", "host": "info.tsinghua.edu.cn",
                "scheme": "https", "path": "/f/info/gxfw_fg/common/index"},
    )


def logout(session) -> str:
    return request_text(session, "GET", f"{WEBVPN}/logout")
