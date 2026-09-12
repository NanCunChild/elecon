/**
 * Response Masker 策略装配（ADR-026 §2.7 / §2.7.1 落地）—— 已验签 bundle 内 `masker.json` 的
 * **运行时严格解析** + firewall ② 步的**规则选取**。与 Dart `client/lib/core/broker/masker_policy.dart`
 * 逐字对齐，行为由 `contract/golden/broker/masker-policy.json` 双端钉死。
 *
 * 职责边界：
 *  - `parseMaskerPolicy`：字节 → 策略对象。形状与 `contract/response-masker.schema.json` 逐字对齐
 *    （多余字段 / 缺字段 / 错枚举一律 fail-closed）。**不**重做 policy⟷manifest 的闭合性校验
 *    （capability / network.allow / credential ref / bind 引用属签发期 validator RM1–RM15，签名已背书）。
 *  - `selectMaskerRules`：按 (capability, method, 最终 URL, requestKey) 选出本次响应适用的规则，
 *    交给纯引擎 `applyResponseMasker`。AND 语义、保持策略序；`handle` 目标**不进引擎**（由 dataflow
 *    `bind` 承接，ADR-026 §3）。
 *
 * 装配纪律（ADR-026 §2.7）：official adapter 加载时 policy / sink / store / host gate 任一缺失即拒载，
 * 空规则不放宽——本模块只提供解析与选取，拒载判定在 loader / sandbox 入口。
 *
 * 🔒 红线 #1 承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import { scopeMatches } from "@elecon/broker-primitives";
import type { MaskerCaptureDecl, MaskerRule } from "./response-masker.js";

export const MAX_MASKER_RULES = 64;

export interface MaskerMatch {
  capability: string;
  requestKey?: string;
  method: "GET" | "POST";
  urlScope: string;
}

/** 一条带 `match` 的策略规则；`capture.source` 缺省表示 handle 目标（不进引擎）。 */
export interface MaskerPolicyRule {
  id: string;
  match: MaskerMatch;
  capture: MaskerCaptureDecl | { destination: { kind: "handle"; ref: string } };
  project: "delete" | "replace";
}

export interface MaskerPolicy {
  schemaVersion: 1;
  rules: MaskerPolicyRule[];
}

export class MaskerPolicyError extends Error {
  constructor(
    readonly code: "policy_bad_json" | "policy_bad_shape" | "policy_duplicate_rule_id",
    message: string,
  ) {
    super(message);
    this.name = "MaskerPolicyError";
  }
}

const RE_RULE_ID = /^[a-z][a-z0-9-]{0,63}$/;
const RE_HEADER_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const RE_CREDENTIAL_REF = /^[a-z][a-z0-9-]*$/;
const RE_HANDLE_REF = /^[a-z][a-z0-9_]{0,31}$/;

