"""
水电查询 — 电表余量 + 用电/用水历史记录

转化自: traintime_pda/lib/repository/xidian_ids/energy_session.dart

依赖: ids/login.py
注意: 必须在校园网环境下才能访问 ignypt.xidian.edu.cn
      所有请求体 AES-CBC 加密 (固定 key/iv = "1234567812345678")
      每个请求需附带 timestamp + signature (从 GetSignature 接口获取)
"""

import base64
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ids.login import IDSSession

ENERGY_AES_KEY = b"1234567812345678"
ENERGY_AES_IV = b"1234567812345678"

ENERGY_CAS_TARGET = (
    "https://xxcapp.xidian.edu.cn/uc/api/oauth/index?"
    "redirect=https://ignypt.xidian.edu.cn/revenueH5/login?"
    "opcode=MPAY&appid=200260318155520600&state=12312312312312&qrcode=0"
)


def _energy_encrypt(data: dict) -> str:
    """AES-CBC 加密请求数据"""
    plaintext = json.dumps(data, separators=(",", ":")).encode("utf-8")
    padded = pad(plaintext, 16)
    cipher = AES.new(ENERGY_AES_KEY, AES.MODE_CBC, ENERGY_AES_IV)
    return base64.b64encode(cipher.encrypt(padded)).decode()


class EnergySession:
    """水电查询会话 (需校园网)"""

    def __init__(self, username: str, password: str):
        self.username = username
        self.password = password
        self.ids = IDSSession()
        self.node_id: str = ""

    @property
    def session(self):
        return self.ids.session

    def _get_signature(self) -> tuple[str, str]:
        """获取 timestamp + signature"""
        resp = self.session.post(
            "https://ignypt.xidian.edu.cn/baseNew/api/User/GetSignature",
            json={
                "data": "",
                "access_token": "",
                "OpCode": "MPAY",
                "RequestID": "",
            },
        )
        data = resp.json()["data"]
        return str(data["timestamp"]), str(data["signature"])

    def _request_get(self, url: str, data: dict) -> dict:
        """发送 GET 请求 (AES 加密参数)"""
        timestamp, signature = self._get_signature()
        encrypted = _energy_encrypt(data)
        resp = self.session.get(
            url,
            params={"content": quote(encrypted)},
            headers={
                "timestamp": timestamp,
                "signature": signature,
                "OpCode": "MPAY",
                "OrgId": "",
                "RequestID": "",
            },
        )
        return resp.json()

    def _request_post(self, url: str, data: dict) -> dict:
        """发送 POST 请求 (AES 加密 body)"""
        timestamp, signature = self._get_signature()
        encrypted = _energy_encrypt(data)
        resp = self.session.post(
            url,
            json={"content": encrypted},
            headers={
                "timestamp": timestamp,
                "signature": signature,
                "OpCode": "MPAY",
                "OrgId": "",
                "RequestID": "",
            },
        )
        return resp.json()

    def login(self) -> None:
        """通过 IDS CAS 登录水电系统, 获取 NodeID"""
        location = self.ids.check_and_login(
            target=ENERGY_CAS_TARGET,
            username=self.username,
            password=self.password,
        )

        # 跟随重定向链获取 code
        for _ in range(15):
            resp = self.session.get(location, allow_redirects=False)
            if resp.status_code in (301, 302) and "Location" in resp.headers:
                location = resp.headers["Location"]
            else:
                break

        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(location)
        code = parse_qs(parsed.query).get("code", [""])[0]
        if not code:
            raise EnergyException("无法获取 OAuth code")

        # 用 code 获取用户信息
        self._request_get(
            "https://ignypt.xidian.edu.cn/estManage/api/WeChat/V2/OauthGetUserInfo",
            {"CODE": code},
        )

        # 登录获取 NodeID
        resp_data = self._request_post(
            "https://ignypt.xidian.edu.cn/estManage/api/WeChat/V2/H5UserIDLogIn",
            {
                "UserID": self.username,
                "Pwd": "",
                "IsCehckPwd": 1,
                "NodeID": "",
            },
        )
        nodes = resp_data.get("ResData", [])
        if not nodes:
            raise EnergyException("登录失败, 无 NodeID")
        self.node_id = nodes[0]["NodeID"]

    def get_meter_list(self) -> dict:
        """
        获取电表/水表列表及余量

        Returns:
            {electricity_remain: float, electricity_met_id: str,
             water_met_id: str | None, meters: [...]}
        """
        if not self.node_id:
            self.login()

        resp_data = self._request_get(
            "https://ignypt.xidian.edu.cn/estManage/api/wechat/v2/H5QueryMeterList",
            {"NodeID": self.node_id},
        )
        rows = resp_data.get("ResData", {}).get("rows", [])
        if not rows:
            raise EnergyException("无表具数据")

        # MediumCode: "2" = 电, "1" = 水
        elec_idx = 0 if rows[0].get("MediumCode") == "2" else 1
        water_idx = 1 - elec_idx if len(rows) > 1 else None

        result = {
            "electricity_remain": float(rows[elec_idx].get("LastNum", 0)),
            "electricity_met_id": rows[elec_idx].get("MetID", ""),
            "electricity_last_read_date": rows[elec_idx].get("LastReadDate", ""),
            "water_met_id": rows[water_idx].get("MetID", "") if water_idx is not None else None,
            "meters": rows,
        }
        return result

    def get_meter_history(self, met_id: str, start_date: str, end_date: str) -> list[dict]:
        """
        获取表具读数历史

        Args:
            met_id: 表具 ID
            start_date: 开始日期 (yyyy-MM-dd)
            end_date: 结束日期 (yyyy-MM-dd)

        Returns:
            [{read_time, read_num, use_num, ...}, ...]
        """
        resp_data = self._request_get(
            "https://ignypt.xidian.edu.cn/estManage/api/WeChat/V2/GetMetRead",
            {
                "MetID": met_id,
                "ReadTimeS": start_date,
                "ReadTimeE": end_date,
                "ReadNum": "",
            },
        )
        return resp_data.get("ResData", {}).get("rows", [])

    def get_electricity_info(self) -> dict:
        """
        获取电量信息 (余量 + 近一月用电历史)

        Returns:
            {remain: float, last_read_date: str, history: [...]}
        """
        meters = self.get_meter_list()
        met_id = meters["electricity_met_id"]
        last_date_str = meters["electricity_last_read_date"]

        # 计算查询范围: 最后读数日期前一月
        try:
            end_date = datetime.strptime(last_date_str, "%Y-%m-%d")
        except ValueError:
            end_date = datetime.now()
        start_date = end_date - timedelta(days=30)

        history = self.get_meter_history(
            met_id,
            start_date.strftime("%Y-%m-%d"),
            end_date.strftime("%Y-%m-%d"),
        )

        return {
            "remain": meters["electricity_remain"],
            "last_read_date": last_date_str,
            "history": history,
        }


class EnergyException(Exception):
    pass


if __name__ == "__main__":
    import getpass

    print("=== XIDIAN Energy (水电) Test ===")
    print("注意: 必须在校园网环境下运行!")
    user = input("学号: ").strip()
    pwd = getpass.getpass("密码: ")

    energy = EnergySession(user, pwd)
    energy.login()
    print("[OK] 水电会话已建立，NodeID 不输出。")

    info = energy.get_electricity_info()
    print(f"[OK] 电量余额: {info['remain']} kWh")
    print(f"[OK] 最后读数: {info['last_read_date']}")
    print(f"[OK] 历史记录: {len(info['history'])} 条")
