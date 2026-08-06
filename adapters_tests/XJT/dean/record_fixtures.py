"""
XJT dean 夹具录制脚本 —— 在校园网/本机运行，录一次完整流程并自动脱敏。

产出三份夹具（供 adapter 录制/回放双跑，ADR-009 §3.6 / FLOW.md §5）：
  1. challenge.html     —— 步骤[1] 挑战页（challengeId/answer 替换为假值）
  2. challenge_response.json —— 步骤[3] POST 响应（body + 响应头；client_id 脱敏）
  3. notice.html         —— 步骤[5] 真实通知页（公开数据；cookie 痕迹清除）

脱敏要求（红线 #8）：challengeId / client_id / JSESSIONID / 所有 cookie 值
一律替换为假值；不留真实会话态。

用法：
  cd adapters_tests/XJT/dean
  python record_fixtures.py                          # 默认输出到 adapters/school-xjt/fixtures/
  python record_fixtures.py --outdir /tmp/fixtures   # 自定义输出目录
  python record_fixtures.py --raw                    # 原始文件仅写仓库 .private-probes/
"""

import argparse
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

import requests
ORIGIN = "https://dean.xjtu.edu.cn"
CHALLENGE_URL = f"{ORIGIN}/dynamic_challenge"
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
)

REDACTED_CHALLENGE_ID = "REDACTED_CHALLENGE_ID_0000000000"
REDACTED_CHALLENGE_ANSWER = "0"
REDACTED_CLIENT_ID = "REDACTED_CLIENT_ID_0000000000"
REDACTED_JSESSIONID = "REDACTED_JSESSIONID_0000000000"
REDACTED_COOKIE = "REDACTED"


def find_repo_root() -> Path:
    d = Path(__file__).resolve().parent
    for _ in range(6):
        if (d / "AGENTS.md").exists():
            return d
        d = d.parent
    raise RuntimeError("无法定位仓库根目录（未找到 AGENTS.md）")


def redact_html(
    html: str,
    cid: str | None,
    client_id: str | None,
    answer: int | None = None,
) -> str:
    out = html
    if cid:
        out = out.replace(cid, REDACTED_CHALLENGE_ID)
    if client_id:
        out = out.replace(client_id, REDACTED_CLIENT_ID)
    if answer is not None:
        out = re.sub(
            r'(var\s+answer\s*=\s*)' + re.escape(str(answer)) + r'\b',
            rf'\g<1>{REDACTED_CHALLENGE_ANSWER}',
            out,
        )
    out = re.sub(r"JSESSIONID=[^;\"'\s]+", f"JSESSIONID={REDACTED_JSESSIONID}", out)
    out = re.sub(r"client_id=[^;\"'\s]+", f"client_id={REDACTED_CLIENT_ID}", out)
    return out


def redact_headers(headers: dict, client_id: str | None) -> dict:
    content_type = next(
        (str(value) for key, value in headers.items() if key.lower() == "content-type"),
        None,
    )
    if content_type is None:
        return {}
    media_type = content_type.split(";", 1)[0].strip().lower()
    if media_type != "application/json":
        raise ValueError("unexpected challenge response Content-Type")
    return {"Content-Type": "application/json"}


def redact_json_body(body: dict, client_id: str | None) -> dict:
    if set(body) != {"success", "client_id"}:
        raise ValueError("unexpected challenge response body fields")
    if body["success"] is not True:
        raise ValueError("unexpected challenge response success value")
    if not isinstance(body["client_id"], str) or not body["client_id"]:
        raise ValueError("unexpected challenge response client_id")
    if client_id is None or body["client_id"] != client_id:
        raise ValueError("challenge response client_id mismatch")
    return {"success": True, "client_id": REDACTED_CLIENT_ID}


