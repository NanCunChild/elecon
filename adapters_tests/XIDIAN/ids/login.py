"""
IDS (统一认证服务) 登录模块 — CAS/SSO + AES 密码加密 + 滑块验证码自动求解

转化自: traintime_pda/lib/repository/xidian_ids/ids_session.dart
         traintime_pda/lib/repository/xidian_ids/slider_captcha_client.dart
         traintime_pda/lib/repository/network_session.dart

依赖: pip install requests pycryptodome Pillow numpy beautifulsoup4
"""

import base64
import json
import math
import random
import time
import urllib.parse
from io import BytesIO

import numpy as np
import requests
from bs4 import BeautifulSoup
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad
from PIL import Image

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130.0.0.0 Safari/537.36"
)

IDS_BASE = "https://ids.xidian.edu.cn/authserver"
AES_CHARS = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678"


# ──────────────────────────────────────────────
# AES 工具
# ──────────────────────────────────────────────

def aes_encrypt_password(password: str, salt: str) -> str:
    """IDS 密码加密: AES-CBC, key=salt, iv='xidianscriptsxdu', 明文前补64字节固定串+PKCS7"""
    key = salt.encode("utf-8")
    iv = b"xidianscriptsxdu"
    plaintext = ("xidianscriptsxdu" * 4 + password).encode("utf-8")
    plaintext_padded = pad(plaintext, 16)
    cipher = AES.new(key, AES.MODE_CBC, iv)
    encrypted = cipher.encrypt(plaintext_padded)
    return base64.b64encode(encrypted).decode()


def aes_encrypt_captcha(payload: str, key_bytes: bytes) -> str:
    """滑块验证码 payload 加密: AES-CBC, key=图片末16字节, iv/nonce 随机生成"""
    randstr = "".join(random.choice(AES_CHARS) for _ in range(80))
    nonce = randstr[:64]
    iv = randstr[64:80].encode("utf-8")
    plaintext = (nonce + payload).encode("utf-8")
    plaintext_padded = pad(plaintext, 16)
    cipher = AES.new(key_bytes, AES.MODE_CBC, iv)
    encrypted = cipher.encrypt(plaintext_padded)
    return base64.b64encode(encrypted).decode()


# ──────────────────────────────────────────────
# 滑块验证码求解 (NCC 图像匹配)
# ──────────────────────────────────────────────

PUZZLE_WIDTH = 280


def _image_to_luminance(img: Image.Image) -> np.ndarray:
    """转换为灰度浮点数组"""
    return np.array(img.convert("L"), dtype=np.float64)


def _image_bbox_alpha(img: Image.Image) -> tuple:
    """找到 alpha=255 的像素边界框"""
    alpha = np.array(img.split()[-1])
    rows = np.any(alpha == 255, axis=1)
    cols = np.any(alpha == 255, axis=0)
    if not rows.any():
        return (0, 0, img.width - 1, img.height - 1)
    y_min, y_max = np.where(rows)[0][[0, -1]]
    x_min, x_max = np.where(cols)[0][[0, -1]]
    return (int(x_min), int(y_min), int(x_max), int(y_max))


def solve_offset(puzzle_data: bytes, piece_data: bytes, border: int = 24) -> float | None:
    """NCC 匹配计算滑块偏移量 (返回 0~1 的比率)"""
    puzzle_img = Image.open(BytesIO(puzzle_data)).convert("RGBA")
    piece_img = Image.open(BytesIO(piece_data)).convert("RGBA")

    x_min, y_min, x_max, y_max = _image_bbox_alpha(piece_img)
    xl = x_min + border
    yt = y_min + border
    xr = x_max - border
    yb = y_max - border
    if xl >= xr or yt >= yb:
        return None

    w = xr - xl + 1
    h = yb - yt + 1

    piece_lum = _image_to_luminance(piece_img)
    puzzle_lum = _image_to_luminance(puzzle_img)

    template = piece_lum[yt:yt + h, xl:xl + w]
    tmpl_mean = template.mean()
    template_norm = template - tmpl_mean

    big_width = puzzle_img.width - piece_img.width + w
    best_ncc = -1.0
    best_x = 0

    for x in range(big_width - w):
        window = puzzle_lum[yt:yt + h, (x + xl):(x + xl + w)]
        win_mean = window.mean()
        win_norm = window - win_mean
        numerator = np.sum(win_norm * template_norm)
        denominator = np.sqrt(np.sum(win_norm ** 2)) + 1e-6
        ncc = numerator / denominator
        if ncc > best_ncc:
            best_ncc = ncc
            best_x = x

    return best_x / puzzle_img.width


