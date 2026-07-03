/// Shared test utilities for server-side broker / runtime smoke tests.
///
/// Extract common helpers used across multiple smoke test files:
///   - repoRoot resolution (eliminates 9× duplication of fileURLToPath(new URL(...)))
///   - FakeResolver / FakeTransport test doubles
///   - resp() helper for constructing TransportResponse
///   - readJson / readText helpers
///   - runMain() wrapper for the catch(process.exit) pattern

import { readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";

import type { CredentialResolver, ResolvedCredential } from "../broker/ports.js";
import type { Transport, TransportRequest, TransportResponse } from "../broker/fetch-proxy.js";

// ---------------------------------------------------------------------------
// Repo root resolution
// ---------------------------------------------------------------------------

export function resolveRepoRoot(metaUrl: string): string {
  const startDir = fileURLToPath(new URL(".", metaUrl));
  let dir = startDir.endsWith("/") ? startDir.slice(0, -1) : startDir;
  for (let i = 0; i < 8; i++) {
    try {
      if (statSync(`${dir}/contract`).isDirectory()) return `${dir}/`;
    } catch { /* not found at this level */ }
    const parent = dir.substring(0, dir.lastIndexOf("/"));
    if (parent === dir) break;
    dir = parent;
  }
  return `${startDir}/`;
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

export function readText(path: string): string {
  return readFileSync(path, "utf8");
}

export function readJson<T = unknown>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

// ---------------------------------------------------------------------------
// Test doubles
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
  async get() { return null; },
};

// ---------------------------------------------------------------------------
// Entry-point wrapper
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
