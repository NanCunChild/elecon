"""
一卡通 (校园卡) — 余额查询 + 消费记录

转化自: traintime_pda/lib/repository/xidian_ids/school_card_session.dart

依赖: ids/login.py
注意: 校园卡系统使用 OAuth 跳转获取 openid, 基于 v8scan.xidian.edu.cn
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ids.login import IDSSession

CARD_CAS_TARGET = "https://v8scan.xidian.edu.cn/home/openXDOAuth2Page"


class CardSession:
    """校园卡会话"""

    def __init__(self, username: str, password: str):
        self.username = username
        self.password = password
        self.ids = IDSSession()
        self.openid: str | None = None

    @property
    def session(self):
        return self.ids.session

    def login(self) -> None:
        """通过 IDS CAS 登录校园卡系统, 获取 openid"""
        location = self.ids.check_and_login(
            target=CARD_CAS_TARGET,
            username=self.username,
            password=self.password,
        )
        # 跟随重定向链, 从最终 URL 提取 openid
        url = location
        for _ in range(10):
            resp = self.session.get(url, allow_redirects=False)
            if resp.status_code in (301, 302) and "Location" in resp.headers:
                url = resp.headers["Location"]
            else:
                break

        # openid 出现在 URL 参数或页面中
        match = re.search(r"openid=([^&\"']+)", url)
        if not match:
            match = re.search(r"openid=([^&\"']+)", resp.text if resp else "")
        if not match:
            raise CardException("无法获取 openid")
        self.openid = match.group(1)

    def get_balance(self) -> dict:
        """
        获取一卡通余额

        Returns:
            {balance: float, ...} (具体字段取决于接口返回)
        """
        if not self.openid:
            self.login()

        resp = self.session.get(
            f"https://v8scan.xidian.edu.cn/myaccount/openMyAccount?openid={self.openid}",
        )
        # 页面中包含余额信息, 需要从 HTML 解析
        from bs4 import BeautifulSoup
        soup = BeautifulSoup(resp.text, "html.parser")

        # 尝试提取余额 (页面结构可能变化)
        balance_text = ""
        for el in soup.find_all(string=re.compile(r"\d+\.\d+")):
            balance_text = el.strip()
            break

        return {"balance_raw": balance_text, "openid": self.openid, "html_length": len(resp.text)}

    def get_transactions(self, page: int = 1, page_size: int = 20) -> list[dict]:
        """获取消费记录"""
        if not self.openid:
            self.login()

        resp = self.session.post(
            f"https://v8scan.xidian.edu.cn/selftrade/queryCardSelfTradeList?openid={self.openid}",
            data={"pageNo": page, "pageSize": page_size},
        )
        try:
            return resp.json().get("resultData", {}).get("rows", [])
        except Exception:
            return []


class CardException(Exception):
    pass


if __name__ == "__main__":
    import getpass

    print("=== XIDIAN School Card Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    card = CardSession(user, pwd)
    card.login()
    print(f"[OK] openid: {card.openid}")

    balance = card.get_balance()
    print(f"[OK] 余额信息: {balance}")
