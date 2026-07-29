"""
E-Hall 会话管理 — 登录 + useApp (打开具体业务应用)

转化自: traintime_pda/lib/repository/xidian_ids/ehall_session.dart

依赖: ids/login.py
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ids.login import IDSSession

EHALL_LOGIN_TARGET = (
    "https://ehall.xidian.edu.cn/login?"
    "service=https://ehall.xidian.edu.cn/new/index.html"
)

EHALL_REFERER_HEADERS = {
    "Referer": "http://ehall.xidian.edu.cn/new/index_xd.html",
    "Host": "ehall.xidian.edu.cn",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Accept-Encoding": "identity",
    "Connection": "Keep-Alive",
    "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
}


class EhallSession:
    """E-Hall 会话: 基于 IDS 登录, 提供 useApp 进入具体应用"""

    def __init__(self, username: str, password: str):
        self.username = username
        self.password = password
        self.ids = IDSSession()
        self._logged_in = False

    @property
    def session(self):
        return self.ids.session

    def is_logged_in(self) -> bool:
        resp = self.session.get(
            "https://ehall.xidian.edu.cn/jsonp/getAppUsageMonitor.json",
            params={"type": "uv"},
            headers=EHALL_REFERER_HEADERS,
        )
        return resp.json().get("hasLogin", False)

    def ensure_login(self) -> None:
        """确保已登录 E-Hall, 未登录则执行完整登录流程"""
        if self._logged_in and self.is_logged_in():
            return

        location = self.ids.check_and_login(
            target=EHALL_LOGIN_TARGET,
            username=self.username,
            password=self.password,
        )
        self._follow_ehall_redirects(location)
        self._logged_in = True

    def _follow_ehall_redirects(self, url: str) -> None:
        """跟随 E-Hall 登录后的重定向链"""
        while True:
            resp = self.session.get(url, headers=EHALL_REFERER_HEADERS, allow_redirects=False)
            if resp.status_code in (301, 302) and "Location" in resp.headers:
                url = resp.headers["Location"]
            else:
                break

    def use_app(self, app_id: str) -> str:
        """
        打开一个 E-Hall 应用, 返回应用入口 URL

        Args:
            app_id: E-Hall 应用 ID (如 '4768574631264620' 为成绩查询)

        Returns:
            应用入口 URL (已去除 jsessionid)
        """
        self.ensure_login()

        resp = self.session.get(
            f"https://ehall.xidian.edu.cn/appShow?appId={app_id}",
            headers=EHALL_REFERER_HEADERS,
            allow_redirects=False,
        )
        if resp.status_code not in (301, 302):
            raise EhallAppException(f"useApp 失败, 状态码: {resp.status_code}")

        location = resp.headers["Location"]
        # 与 ADR-027 Broker 语义一致：仅剥路径矩阵参数，保留 query/fragment。
        location = re.sub(r";jsessionid=[^/?#;]*", "", location, flags=re.IGNORECASE)

        # 访问应用入口以初始化 session
        self.session.get(location, headers=EHALL_REFERER_HEADERS)
        return location


class EhallAppException(Exception):
    pass


if __name__ == "__main__":
    import getpass

    print("=== XIDIAN E-Hall Session Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    ehall = EhallSession(user, pwd)
    ehall.ensure_login()
    print("[OK] E-Hall 登录成功")
    print(f"[OK] isLoggedIn: {ehall.is_logged_in()}")