function bad(message: string): never {
  throw new MaskerPolicyError("policy_bad_shape", message);
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function assertKeys(o: Record<string, unknown>, allowed: readonly string[], where: string): void {
  for (const k of Object.keys(o)) {
    if (!allowed.includes(k)) bad(`${where} 含未知字段 ${JSON.stringify(k)}`);
  }
}

function requireString(
  o: Record<string, unknown>,
  key: string,
  where: string,
  min = 1,
  max = Infinity,
): string {
  const v = o[key];
  if (typeof v !== "string") bad(`${where}.${key} 缺失或非字符串`);
  if (v.length < min || v.length > max) bad(`${where}.${key} 长度越界`);
  return v;
}

function parseMatch(raw: unknown, where: string): MaskerMatch {
  if (!isPlainObject(raw)) bad(`${where} 非对象`);
  assertKeys(raw, ["capability", "requestKey", "method", "urlScope"], where);
  const capability = requireString(raw, "capability", where, 1, 128);
  const method = requireString(raw, "method", where);
  if (method !== "GET" && method !== "POST") bad(`${where}.method 只允许 GET | POST`);
  const urlScope = requireString(raw, "urlScope", where, 1, 2048);
  const match: MaskerMatch = { capability, method, urlScope };
  if (raw.requestKey !== undefined) {
    match.requestKey = requireString(raw, "requestKey", where, 1, 64);
  }
  return match;
}

function parseDestination(
  raw: unknown,
  where: string,
): { kind: "credential" | "redact" | "handle"; ref?: string } {
  if (!isPlainObject(raw)) bad(`${where} 非对象`);
  const kind = raw.kind;
  if (kind === "credential") {
    assertKeys(raw, ["kind", "ref"], where);
    const ref = requireString(raw, "ref", where, 1, 64);
    if (!RE_CREDENTIAL_REF.test(ref)) bad(`${where}.ref 不合 credential ref 模式`);
    return { kind, ref };
  }
  if (kind === "redact") {
    assertKeys(raw, ["kind"], where);
    return { kind };
  }
  if (kind === "handle") {
    assertKeys(raw, ["kind", "ref"], where);
    const ref = requireString(raw, "ref", where);
    if (!RE_HANDLE_REF.test(ref)) bad(`${where}.ref 不合 handle ref 模式`);
    return { kind, ref };
  }
  return bad(`${where}.kind 只允许 credential | redact | handle`);
}

function parseCapture(raw: unknown, where: string): MaskerPolicyRule["capture"] {
  if (!isPlainObject(raw)) bad(`${where} 非对象`);
  if (raw.exactly !== 1) bad(`${where}.exactly 必须为 1`);
  const destination = parseDestination(raw.destination, `${where}.destination`);

  if (raw.source === undefined) {
    // handleCapture：只允许 exactly + destination(kind=handle)。
    assertKeys(raw, ["exactly", "destination"], where);
    if (destination.kind !== "handle") bad(`${where} 无 source 时 destination 只能是 handle`);
    return { destination: { kind: "handle", ref: destination.ref ?? "" } };
  }
  if (destination.kind === "handle") bad(`${where} handle 目标不得声明 source`);

  if (raw.source === "header") {
    assertKeys(raw, ["source", "name", "exactly", "destination"], where);
    const name = requireString(raw, "name", where);
    if (!RE_HEADER_NAME.test(name)) bad(`${where}.name 不合响应头名模式`);
    return destination.kind === "credential"
      ? { source: "header", name, destination: { kind: "credential", ref: destination.ref ?? "" } }
      : { source: "header", name, destination: { kind: "redact" } };
  }
  if (raw.source === "json") {
    assertKeys(raw, ["source", "path", "exactly", "destination"], where);
    const path = requireString(raw, "path", where, 1, 512);
    return destination.kind === "credential"
      ? { source: "json", path, destination: { kind: "credential", ref: destination.ref ?? "" } }
      : { source: "json", path, destination: { kind: "redact" } };
  }
  return bad(`${where}.source 只允许 header | json（或缺省 = handle）`);
}

function parseRule(raw: unknown, where: string): MaskerPolicyRule {
  if (!isPlainObject(raw)) bad(`${where} 非对象`);
  assertKeys(raw, ["id", "match", "capture", "project"], where);
  const id = requireString(raw, "id", where);
  if (!RE_RULE_ID.test(id)) bad(`${where}.id 不合规则 id 模式`);
  const match = parseMatch(raw.match, `${where}.match`);
  const capture = parseCapture(raw.capture, `${where}.capture`);
  const project = requireString(raw, "project", where);
  if (project !== "delete" && project !== "replace") bad(`${where}.project 只允许 delete | replace`);
  return { id, match, capture, project };
}

/**
 * 严格解析 `masker.json` 文本。**只在验签之后**对签名覆盖的字节调用（字节来自 blob 表，
 * digest 已证明其确属 `masker.json`，P0-01）。任何形状偏差 → {@link MaskerPolicyError}。
 */
export function parseMaskerPolicy(text: string): MaskerPolicy {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (err) {
    throw new MaskerPolicyError("policy_bad_json", `masker.json 不是合法 JSON：${(err as Error).message}`);
  }
  if (!isPlainObject(raw)) bad("masker.json 顶层非对象");
  assertKeys(raw, ["schemaVersion", "rules"], "masker.json");
  if (raw.schemaVersion !== 1) bad("masker.json.schemaVersion 必须为 1");
  if (!Array.isArray(raw.rules)) bad("masker.json.rules 缺失或非数组");
  if (raw.rules.length > MAX_MASKER_RULES) bad(`masker.json.rules 超过 ${MAX_MASKER_RULES} 条上限`);
  const rules = raw.rules.map((r, i) => parseRule(r, `rules[${i}]`));
  const seen = new Set<string>();
  for (const rule of rules) {
    if (seen.has(rule.id)) {
      throw new MaskerPolicyError("policy_duplicate_rule_id", `masker.json 规则 id '${rule.id}' 重复`);
    }
    seen.add(rule.id);
  }
  return { schemaVersion: 1, rules };
}

export interface MaskerSelectContext {
  /** 本次执行的 capability id（manifest 权威能力集内）。 */
  capability: string;
  /** 最终响应所属请求的方法（重定向后最后一跳）。大小写不敏感。 */
  method: string;
  /** 最终响应 URL（重定向后最后一跳，含 query）。 */
  finalUrl: string;
  /** declarative 逻辑请求 key；imperative `ctx.fetch` 无 key（带 requestKey 的规则永不命中）。 */
  requestKey?: string;
}

/**
 * firewall ② 步：选出本次响应适用的引擎规则（AND：capability = 、method = 、urlScope ∋ finalUrl、
 * requestKey 若声明则须相等）。保持策略序；`handle` 目标不进引擎。
 */
export function selectMaskerRules(policy: MaskerPolicy, ctx: MaskerSelectContext): MaskerRule[] {
  const method = ctx.method.toUpperCase();
  const out: MaskerRule[] = [];
  for (const rule of policy.rules) {
    if (rule.match.capability !== ctx.capability) continue;
    if (rule.match.method !== method) continue;
    if (rule.match.requestKey !== undefined && rule.match.requestKey !== ctx.requestKey) continue;
    if (!scopeMatches(ctx.finalUrl, rule.match.urlScope)) continue;
    if (!("source" in rule.capture)) continue; // handle 目标：dataflow bind 承接
    out.push({ id: rule.id, capture: rule.capture, project: rule.project });
  }
  return out;
}
