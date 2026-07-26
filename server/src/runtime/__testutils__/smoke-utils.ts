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
// 兄弟仓 elecon-adapters（ADR-018 adapter 分离）
// ---------------------------------------------------------------------------

/**
 * 公开 adapter 兄弟仓根。解析优先级：`ELECON_ADAPTERS_REPO`（可覆盖）→ 子模块
 * `vendor/elecon-adapters`（core CI 拉子模块后即在此）→ 并排检出 `../elecon-adapters`（本地/兄弟仓 CI）。
 * 返回首个存在 `adapters/` 的候选；均无则返回并排检出路径（由 [adapterDirIfPresent] skip-if-absent 承接）。
 */
export function adaptersRepoRoot(repoRoot: string): string {
  const env = process.env.ELECON_ADAPTERS_REPO;
  const sibling = `${repoRoot}../elecon-adapters`;
  const candidates = [...(env ? [env] : []), `${repoRoot}vendor/elecon-adapters`, sibling].map((p) =>
    p.replace(/\/$/, ""),
  );
  for (const base of candidates) {
    try {
      if (statSync(`${base}/adapters`).isDirectory()) return base;
    } catch {
      /* 下一个候选 */
    }
  }
  return sibling.replace(/\/$/, "");
}

/**
 * 返回某 adapter 的目录；兄弟仓或其 `index.js` 缺失时返回 null。
 *
 * 供依赖公开 adapter 源的 smoke「缺仓即跳过」：adapter 已按 ADR-018 迁至独立仓，
 * 本仓 CI 不检出兄弟仓 → 缺失即跳过而非 ENOENT 硬失败（本地 / adapters 仓 CI 仍完整跑）。
 */
export function adapterDirIfPresent(
  repoRoot: string,
  adapterId: string,
  requireAdapters = process.env.ELECON_REQUIRE_ADAPTERS === "1",
): string | null {
  const dir = `${adaptersRepoRoot(repoRoot)}/adapters/${adapterId}`;
  try {
    if (statSync(`${dir}/index.js`).isFile()) return dir;
  } catch {
    /* 缺兄弟仓或缺该 adapter */
  }
  if (requireAdapters) {
    throw new Error(
      `缺必需 adapter '${adapterId}'：请检出 vendor/elecon-adapters submodule 或设置 ELECON_ADAPTERS_REPO`,
    );
  }
  return null;
}

/** smoke 跳过提示（run-smokes 以 exit 0 判通过；跳过须显式打印，以免被误读为「跑过」）。 */
export function skipSmoke(reason: string): void {
  console.log(`  ⊘ SKIP：${reason}`);
}

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
