#!/usr/bin/env python3
import re
import subprocess
import time
import xml.etree.ElementTree as ET


def adb(*args: str) -> str:
    return subprocess.run(
        ["adb", *args], check=True, capture_output=True, text=True
    ).stdout


def ui_root() -> ET.Element:
    output = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    start = output.find("<?xml")
    if start < 0:
        raise RuntimeError(f"uiautomator returned no XML: {output}")
    end = output.find("</hierarchy>", start)
    if end < 0:
        raise RuntimeError(f"uiautomator returned incomplete XML: {output}")
    return ET.fromstring(output[start : end + len("</hierarchy>")])


def wait_for(text: str, timeout: float = 20) -> ET.Element:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for node in ui_root().iter("node"):
            label = " ".join(
                (node.attrib.get("text", ""), node.attrib.get("content-desc", ""))
            )
            if text in label:
                return node
        time.sleep(0.5)
    raise AssertionError(f"Timed out waiting for Android UI text: {text}")


def tap_text(text: str) -> None:
    node = wait_for(text)
    bounds = node.attrib.get("bounds", "")
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if match is None:
        raise AssertionError(f"Missing bounds for {text}: {bounds}")
    left, top, right, bottom = map(int, match.groups())
    adb("shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2))


wait_for("选择学校")
wait_for("测试甲大学")
tap_text("测试乙大学")
tap_text("登录并进入")
wait_for("登录中…")
wait_for("已取消登录")
wait_for("Home")
wait_for("Settings")
wait_for("加载失败")
wait_for("脱敏测试故障")
wait_for("重试")