def generate_tracks(offset_px: int) -> list[dict]:
    """生成仿真鼠标轨迹 (sigmoid 曲线 + 噪声)"""
    tracks = [{"a": 0, "b": 0, "c": 0}]
    n = random.randint(10, 14)
    norm_factor = 1.0 / (1.0 + math.exp(-7.0 * (1.0 - 0.42)))
    b = 0
    for i in range(n):
        z = (1.0 / (1.0 + math.exp(-7.0 * (i / n - 0.42)))) / norm_factor
        a = min(offset_px - 1, max(tracks[-1]["a"] + 1, round(offset_px * z)))
        r = random.random()
        if r < 0.65:
            b -= 1
        elif r < 0.80:
            b += 1
        b = max(-10, min(10, b))
        tracks.append({"a": a, "b": b, "c": random.randint(300, 500)})
    tracks.append({"a": offset_px, "b": b, "c": random.randint(300, 500)})
    return tracks


# ──────────────────────────────────────────────
# IDS 登录主流程
# ──────────────────────────────────────────────

class IDSSession:
    """IDS 统一认证登录会话"""

    def __init__(self):
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": UA})

    def _get_login_page(self, target: str | None = None) -> str:
        """获取登录页 HTML"""
        params = {"service": target} if target else None
        resp = self.session.get(f"{IDS_BASE}/login", params=params, allow_redirects=False)
        if resp.status_code in (301, 302):
            return resp.headers["Location"]
        if resp.status_code == 401:
            raise PasswordWrongException(resp.text)
        return resp.text

    def _parse_login_form(self, html: str) -> tuple[dict, str]:
        """解析登录表单, 返回 (hidden_fields, aes_salt)"""
        soup = BeautifulSoup(html, "html.parser")
        salt_input = soup.find(id="pwdEncryptSalt")
        if not salt_input:
            raise LoginFailedException("无法找到加密 salt")
        salt = salt_input.get("value", "")

        fields = {}
        for inp in soup.find_all("input", {"type": "hidden"}):
            name = inp.get("name") or inp.get("id")
            value = inp.get("value", "")
            if name in ("lt", "execution"):
                fields[name] = value
        return fields, salt

    def _solve_slider_captcha(self) -> None:
        """自动求解滑块验证码"""
        for attempt in range(6):
            resp = self.session.get(
                f"{IDS_BASE}/common/openSliderCaptcha.htl",
                params={"_": str(int(time.time() * 1000))},
            )
            data = resp.json()
            puzzle_data = base64.b64decode(data["bigImage"])
            piece_data = base64.b64decode(data["smallImage"])
            aes_key = piece_data[-16:]

            offset = solve_offset(puzzle_data, piece_data)
            if offset is None:
                continue

            base_move = round(offset * PUZZLE_WIDTH)

            for delta in [1, -1, 2, -2, 3, -3, 4]:
                move = base_move + delta
                if move < 0 or move > PUZZLE_WIDTH:
                    continue
                tracks = generate_tracks(move)
                payload = json.dumps({
                    "canvasLength": PUZZLE_WIDTH,
                    "moveLength": tracks[-1]["a"],
                    "tracks": tracks,
                }, separators=(",", ":"))
                sign = aes_encrypt_captcha(payload, aes_key)

                time.sleep(max(0, (tracks[-1]["c"] - 100) / 1000))

                verify_resp = self.session.post(
                    f"{IDS_BASE}/common/verifySliderCaptcha.htl",
                    data=f"sign={urllib.parse.quote_plus(sign)}",
                    headers={
                        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
                        "X-Requested-With": "XMLHttpRequest",
                    },
                )
                result = verify_resp.json()
                if result.get("errorCode") == 1:
                    return

        raise CaptchaSolveFailedException("滑块验证码求解失败 (6 轮尝试)")

    def login(self, username: str, password: str, target: str | None = None) -> str:
        """
        执行完整登录流程，返回仅供会话内部继续跟随的最终重定向 URL。

        Args:
            username: 学号/工号
            password: 密码
            target: CAS service URL (登录成功后跳转目标)

        Returns:
            最终重定向 URL
        """
        page = self._get_login_page(target)
        if not page.startswith("http") and not page.startswith("/"):
            pass
        else:
            return self._follow_redirects(page)

        hidden_fields, salt = self._parse_login_form(page)
        encrypted_pwd = aes_encrypt_password(password, salt)

        self.session.get(
            f"{IDS_BASE}/common/openSliderCaptcha.htl",
            params={"_": str(int(time.time() * 1000))},
        )
        self._solve_slider_captcha()

        form_data = {
            "username": username,
            "password": encrypted_pwd,
            "rememberMe": "true",
            "cllt": "userNameLogin",
            "dllt": "generalLogin",
            "_eventId": "submit",
            **hidden_fields,
        }

        params = {"service": target} if target else None
        resp = self.session.post(
            f"{IDS_BASE}/login",
            data=form_data,
            params=params,
            allow_redirects=False,
        )

        if resp.status_code in (301, 302):
            return resp.headers["Location"]
        if resp.status_code == 401:
            raise PasswordWrongException(resp.text)

        soup = BeautifulSoup(resp.text, "html.parser")
        form = soup.find("form", id="continue")
        if form:
            inputs = form.find_all("input")
            post_data = {i.get("name"): i.get("value", "") for i in inputs if i.get("name")}
            resp2 = self.session.post(f"{IDS_BASE}/login", data=post_data, allow_redirects=False)
            if resp2.status_code in (301, 302):
                return resp2.headers["Location"]

        raise LoginFailedException(f"登录失败, 状态码: {resp.status_code}")

    def _follow_redirects(self, url: str) -> str:
        """手动跟随重定向链直到最终页面"""
        while True:
            resp = self.session.get(url, allow_redirects=False)
            if resp.status_code in (301, 302) and "Location" in resp.headers:
                url = resp.headers["Location"]
            else:
                return url

    def check_and_login(self, target: str, username: str, password: str) -> str:
        """检查是否已登录, 未登录则执行登录, 返回最终 URL"""
        resp = self.session.get(
            f"{IDS_BASE}/login",
            params={"service": target},
            allow_redirects=False,
        )
        if resp.status_code in (301, 302):
            return resp.headers["Location"]
        if resp.status_code == 401:
            raise PasswordWrongException(resp.text)

        soup = BeautifulSoup(resp.text, "html.parser")
        form = soup.find("form", id="continue")
        if form:
            inputs = form.find_all("input")
            post_data = {i.get("name"): i.get("value", "") for i in inputs if i.get("name")}
            resp2 = self.session.post(f"{IDS_BASE}/login", data=post_data, allow_redirects=False)
            if resp2.status_code in (301, 302):
                return resp2.headers["Location"]

        return self.login(username, password, target)


class PasswordWrongException(Exception):
    pass


class LoginFailedException(Exception):
    pass


class CaptchaSolveFailedException(Exception):
    pass


# ──────────────────────────────────────────────
# 独立运行测试
# ──────────────────────────────────────────────

if __name__ == "__main__":
    import getpass

    print("=== XIDIAN IDS Login Test ===")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    ids = IDSSession()
    try:
        url = ids.login(user, pwd, target="https://ehall.xidian.edu.cn/login?service=https://ehall.xidian.edu.cn/new/index.html")
        print("[OK] 登录成功，票据 URL 不输出。")
        final = ids._follow_redirects(url)
        print("[OK] 重定向流程完成，最终 URL 不输出。")
    except PasswordWrongException:
        print("[FAIL] 密码错误（响应内容不输出）。")
    except LoginFailedException:
        print("[FAIL] 登录失败（响应内容不输出）。")
    except CaptchaSolveFailedException:
        print("[FAIL] 验证码求解失败。")
    except requests.RequestException:
        print("[FAIL] 网络请求失败（URL 与响应内容不输出）。")
