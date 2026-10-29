/** Trusted school script SDK 1/2 (ADR-034/035). Values include actual secrets.
 * SDK2 defaults namespace to stable scriptId; namespace is not an access grant.
 */
export interface CredentialAddress {
  /** SDK2: defaults to scriptId. @legacy/@preview1 are explicit migration sources. */
  namespace?: string;
}
export interface CredentialRecord {
  /** Stable qualified identity; legacy ids include schoolId even when their stored ref is bare. */
  id: string;
  namespace: string;
  key: string;
  value: string;
  type: "token" | "cookie" | "header" | "query" | "password";
  scope: string[];
  expiresAt: number | null;
  expired: boolean;
}
export interface CredentialOptions extends CredentialAddress {
  type?: CredentialRecord["type"];
  /** Unix epoch milliseconds. Omit to preserve, null to clear. */
  expiresAt?: number | null;
  scope?: string[];
}
export interface ScriptResponse {
  readonly status: number;
  readonly ok: boolean;
  readonly url: string;
  readonly headers: {
    get(name: string): string | null;
    getSetCookie(): string[];
    raw(): Record<string, string[]>;
  };
  /** UTF-8/ASCII and explicit Latin-1; other encodings reject with unsupported_encoding. */
  text(): Promise<string>;
  /** Raw bytes allow adapter-owned legacy encoding decoders. */
  bytes(): Promise<Uint8Array>;
  arrayBuffer(): Promise<ArrayBuffer>;
  json(): Promise<unknown>;
}
export interface ScriptBrowser {
  open(url: string): Promise<unknown>;
  evaluate(source: string | ((...args: unknown[]) => unknown), ...args: unknown[]): Promise<unknown>;
  text(selector: string): Promise<string | null>;
  exists(selector: string): Promise<boolean>;
  queryAll(selector: string, limit?: number): Promise<unknown[]>;
  waitFor(selector: string, timeout?: number): Promise<boolean>;
  cookies(url?: string): Promise<unknown[]>;
  /** Restore saved cookies for an explicitly allowed URL. */
  setCookies(url: string, cookies: Array<{
    name: string;
    value: string;
    domain?: string;
    path?: string;
    expiresDate?: number;
    isSecure?: boolean;
    isHttpOnly?: boolean;
    sameSite?: 'Lax' | 'Strict' | 'None';
  }>): Promise<void>;
}
export interface ScriptContext {
  /** Current authorized school only; revoked sessions are unavailable.
   * SDK2 list retains every namespace; get(record.key,{namespace:record.namespace}) round-trips.
   * set/delete resolve after in-memory acceptance; the host awaits storage at run end.
   */
  readonly credentials: {
    get(key: string, address?: CredentialAddress): Promise<CredentialRecord | null>;
    list(): Promise<CredentialRecord[]>;
    set(key: string, value: string, options?: CredentialOptions): Promise<void>;
    delete(key: string, address?: CredentialAddress): Promise<void>;
  };
  fetch(url: string, init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    redirect?: "manual" | "follow" | "error";
  }): Promise<ScriptResponse>;
  /** Present only when browser=true; host platform limitations still apply. */
  readonly browser?: ScriptBrowser;
  now(): number;
  log(level: "debug" | "info" | "warn" | "error", message: string): void;
}
export type CapabilityHandler = (ctx: ScriptContext, params: Record<string, unknown>) => Promise<unknown>;
export interface CapabilityModule {
  capabilities: Record<string, CapabilityHandler>;
}
