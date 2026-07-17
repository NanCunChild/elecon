from __future__ import annotations

from ..common import request_json, request_text


ID_HOST = "https://id.fudan.edu.cn"
UIS_HOST = "https://uis.fudan.edu.cn"


def start_service_login(session, service: str):
    """访问业务入口，返回认证系统重定向页面或业务响应。"""
    response = session.get(service, allow_redirects=True, timeout=15)
    response.raise_for_status()
    return response


def get_public_key(session) -> dict:
    return request_json(session, "POST", f"{ID_HOST}/idp/authn/getJsPublicKey")


def query_auth_methods(session, lck: str, entity_id: str) -> dict:
    return request_json(session, "POST", f"{ID_HOST}/idp/authn/queryAuthMethods",
                        json={"lck": lck, "entityId": entity_id})


def authenticate(session, lck: str, entity_id: str, chain_code: str,
                 username: str, encrypted_password: str, verify_code: str = "") -> dict:
    """提交认证参数；密码必须由可信登录组件按 RSA 规则预加密。"""
    return request_json(
        session, "POST", f"{ID_HOST}/idp/authn/authExecute",
        json={"authModuleCode": "userAndPwd", "authChainCode": chain_code,
              "entityId": entity_id, "requestType": "chain_type", "lck": lck,
              "authPara": {"loginName": username, "password": encrypted_password,
                            "verifyCode": verify_code}},
    )


def submit_login_token(session, login_token: str) -> str:
    response = session.post(
        f"{ID_HOST}/idp/authCenter/authnEngine",
        data={"loginToken": login_token},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=15,
    )
    response.raise_for_status()
    return response.text


def uis_login_page(session, service: str) -> str:
    return request_text(session, f"GET", f"{UIS_HOST}/authserver/login",
                        params={"service": service})