def _write_private(path: Path, content: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    path.chmod(0o600)


def record(repo_root: Path, outdir: Path, save_raw: bool) -> None:
    session = requests.Session()
    session.headers.update({
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "User-Agent": UA,
        "Referer": ORIGIN + "/",
    })

    # ── [1] GET 首页 → 挑战页 ──
    print("[1/5] GET 首页，触发挑战页...")
    res1 = session.get(ORIGIN + "/", timeout=15)
    challenge_html = res1.text

    if "var challengeId" not in challenge_html:
        print("  未触发挑战页（可能已有有效 cookie 或站点策略变更）。")
        print("  若需录制挑战流程，请清除浏览器/session cookie 后重试。")
        return

    # ── [2] 解析 challengeId / answer ──
    cid_m = re.search(r'var challengeId\s*=\s*"([^"]+)"', challenge_html)
    ans_m = re.search(r'var answer\s*=\s*(\d+)', challenge_html)
    if not cid_m or not ans_m:
        print("  解析 challengeId/answer 失败，页面结构可能已变。")
        return
    cid = cid_m.group(1)
    answer = int(ans_m.group(1))
    print("  challenge 已解析。")

    # ── [3] POST 挑战 ──
    print("[2/5] POST 挑战端点...")
    time.sleep(0.8)
    payload = {
        "challenge_id": cid,
        "answer": answer,
        "browser_info": {
            "userAgent": UA,
            "language": "zh-CN",
            "platform": "Linux x86_64",
            "cookieEnabled": True,
            "hardwareConcurrency": 8,
            "deviceMemory": 8,
            "timezone": "Asia/Shanghai",
        },
    }
    res2 = session.post(CHALLENGE_URL, json=payload, timeout=15)
    challenge_body = res2.json()
    challenge_headers = dict(res2.headers)

    client_id = challenge_body.get("client_id")
    if not challenge_body.get("success") or not client_id:
        print("  挑战失败（响应内容不输出，以免泄漏凭证材料）。")
        return
    print("  挑战通过。")

    # 手动注入 client_id cookie（模拟浏览器 JS 行为）
    session.cookies.set("client_id", client_id, domain="dean.xjtu.edu.cn", path="/")

    # ── [5] GET 首页（带 cookie）→ 真实通知页 ──
    print("[3/5] GET 真实通知页...")
    res3 = session.get(ORIGIN + "/", timeout=15)
    res3.encoding = res3.apparent_encoding
    notice_html = res3.text

    if "var challengeId" in notice_html:
        print("  仍然是挑战页，client_id 可能未生效。录制中止。")
        return

    # ── 保存 ──
    private_root = repo_root / ".private-probes"
    private_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    private_root.chmod(0o700)
    print(f"[4/5] 脱敏并保存到 {outdir}/")

    if save_raw:
        raw_dir = private_root / "xjt-dean"
        raw_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        raw_dir.chmod(0o700)
        _write_private(raw_dir / "challenge.html", challenge_html)
        _write_private(
            raw_dir / "challenge_response.json",
            json.dumps({"headers": challenge_headers, "body": challenge_body}, indent=2, ensure_ascii=False),
        )
        _write_private(raw_dir / "notice.html", notice_html)
        print("  原始文件已保存到仓库 .private-probes/xjt-dean/（仅本地调试）。")

    # 脱敏
    redacted_challenge = redact_html(challenge_html, cid, client_id, answer)
    redacted_notice = redact_html(notice_html, cid, client_id, answer)
    redacted_resp = {
        "headers": redact_headers(challenge_headers, client_id),
        "body": redact_json_body(challenge_body, client_id),
    }

    redacted_resp_text = json.dumps(redacted_resp, indent=2, ensure_ascii=False)
    # 候选文件先在 gitignore 的私有目录以安全权限落盘；scanner 通过后才进入 tracked 目录。
    with tempfile.TemporaryDirectory(prefix="xjt-dean-candidate-", dir=private_root) as candidate:
        candidate_dir = Path(candidate)
        candidate_dir.chmod(0o700)
        _write_private(candidate_dir / "challenge.html", redacted_challenge)
        _write_private(candidate_dir / "challenge_response.json", redacted_resp_text)
        _write_private(candidate_dir / "notice.html", redacted_notice)
        subprocess.run(
            ["npm", "run", "scan", "--", f"--path={candidate_dir.resolve()}"],
            cwd=repo_root / "tools",
            check=True,
        )

    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "challenge.html").write_text(redacted_challenge, encoding="utf-8")
    (outdir / "challenge_response.json").write_text(redacted_resp_text, encoding="utf-8")
    (outdir / "notice.html").write_text(redacted_notice, encoding="utf-8")
    subprocess.run(
        ["npm", "run", "scan", "--", f"--path={outdir.resolve()}"],
        cwd=repo_root / "tools",
        check=True,
    )

    print("[5/5] 录制完成。")
    print(f"  challenge.html            ({len(redacted_challenge)} 字符)")
    print(f"  challenge_response.json   (headers + body)")
    print(f"  notice.html               ({len(redacted_notice)} 字符)")
    print()
    print("下一步：检查脱敏文件确认无真实 cookie/token 残留，然后提交到")
    print("adapters/school-xjt/fixtures/（红线 #8：绝不提交真实学生数据）。")


def main() -> None:
    repo_root = find_repo_root()
    default_outdir = repo_root / "adapters" / "school-xjt" / "fixtures" / "dean.xjtu.edu.cn"

    parser = argparse.ArgumentParser(description="XJT dean 夹具录制（校园网运行）")
    parser.add_argument(
        "--outdir", type=Path, default=default_outdir,
        help=f"输出目录（默认 {default_outdir}）",
    )
    parser.add_argument(
        "--raw", action="store_true",
        help="同时保存未脱敏原始文件到仓库 .private-probes/（权限 0700/0600）",
    )
    args = parser.parse_args()

    record(repo_root, args.outdir, args.raw)


if __name__ == "__main__":
    main()
