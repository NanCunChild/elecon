from __future__ import annotations

import base64
from typing import Any

import requests

from ..common import request_json


BASE_URL = "https://org.xjtu.edu.cn/openplatform/g/admin"


def captcha_required(session: requests.Session, username: str) -> bool:
    data = request_json(
        session, "POST", f"{BASE_URL}/getIsShowJcaptchaCode",
        headers={"Content-Type": "application/json;charset=UTF-8"},
        json={"userName": username},
    )
    if data.get("code") != 0:
        raise RuntimeError(data.get("message", "查询验证码状态失败"))
    return bool(data.get("data"))


def get_captcha(session: requests.Session) -> bytes:
    data = request_json(
        session, "POST", f"{BASE_URL}/getJcaptchaCode",
        headers={"Content-Type": "application/json;charset=UTF-8"},
    )
    if data.get("code") != 0:
        raise RuntimeError(data.get("message", "获取验证码失败"))
    return base64.b64decode(data["data"])


def login(session: requests.Session, username: str, encrypted_password: str,
          captcha: str = "") -> dict[str, Any]:
    """提交登录请求；密码应由可信登录组件在调用前完成加密。"""
    data = request_json(
        session, "POST", f"{BASE_URL}/login",
        headers={"Content-Type": "application/json;charset=utf-8"},
        json={"loginType": 1, "username": username,
              "pwd": encrypted_password, "jcaptchaCode": captcha},
    )
    if data.get("code") != 0:
        raise RuntimeError(data.get("message", "登录失败"))
    return data["data"]


def get_identity(session: requests.Session, member_id: str) -> dict[str, Any]:
    data = request_json(
        session, "POST", f"{BASE_URL}/getUserIdentity",
        headers={"Content-Type": "application/x-www-form-urlencoded;charset=utf-8"},
        data={"memberId": member_id},
    )
    if data.get("code") != 0:
        raise RuntimeError(data.get("message", "获取用户身份失败"))
    return data["data"][0]
