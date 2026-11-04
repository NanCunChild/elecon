/** SDK17 execution globals. Compile host scripts with lib: ["ES2022"], not DOM.
 * This is the supported buffered subset, not a complete browser environment.
 * Existing ctx.fetch retains its legacy API; global fetch uses these types.
 */
import type { ScriptContext } from './types.js';

export interface ScriptBusinessError extends Error {
  readonly code: 'script_business_error';
  /** Approved package id followed by ':' and the local code. */
  readonly businessCode: string;
}
export interface EleconContext extends ScriptContext {
  readonly errors: { create(localCode: string): ScriptBusinessError };
}
export type HeadersInit = Headers | Record<string, string> | Iterable<readonly [string, string]>;
export type BodyInit = string | ArrayBuffer | ArrayBufferView;
export interface RequestInit {
  method?: string;
  headers?: HeadersInit;
  body?: BodyInit | null;
  redirect?: 'follow' | 'manual' | 'error';
  signal?: AbortSignal | null;
}
export interface ResponseInit {
  status?: number;
  statusText?: string;
  headers?: HeadersInit;
}
export interface AbortEvent {
  readonly type: 'abort';
  readonly target: AbortSignal;
  readonly currentTarget: AbortSignal;
}
export type AbortListener = ((event: AbortEvent) => void) | { handleEvent(event: AbortEvent): void };

export class Headers implements Iterable<[string, string]> {
  constructor(init?: HeadersInit);
  append(name: string, value: string): void;
  set(name: string, value: string): void;
  delete(name: string): void;
  get(name: string): string | null;
  has(name: string): boolean;
  getSetCookie(): string[];
  entries(): IterableIterator<[string, string]>;
  keys(): IterableIterator<string>;
  values(): IterableIterator<string>;
  [Symbol.iterator](): IterableIterator<[string, string]>;
  forEach(callback: (value: string, key: string, headers: Headers) => void, thisArg?: unknown): void;
}
export class AbortSignal {
  private constructor();
  readonly aborted: boolean;
  readonly reason: unknown;
  onabort: ((event: AbortEvent) => void) | null;
  throwIfAborted(): void;
  addEventListener(type: 'abort', callback: AbortListener | null, options?: boolean | { once?: boolean; capture?: boolean }): void;
  removeEventListener(type: 'abort', callback: AbortListener | null, options?: boolean | { capture?: boolean }): void;
  static abort(reason?: unknown): AbortSignal;
}
export class AbortController {
  constructor();
  readonly signal: AbortSignal;
  abort(reason?: unknown): void;
}
export class Request {
  constructor(input: string | Request, init?: RequestInit);
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly redirect: 'follow' | 'manual' | 'error';
  readonly signal: AbortSignal;
  readonly bodyUsed: boolean;
  bytes(): Promise<Uint8Array>;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
  json(): Promise<unknown>;
  clone(): Request;
}
export class Response {
  constructor(body?: BodyInit | null, init?: ResponseInit);
  readonly status: number;
  readonly statusText: string;
  readonly type: 'default' | 'basic';
  readonly ok: boolean;
  readonly url: string;
  readonly headers: Headers;
  readonly bodyUsed: boolean;
  bytes(): Promise<Uint8Array>;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
  json(): Promise<unknown>;
  clone(): Response;
  static json(data: unknown, init?: ResponseInit): Response;
}
/** Abort prevents delivery, not recall of an already transmitted write. */
export function fetch(input: string | Request, init?: RequestInit): Promise<Response>;

// Opt-in ambient declarations; importing this file adds no runtime dependency.
declare global {
  const elecon: EleconContext;
  const Headers: typeof import('./sdk17.js').Headers;
  type Headers = import('./sdk17.js').Headers;
  const Request: typeof import('./sdk17.js').Request;
  type Request = import('./sdk17.js').Request;
  const Response: typeof import('./sdk17.js').Response;
  type Response = import('./sdk17.js').Response;
  const AbortController: typeof import('./sdk17.js').AbortController;
  type AbortController = import('./sdk17.js').AbortController;
  const AbortSignal: typeof import('./sdk17.js').AbortSignal;
  type AbortSignal = import('./sdk17.js').AbortSignal;
  const fetch: typeof import('./sdk17.js').fetch;
}
