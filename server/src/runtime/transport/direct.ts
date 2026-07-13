/**
 * `direct` 档传输（Gate A · ADR-003 §2.2，服务端镜像）—— OS 网络栈直连、无隧道、不终止 TLS。
 *
 * 填 broker 的 `Transport` seam（`fetch-proxy.ts`）：把**已注入凭证的真实请求**
 * （ADR-009 §2.1 第 3 步，凭证由 broker 在 HTTP 语义层注入）送达 origin 并回传字节。
 * transport **只搬字节**——不解析、不碰 schema、不持凭证语义（ADR-003 §2.1）。
 * 与客户端 `client/lib/core/transport/direct.dart` 语义对称。
 *
 * 关键约束（同 Dart 端）：
 *  - **单跳**：`redirect: "manual"`——重定向由核心（B3 `decideRedirect`）逐跳跟随、每跳重做
 *    注入决策 + 校验 allow + 捕获 Set-Cookie；transport 绝不自动跟随（否则中间 `Location`/
 *    Set-Cookie 绕过核心，破红线 #1）。
 *  - **不终止 / 不 MITM TLS**（ADR-003 §2.3）：用 OS/undici TLS 栈正常握手到 origin，**不**关
 *    证书校验、不注入根证书（ADR-009：禁 verify=False）。
 *  - **暴露原始 Set-Cookie / Location**：交回宿主 jar（B4）与重定向逻辑（B3）；响应脱敏
 *    （B2 allowlist）由 broker 在交回 adapter 前完成，不在 transport。
 *
 * 运行环境：服务端 campus / public 缓存填充路径（红线 #2：public 不持凭证、不执行 adapter；
 * 本 transport 用于 campus 授权中继代取或 public 缓存公开数据）。Node ≥20 的全局 `fetch`（undici）。
 *
 * 🔒 承载注入凭证的真实请求（红线 #1/#4 路径，最低信任档但仍在凭证路径）：
 * AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import {
  type Transport,
  TransportBodyLimitExceeded,
  type TransportRequest,
  type TransportResponse,
} from "../broker/fetch-proxy.js";
import type { HeaderMap } from "../broker/header-sanitize.js";

export const DEFAULT_MAX_BODY_BYTES = 8 * 1024 * 1024;

export class DirectTransport implements Transport {
  constructor(private readonly maxBodyBytes = DEFAULT_MAX_BODY_BYTES) {}

  async fetch(req: TransportRequest, signal?: AbortSignal): Promise<TransportResponse> {
    const init: RequestInit = {
      method: req.method,
      headers: req.headers,
      // 单跳：核心自跟随重定向（B3），transport 不自动跟随。
      redirect: "manual",
    };
    if (signal !== undefined) init.signal = signal;
    if (req.body !== undefined) init.body = req.body;

    const resp = await fetch(req.url, init);

    // 原始 Set-Cookie（多条）单独交回——由 B4 jar 捕获，绝不并入普通头、绝不交 adapter。
    const setCookie = resp.headers.getSetCookie();
    const headers: HeaderMap = {};
    resp.headers.forEach((value, name) => {
      if (name.toLowerCase() === "set-cookie") return; // 单独给（forEach 可能折叠多条）
      headers[name] = value;
    });

    // body：undici text() 按 UTF-8。**已知限制**：非 UTF-8（如 GBK）页面会乱码，待后续按
    // Content-Type charset 解码（多数 .do/JSON 端点为 UTF-8）。
    const body = await readBodyLimited(resp, this.maxBodyBytes);

    return {
      status: resp.status,
      headers,
      setCookie,
      location: resp.headers.get("location"),
      body,
    };
  }
}

async function readBodyLimited(resp: Response, maxBytes: number): Promise<string> {
  const declared = resp.headers.get("content-length");
  if (declared !== null && Number(declared) > maxBytes) {
    await resp.body?.cancel();
    throw new TransportBodyLimitExceeded(maxBytes);
  }

  if (!resp.body) return "";
  const reader = resp.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new TransportBodyLimitExceeded(maxBytes);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return new TextDecoder().decode(Buffer.concat(chunks));
}
