/*! Manual slider wire format adapted from Traintime PDA slider_captcha_client.dart.
 * Copyright 2023-2025 BenderBlog Rodriguez and contributors
 * Copyright 2025 Traintime PDA authors. SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
// 🔒 Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// ADR-034 §3/§5, redlines #1/#3: explicit current-school input, direct IDS only.

// All browser functions are self-contained: the SDK serializes their source.
// WebCrypto provides the same AES-CBC/PKCS7 wire format as PDA; no crypto library
// or new host capability is introduced. Passwords/codes are never persisted.
export async function encryptPda({ text, salt, sliderKey }) {
  const alphabet = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678";
  const random = crypto.getRandomValues(new Uint8Array(80));
  const prefix = sliderKey
    ? Array.from(random, (n) => alphabet[n % alphabet.length]).join("")
    : "xidianscriptsxdu".repeat(5);
  const bytes = new TextEncoder();
  const keyBytes = sliderKey
    ? Uint8Array.from(atob(sliderKey), (char) => char.charCodeAt(0)).slice(-16)
    : bytes.encode(salt);
  if (![16, 24, 32].includes(keyBytes.length)) throw new Error("xidian_ids_salt_invalid");
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-CBC", false, ["encrypt"]);
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-CBC", iv: bytes.encode(prefix.slice(64, 80)) },
    key,
    bytes.encode(prefix.slice(0, 64) + text),
  );
  return btoa(String.fromCharCode(...new Uint8Array(encrypted)));
}

export function preparePdaInput() {
  if (location.origin !== "https://ids.xidian.edu.cn") throw new Error("xidian_input_origin_invalid");
  const random = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(random, (n) => n.toString(16).padStart(2, "0"))
    .join("")
    .toUpperCase();
}

export function renderPdaInput(options) {
  if (location.origin !== "https://ids.xidian.edu.cn") throw new Error("xidian_input_origin_invalid");
  // Isolate input events from the school's existing page handlers. This frame
  // has no script/network content, and cannot submit a browser form.
  document.getElementById("elecon-pda-input")?.remove();
  const frame = document.createElement("iframe");
  frame.id = "elecon-pda-input";
  frame.title = "elecon 西电登录";
  frame.setAttribute("sandbox", "allow-same-origin");
  frame.style.cssText =
    "position:fixed;inset:0;width:100%;height:100%;border:0;z-index:2147483647;background:white";
  document.documentElement.append(frame);
  const doc = frame.contentDocument;
  doc.open();
  doc.write(
    '<!doctype html><html lang="zh"><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body></body></html>',
  );
  doc.close();
  doc.body.style.cssText = "font:16px system-ui;margin:24px;color:#17233a;line-height:1.6";
  const add = (tag, text, parent = doc.body) => {
    const node = doc.createElement(tag);
    if (text) node.textContent = text;
    parent.append(node);
    return node;
  };
  add("h2", "elecon · 西电登录");
  add(
    "p",
    options.message ||
      {
        credentials: "请输入统一身份认证账号和密码。凭据将直接提交给西电 IDS。",
        captcha: "拖动下方滑块，将拼图移到缺口。",
        method: "请选择接收二次认证验证码的方式。",
        code: "请输入收到的验证码。",
      }[options.kind],
  );
  const fields = {};
  const input = (name, label, type = "text", value = "") => {
    const wrapper = add("label", label);
    wrapper.style.display = "block";
    const node = add("input", "", wrapper);
    node.type = type;
    node.name = name;
    node.value = value;
    node.style.cssText =
      "display:block;box-sizing:border-box;width:100%;padding:12px;margin:8px 0 18px;font:inherit";
    fields[name] = node;
    return node;
  };
  let pending = null;
  let submitted = false;
  const finish = (value) => {
    if (submitted) return;
    submitted = true;
    pending = value;
    for (const node of Object.values(fields)) node.value = "";
    doc.body.replaceChildren();
    add("p", "正在验证，请稍候……");
  };
  const button = (text, action) => {
    const node = add("button", text);
    node.type = "button";
    node.style.cssText = "font:inherit;padding:12px;margin:12px 8px 12px 0";
    node.addEventListener("click", action);
  };
  if (options.kind === "credentials") {
    input("username", "账号", "text", options.username || "").autocomplete = "username";
    input("password", "密码", "password").autocomplete = "current-password";
    button("登录", () => {
      const username = fields.username.value.trim();
      const password = fields.password.value;
      if (username && password) finish({ username, password });
    });
  } else if (options.kind === "method") {
    button("发送短信验证码", () => finish({ type: "3" }));
    button("发送企业微信验证码", () => finish({ type: "4" }));
  } else if (options.kind === "code") {
    input("code", "验证码").autocomplete = "one-time-code";
    const trust = input("trust", "信任此设备", "checkbox");
    button("验证", () => {
      const code = fields.code.value.trim();
      if (code) finish({ code, trustDevice: trust.checked });
    });
  } else if (options.kind === "captcha") {
    const picture = add("div");
    picture.style.cssText = "position:relative;width:280px;height:155px;overflow:hidden";
    const big = add("img", "", picture);
    big.alt = "验证码背景";
    big.src = `data:image/png;base64,${options.bigImage}`;
    big.style.cssText = "position:absolute;width:280px;height:155px;left:0;top:0";
    const piece = add("img", "", picture);
    piece.alt = "验证码拼图";
    piece.src = `data:image/png;base64,${options.smallImage}`;
    piece.style.cssText = "position:absolute;width:44px;height:155px;left:0;top:0";
    const slider = add("div", "按住并拖动 →");
    slider.style.cssText =
      "touch-action:none;width:280px;height:48px;line-height:48px;background:#dce9f5;text-align:center;margin-top:16px;user-select:none";
    let start, last, tracks;
    const point = (event) => {
      const now = Date.now();
      const a = Math.max(0, Math.min(240, Math.round(event.clientX - start.x)));
      const b = Math.round(event.clientY - start.y);
      const value = { a, b, c: now - last };
      last = now;
      piece.style.left = `${a}px`;
      return value;
    };
    slider.addEventListener("pointerdown", (event) => {
      slider.setPointerCapture(event.pointerId);
      start = { x: event.clientX, y: event.clientY };
      last = Date.now();
      tracks = [{ a: 0, b: 0, c: 0 }];
    });
    slider.addEventListener("pointermove", (event) => {
      if (!start || Date.now() - last < 20) return;
      if (tracks.length < 500) tracks.push(point(event));
    });
    slider.addEventListener("pointerup", (event) => {
      if (!start) return;
      tracks.push(point(event));
      start = null;
      if (tracks.at(-1).a > 0) finish({ tracks });
    });
    slider.addEventListener("pointercancel", () => {
      start = null;
    });
  }
  button("取消", () => finish({ cancelled: true }));
  // A one-shot closure, not a readable password property on window/document.
  frame.eleconTakeInput = () => {
    const value = pending;
    pending = null;
    return value;
  };
  return true;
}

export async function pollPdaInput() {
  await new Promise((resolve) => setTimeout(resolve, 700));
  if (location.origin !== "https://ids.xidian.edu.cn") throw new Error("xidian_input_origin_invalid");
  return document.getElementById("elecon-pda-input")?.eleconTakeInput?.() ?? null;
}

export function clearPdaInput() {
  document.getElementById("elecon-pda-input")?.remove();
  return true;
}
