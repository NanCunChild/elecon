"""
图书馆 — 借阅列表 + 图书搜索 + 续借

转化自: traintime_pda/lib/repository/xidian_ids/library_session.dart

依赖: ids/login.py
注意: 图书馆系统通过 CAS 登录到 hyytsgxzs.xidian.edu.cn 获取 userId + token,
      实际数据接口在 shuwo.xidian.edu.cn
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ids.login import IDSSession

LIBRARY_CAS_TARGET = (
    "https://hyytsgxzs.xidian.edu.cn/api/index/casLoginDo.html?"
    "libraryId=5&openId=REDACTED_OPENID&source=xdbb"  # 脱敏：真实 openId 属凭证等价物（红线 #1），勿提交
)


class LibrarySession:
    """图书馆会话"""

    def __init__(self, username: str, password: str):
        self.username = username
        self.password = password
        self.ids = IDSSession()
        self.user_id: int = 0
        self.token: str = ""

    @property
    def session(self):
        return self.ids.session

    def login(self) -> None:
        """CAS 登录图书馆, 获取 userId + token"""
        location = self.ids.check_and_login(
            target=LIBRARY_CAS_TARGET,
            username=self.username,
            password=self.password,
        )

        match_json = re.compile(r"wx\.miniProgram\.postMessage\((.*?)\);", re.DOTALL)
        result_text = ""

        for _ in range(15):
            resp = self.session.get(location, allow_redirects=False)
            if resp.status_code in (301, 302) and "Location" in resp.headers:
                location = resp.headers["Location"]
            else:
                m = match_json.search(resp.text)
                if m:
                    result_text = m.group(1)
                    result_text = result_text.replace("data", '"data"', 1)
                break

        if not result_text:
            raise LibraryException("无法从登录响应中提取 userId/token")

        data = json.loads(result_text)
        self.user_id = data["data"]["id"]
        self.token = data["data"]["token"]

    def get_borrow_list(self) -> list[dict]:
        """
        获取当前借阅列表

        Returns:
            [{book_name, barcode, borrow_date, return_date, renew_count, ...}, ...]
        """
        if not self.user_id:
            self.login()

        resp = self.session.post(
            "https://shuwo.xidian.edu.cn/xidian_book/api/borrow/getBorrowList.html",
            data={
                "libraryId": 5,
                "userId": self.user_id,
                "token": self.token,
                "cardNumber": self.username,
                "page": 0,
            },
        )
        data = resp.json()
        rows = data.get("data", [])
        if not rows:
            return []

        books = []
        for row in rows:
            books.append({
                "book_name": row.get("bookName", ""),
                "barcode": row.get("barcode", ""),
                "borrow_date": row.get("borrowDate", ""),
                "return_date": row.get("returnDate", ""),
                "renew_count": row.get("renewCount", 0),
                "location": row.get("location", ""),
            })
        return books

    def renew_book(self, barcode: str) -> str:
        """
        续借图书

        Args:
            barcode: 图书条码

        Returns:
            续借结果消息
        """
        if not self.user_id:
            self.login()

        resp = self.session.post(
            "https://shuwo.xidian.edu.cn/xidian_book/api/borrow/renewBook.html",
            data={
                "libraryId": 5,
                "userId": self.user_id,
                "token": self.token,
                "cardNumber": self.username,
                "barNumber": barcode,
            },
        )
        return resp.json().get("msg", "未知结果")

    def search_book(self, keyword: str, page: int = 1) -> list[dict]:
        """
        搜索图书 (无需登录)

        Args:
            keyword: 搜索关键词
            page: 页码

        Returns:
            [{book_name, author, isbn, publisher, doc_number, ...}, ...]
        """
        resp = self.session.post(
            "https://shuwo.xidian.edu.cn/xidian_book/api/search/list.html",
            data={
                "libraryId": 5,
                "searchWord": keyword,
                "searchFiled": "title",
                "page": page,
                "searchLocationStatus": 1,
            },
        )
        data = resp.json()
        rows = data.get("data", {}).get("list", [])

        books = []
        for row in rows:
            books.append({
                "book_name": row.get("bookName", ""),
                "author": row.get("author", ""),
                "isbn": row.get("isbn", ""),
                "publisher": row.get("publisher", ""),
                "doc_number": row.get("docNumber"),
                "call_number": row.get("callNumber", ""),
            })
        return books


class LibraryException(Exception):
    pass


if __name__ == "__main__":
    import getpass

    print("=== XIDIAN Library Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    lib = LibrarySession(user, pwd)
    lib.login()
    print(f"[OK] userId={lib.user_id}, token={lib.token[:8]}...")

    borrows = lib.get_borrow_list()
    print(f"\n[OK] 当前借阅 {len(borrows)} 本:")
    for b in borrows:
        print(f"  {b['book_name']} | 应还: {b['return_date']}")
