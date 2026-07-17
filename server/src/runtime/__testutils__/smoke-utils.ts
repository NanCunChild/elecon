/**
 * 服务端 broker / runtime smoke 测试的共享工具。
 *
 * 收敛多个 smoke 测试文件里重复的辅助逻辑：
 *   - repoRoot 解析（消除 9× 重复的 `fileURLToPath(new URL(...))`）
 *   - FakeResolver / FakeTransport 测试替身
 *   - 构造 TransportResponse 的 resp() 辅助
 *   - readJson / readText 辅助
 *   - 封装 catch(process.exit) 模式的 runMain()
 */

import { readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Transport, TransportRequest, TransportResponse } from "../broker/fetch-proxy.js";
import type { CredentialResolver, ResolvedCredential } from "../broker/ports.js";

// ---------------------------------------------------------------------------
// 仓库根解析
// ---------------------------------------------------------------------------

export function resolveRepoRoot(metaUrl: string): string {
  const startDir = fileURLToPath(new URL(".", metaUrl));
  let dir = startDir.endsWith("/") ? startDir.slice(0, -1) : startDir;
  for (let i = 0; i < 8; i++) {
    try {
      if (statSync(`${dir}/contract`).isDirectory()) return `${dir}/`;
    } catch {
      /* 本层未找到，继续向上 */
    }
    const parent = dir.substring(0, dir.lastIndexOf("/"));
    if (parent === dir) break;
    dir = parent;
  }
  return `${startDir}/`;
}

// ---------------------------------------------------------------------------
// 文件辅助
// ---------------------------------------------------------------------------

export function readText(path: string): string {
  return readFileSync(path, "utf8");
}

export function readJson<T = unknown>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

// ---------------------------------------------------------------------------
// 测试替身
// ---------------------------------------------------------------------------

export class FakeResolver implements CredentialResolver {
  constructor(private readonly map: Record<string, ResolvedCredential>) {}
  async get(ref: string): Promise<ResolvedCredential | null> {
    return this.map[ref] ?? null;
  }
}

export class FakeTransport implements Transport {
  readonly seen: TransportRequest[] = [];
  constructor(private readonly queue: TransportResponse[]) {}
  async fetch(req: TransportRequest): Promise<TransportResponse> {
    this.seen.push(req);
    const r = this.queue.shift();
    if (!r) throw new Error("FakeTransport queue exhausted");
    return r;
  }
}

export function resp(partial: Partial<TransportResponse> & { status: number }): TransportResponse {
  return { headers: {}, setCookie: [], location: null, ...partial };
}

export const noResolver: CredentialResolver = {
  async get() {
    return null;
  },
};

// ---------------------------------------------------------------------------
// 入口封装
// ---------------------------------------------------------------------------

export function runMain(fn: () => void | Promise<void>): void {
  try {
    const result = fn();
    if (result instanceof Promise) {
      result.catch((err: unknown) => {
        console.error(err);
        process.exit(1);
      });
    }
  } catch (err) {
    console.error(err);
    process.exit(1);
  }
}
