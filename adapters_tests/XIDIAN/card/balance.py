"""
一卡通 (校园卡) — 余额查询 + 消费记录

转化自: traintime_pda/lib/repository/xidian_ids/school_card_session.dart

依赖: ids/login.py
注意: 校园卡系统使用 OAuth 跳转获取 openid, 基于 v8scan.xidian.edu.cn
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

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

    def get_balance_response(self):
        """获取余额页原始响应；仅供本机私有采样，不打印或返回 openid。"""
        if not self.openid:
            self.login()

        return self.session.get(
            f"https://v8scan.xidian.edu.cn/myaccount/openMyAccount?openid={self.openid}",
        )

    def get_transactions_response(self, page: int = 1, page_size: int = 20):
        """获取流水接口原始响应；仅供本机私有采样。"""
        if not self.openid:
            self.login()

        return self.session.post(
            f"https://v8scan.xidian.edu.cn/selftrade/queryCardSelfTradeList?openid={self.openid}",
            data={"pageNo": page, "pageSize": page_size},
        )


class CardException(Exception):
    pass


def _private_output_dir() -> Path:
    root = Path(__file__).resolve().parents[3]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = root / ".private-probes" / "xidian-card" / stamp
    output.mkdir(parents=True, exist_ok=False)
    output.chmod(0o700)
    return output


def _write_private(path: Path, content: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)


def _safe_url(raw: str) -> str:
    """只保留 scheme/host/path；query/fragment 可能含凭证，恒剥除（ADR-020 §2.5）。"""
    parsed = urlsplit(raw)
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))


def _json_shape(value, depth: int = 0):
    """只输出字段名与类型，不输出任何响应值。"""
    if depth >= 8:
        return "depth-limit"
    if isinstance(value, dict):
        return {str(key): _json_shape(item, depth + 1) for key, item in value.items()}
    if isinstance(value, list):
        return {"type": "array", "length": len(value), "item": _json_shape(value[0], depth + 1) if value else None}
    if value is None:
        return "null"
    return type(value).__name__


def capture_private(card: CardSession, output: Path) -> None:
    """保存私有原件与无值结构摘要；原件必须人工脱敏后才能移入 fixture。"""
    balance = card.get_balance_response()
    transactions = card.get_transactions_response()

    _write_private(output / "balance.raw.html", balance.text)
    _write_private(output / "transactions.raw.json", transactions.text)

    try:
        transaction_shape = _json_shape(transactions.json())
    except ValueError:
        transaction_shape = {"parseError": "response is not JSON"}
    summary = {
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "balance": {
            "status": balance.status_code,
            "url": _safe_url(balance.url),
            "contentType": balance.headers.get("Content-Type", ""),
            "bytes": len(balance.content),
        },
        "transactions": {
            "status": transactions.status_code,
            "url": _safe_url(transactions.url),
            "contentType": transactions.headers.get("Content-Type", ""),
            "bytes": len(transactions.content),
            "shape": transaction_shape,
        },
    }
    _write_private(output / "summary.no-values.json", json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    import getpass

    print("=== XIDIAN School Card Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    card = CardSession(user, pwd)
    card.login()
    output_dir = _private_output_dir()
    capture_private(card, output_dir)
    print(f"[OK] 私有原件已写入: {output_dir}")
    print("[WARN] balance.raw.html / transactions.raw.json 含真实学生数据，只能本机查看。")
    print("[WARN] 人工脱敏并运行 tools scanner 前，禁止复制到 adapters/fixtures 或提交 Git。")
