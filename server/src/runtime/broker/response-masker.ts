/**
 * 响应凭证收割与投影引擎（ADR-026 §2.8 / 工程说明 §6）—— **TS 参考实现**。
 *
 * 角色：与客户端 Dart 生产实现（`client/lib/core/broker/response_masker.dart`）**逐字节对称**，
 * 两端照同一 golden（`contract/golden/broker/response-masker.json`）双跑，钉死跨端一致
 * （ADR-001 §8）。本文件只实现 ADR-026 交付事务里的两段**纯函数**：
 *
 *   Capture（收割）：从**脱敏前**响应按规则提取一个凭证敏感标量值。
 *   Project（投影）：从交给 adapter 的响应里删除/替换命中值，并清理失效实体元数据。
 *
 * 不含 Commit（Credential Store / opaque handle 事务）、delivery firewall 接线、host/version
 * gate——那些是后续阶段（工程说明 §9.2 step 4/5），须人工主导。本引擎假定规则**已过组合
 * 校验**（`tools/src/validator/response-masker.ts`），只保留**运行期 fail-closed**（§2.5）。
 *
 * 🔒 红线 #1（凭证敏感值不进 adapter）+ 承重路径：AI 起草，须人工 + 安全清单复核，
 *    不得 AI 独自闭环（AGENTS.md §1 / ADR-026 §6）。错误只进宿主诊断，绝不含原值 / 命中片段。
 *
 * JSON 投影用**按位剪接**而非「解析→改树→重序列化」：只替换命中标量的源码区间，其余字节原样
 * 保留。重序列化会在数字 / 浮点 / 转义上引入 JS↔Dart 漂移（dataflow 对超安全整数 fail-closed
 * 即此因），剪接从根上回避（§2.8「具体字节由共享 golden 钉死」）。
 */

// ---- 常量（两端必须一致）----

/** body 命中值的核心固定 sentinel（ADR-026 §2.8 / 工程说明 §6）。 */
export const MASKER_SENTINEL = "__ELECON_MASKED__";
/** JSON 投影写入的 sentinel 字面量（合法 JSON 字符串，剪接后仍是合法 JSON）。 */
const SENTINEL_JSON = JSON.stringify(MASKER_SENTINEL);

/** body 改写后须删除的实体元数据头（小写，大小写不敏感匹配）。Content-Type 保留供 adapter 解析。 */
const STRIPPED_ENTITY_HEADERS = new Set(["content-length", "content-encoding", "etag"]);

/** header 提取输入上限（对齐 dataflow MAX_HEADER_INPUT_BYTES）。 */
export const MAX_HEADER_INPUT_BYTES = 4 * 1024;
/** body 提取输入上限（对齐 dataflow MAX_BODY_INPUT_BYTES）。 */
export const MAX_BODY_INPUT_BYTES = 8 * 1024 * 1024;
/** 单次收割值上限（对齐 dataflow MAX_HANDLE_BYTES）。 */
export const MAX_CAPTURE_VALUE_BYTES = 64 * 1024;

// ---- 类型 ----

/** 脱敏**前**的响应（Capture 读它）。 */
export interface MaskerRawResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

/** 单条规则的 capture 声明（引擎只用 header / json 源；handle 源由 dataflow bind 承接）。 */
export interface MaskerCaptureDecl {
  source: "header" | "json";
  name?: string;
  path?: string;
  destination: { kind: "credential" | "redact"; ref?: string };
}

/** 引擎可执行的 Masker 规则（`match` 由 firewall 判定，不在纯引擎内）。 */
export interface MaskerRule {
  id: string;
  capture: MaskerCaptureDecl;
  project: "delete" | "replace";
}

/** 一个待托管到 Credential Store 的收割值（kind=credential 才产出；redact 只投影）。 */
export interface CapturedCredential {
  ruleId: string;
  ref: string;
  value: string;
}

/** 交付事务纯函数部分的产出：待提交凭证 + 投影后响应。 */
export interface MaskerOutcome {
  captured: CapturedCredential[];
  projected: MaskerRawResponse;
}

/** Masker 执行期错误。整条 capability fail-closed；🔒 错误只进宿主日志，绝不回流 adapter。 */
export class MaskerError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "MaskerError";
  }
}

const utf8 = new TextEncoder();
function utf8Len(s: string): number {
  return utf8.encode(s).length;
}

/** 单次收割值上限检查，超出 fail-closed。 */
function capValue(value: string): string {
  if (utf8Len(value) > MAX_CAPTURE_VALUE_BYTES) {
    throw new MaskerError("capture_value_too_large", `收割值超过单值上限 ${MAX_CAPTURE_VALUE_BYTES} 字节`);
  }
  return value;
}

// ═══════════════════════════════════════════════════════════════════════════
// Capture ①：header 源。大小写不敏感固定头名，须恰 1 命中（schema exactly:1）。
// ═══════════════════════════════════════════════════════════════════════════

/** 从**脱敏前**响应头收割一个值。0 命中 / 多命中 / 超限一律 fail-closed（§2.5）。 */
export function captureHeader(name: string, raw: MaskerRawResponse): string {
  const wanted = name.toLowerCase();
  const matches: string[] = [];
  for (const [key, value] of Object.entries(raw.headers)) {
    if (key.toLowerCase() === wanted) {
      if (utf8Len(value) > MAX_HEADER_INPUT_BYTES) {
        throw new MaskerError("capture_input_too_large", `响应头超过 ${MAX_HEADER_INPUT_BYTES} 字节`);
      }
      matches.push(value);
    }
  }
  if (matches.length === 0) {
    throw new MaskerError("capture_not_found", "响应头不存在");
  }
  if (matches.length > 1) {
    throw new MaskerError("capture_ambiguous", `响应头出现 ${matches.length} 次（须恰 1）`);
  }
  return capValue(matches[0]!);
}

// ═══════════════════════════════════════════════════════════════════════════
// Capture ②：json 源。封闭 JSONPath 定位单标量；剪接同一定位器，capture / project 一致。
// ═══════════════════════════════════════════════════════════════════════════

/** 从**脱敏前**响应体 JSON 收割一个标量值（字符串反转义；数字 / 布尔取源码字面量）。 */
export function captureJson(path: string, raw: MaskerRawResponse): string {
  assertBodyWithinLimit(raw.body);
  assertJson(raw.body);
  const tokens = tokenizeJsonPath(path);
  if (tokens === null) {
    throw new MaskerError("capture_bad_jsonpath", `不支持的 jsonpath 语法：'${path}'`);
  }
  const span = locateJsonSpan(raw.body, tokens);
  return capValue(spanScalarValue(raw.body, span.start, span.end));
}

function assertBodyWithinLimit(body: string): void {
  if (utf8Len(body) > MAX_BODY_INPUT_BYTES) {
    throw new MaskerError("capture_input_too_large", `响应体超过 ${MAX_BODY_INPUT_BYTES} 字节`);
  }
}

/**
 * 全量 JSON 合法性校验（与 dataflow「先 JSON.parse 再抽取」同口径）。只用于产出 not_json
 * 信号并确保剪接器面对合法 JSON；**不**用其重序列化（回避跨端漂移）。
 */
function assertJson(body: string): void {
  try {
    JSON.parse(body);
  } catch {
    throw new MaskerError("capture_not_json", "响应体非 JSON");
  }
}

/** 与 ADR-023 runtime 同语义的封闭 JSONPath 子集：`$`、`.key`、`['key']`、`["key"]`、`[n]`。 */
function tokenizeJsonPath(path: string): Array<string | number> | null {
  if (!path.startsWith("$")) return null;
  const out: Array<string | number> = [];
  let i = 1;
  while (i < path.length) {
    const c = path[i];
    if (c === ".") {
      i++;
      let key = "";
      while (i < path.length && /[A-Za-z0-9_]/.test(path[i]!)) key += path[i++];
      if (key === "") return null;
      out.push(key);
    } else if (c === "[") {
      const close = path.indexOf("]", i);
      if (close === -1) return null;
      const inner = path.slice(i + 1, close).trim();
      if (/^\d+$/.test(inner)) {
        out.push(Number(inner));
      } else if (/^'[^']*'$/.test(inner) || /^"[^"]*"$/.test(inner)) {
        out.push(inner.slice(1, -1));
      } else {
        return null;
      }
      i = close + 1;
    } else {
      return null;
    }
  }
  return out;
}

interface JsonSpan {
  start: number;
  end: number;
}

const WS = new Set([" ", "\t", "\n", "\r"]);
function skipWs(s: string, i: number): number {
  while (i < s.length && WS.has(s[i]!)) i++;
  return i;
}

/** 扫过 s[i] 起的一个 JSON 字符串，返回收尾引号后一位。s[i] 须为 `"`。 */
function scanString(s: string, i: number): number {
  let j = i + 1;
  while (j < s.length) {
    const ch = s[j]!;
    if (ch === "\\") {
      j += 2;
      continue;
    }
    if (ch === '"') return j + 1;
    j++;
  }
  throw new MaskerError("capture_not_json", "未终止的 JSON 字符串");
}

/** 扫过 s[i] 起的一个字面量（number / true / false / null），至分隔符或空白止。 */
function scanLiteral(s: string, i: number): number {
  let j = i;
  while (j < s.length) {
    const ch = s[j]!;
    if (ch === "," || ch === "]" || ch === "}" || WS.has(ch)) break;
    j++;
  }
  if (j === i) throw new MaskerError("capture_not_json", "空标量");
  return j;
}

/** 扫过 s[i] 起的一个完整 JSON 值，返回其后一位。用于跳过无关兄弟或求标量区间。 */
function scanValue(s: string, i: number): number {
  const ch = s[i];
  if (ch === undefined) throw new MaskerError("capture_not_json", "值缺失");
  if (ch === '"') return scanString(s, i);
  if (ch === "{" || ch === "[") return scanContainer(s, i);
  return scanLiteral(s, i);
}

/** 跳过一个对象 / 数组，尊重字符串内的括号。返回闭括号后一位。 */
function scanContainer(s: string, i: number): number {
  let depth = 0;
  let j = i;
  while (j < s.length) {
    const ch = s[j]!;
    if (ch === '"') {
      j = scanString(s, j);
      continue;
    }
    if (ch === "{" || ch === "[") depth++;
    else if (ch === "}" || ch === "]") {
      depth--;
      if (depth === 0) return j + 1;
    }
    j++;
  }
  throw new MaskerError("capture_not_json", "未闭合的 JSON 容器");
}

/**
 * 沿封闭路径定位命中标量的源码区间。假定 body 已过 [assertJson]。不支持通配 / 递归，故命中
 * 至多一个位置——「exactly:1」由「找到即唯一」自然满足（缺失 → capture_not_found）。
 */
function locateJsonSpan(body: string, tokens: Array<string | number>): JsonSpan {
  return navigate(body, skipWs(body, 0), tokens, 0);
}

function navigate(s: string, at: number, tokens: Array<string | number>, depth: number): JsonSpan {
  let i = skipWs(s, at);
  if (depth === tokens.length) {
    return { start: i, end: scanValue(s, i) };
  }
  const tok = tokens[depth]!;
  if (typeof tok === "string") {
    if (s[i] !== "{") throw new MaskerError("capture_not_found", "路径期望对象");
    i = skipWs(s, i + 1);
    if (s[i] === "}") throw new MaskerError("capture_not_found", "键不存在");
    for (;;) {
      if (s[i] !== '"') throw new MaskerError("capture_not_json", "对象键非字符串");
      const keyEnd = scanString(s, i);
      const key = parseJsonStringToken(s.slice(i, keyEnd));
      i = skipWs(s, keyEnd);
      if (s[i] !== ":") throw new MaskerError("capture_not_json", "对象键后缺 ':'");
      i = skipWs(s, i + 1);
      if (key === tok) return navigate(s, i, tokens, depth + 1);
      i = skipWs(s, scanValue(s, i));
      if (s[i] === ",") {
        i = skipWs(s, i + 1);
        continue;
      }
      if (s[i] === "}") throw new MaskerError("capture_not_found", "键不存在");
      throw new MaskerError("capture_not_json", "对象格式错误");
    }
  }
  if (s[i] !== "[") throw new MaskerError("capture_not_found", "路径期望数组");
  i = skipWs(s, i + 1);
  if (s[i] === "]") throw new MaskerError("capture_not_found", "数组下标越界");
  let idx = 0;
  for (;;) {
    if (idx === tok) return navigate(s, i, tokens, depth + 1);
    i = skipWs(s, scanValue(s, i));
    if (s[i] === ",") {
      i = skipWs(s, i + 1);
      idx++;
      continue;
    }
    if (s[i] === "]") throw new MaskerError("capture_not_found", "数组下标越界");
    throw new MaskerError("capture_not_json", "数组格式错误");
  }
}

/** 把命中区间解释为标量文本：字符串反转义；数字 / 布尔取源码字面量；对象 / 数组 / null fail-closed。 */
function spanScalarValue(s: string, start: number, end: number): string {
  const first = s[start]!;
  if (first === "{" || first === "[") throw new MaskerError("capture_not_scalar", "命中值为对象 / 数组");
  if (first === '"') return parseJsonStringToken(s.slice(start, end));
  const raw = s.slice(start, end);
  if (raw === "null") throw new MaskerError("capture_not_scalar", "命中值为 null");
  return raw;
}

/** 反转义单个 JSON 字符串 token（含引号）。非法转义 fail-closed。 */
function parseJsonStringToken(token: string): string {
  try {
    return JSON.parse(token) as string;
  } catch {
    throw new MaskerError("capture_not_json", "JSON 字符串 token 解析失败");
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Project：删除命中头、按位剪接 body 命中标量为 sentinel、清理失效实体元数据。
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 构造 adapter-visible 投影响应。header 源规则删除整头；json 源规则把命中标量剪接为固定
 * sentinel。任一命中缺失 / 越界 / 非标量一律 fail-closed（与 Capture 同口径，纵深防御）。
 * body 被改写后删除 Content-Length / Content-Encoding / ETag（失效实体元数据）。
 */
export function projectResponse(rules: MaskerRule[], raw: MaskerRawResponse): MaskerRawResponse {
  const deleteHeaders = new Set<string>();
  const jsonPaths: string[] = [];
  for (const rule of rules) {
    if (rule.capture.source === "header") {
      // 复核命中存在性 / 基数（与 Capture 同口径）后再登记删除。
      captureHeader(rule.capture.name ?? "", raw);
      deleteHeaders.add((rule.capture.name ?? "").toLowerCase());
    } else if (rule.capture.source === "json") {
      jsonPaths.push(rule.capture.path ?? "");
    } else {
      throw new MaskerError("capture_bad_source", `未知 capture 源 '${rule.capture.source}'`);
    }
  }

  let headers = filterHeaders(raw.headers, deleteHeaders);

  let body = raw.body;
  if (jsonPaths.length > 0) {
    assertBodyWithinLimit(raw.body);
    assertJson(raw.body);
    body = spliceSentinels(raw.body, jsonPaths);
    headers = stripEntityHeaders(headers);
  }

  return { status: raw.status, headers, body };
}

/** 剪接：把每条 json 路径命中的标量区间替换为 sentinel。区间在**原始 body**上计算后由右向左应用。 */
function spliceSentinels(body: string, jsonPaths: string[]): string {
  const spans = jsonPaths.map((path) => {
    const tokens = tokenizeJsonPath(path);
    if (tokens === null) throw new MaskerError("capture_bad_jsonpath", `不支持的 jsonpath 语法：'${path}'`);
    const span = locateJsonSpan(body, tokens);
    spanScalarValue(body, span.start, span.end); // 复核标量（非标量 fail-closed）
    return span;
  });
  spans.sort((a, b) => a.start - b.start);
  for (let k = 1; k < spans.length; k++) {
    if (spans[k]!.start < spans[k - 1]!.end) {
      throw new MaskerError("project_overlap", "两条 json 规则命中区间重叠");
    }
  }
  let out = body;
  for (let k = spans.length - 1; k >= 0; k--) {
    const span = spans[k]!;
    out = out.slice(0, span.start) + SENTINEL_JSON + out.slice(span.end);
  }
  return out;
}

function filterHeaders(headers: Record<string, string>, deleteLower: Set<string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers)) {
    if (!deleteLower.has(key.toLowerCase())) out[key] = value;
  }
  return out;
}

function stripEntityHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers)) {
    if (!STRIPPED_ENTITY_HEADERS.has(key.toLowerCase())) out[key] = value;
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// 事务纯函数部分：Capture 全部规则 → Project。任一步失败即抛，调用方不得交付半成品（§4.3）。
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 执行 Capture + Project 纯函数部分，返回待托管凭证与投影响应。**不**做 Commit / 注入。
 * 先对**每条**规则 Capture（redact 也收割以强制存在性），credential 目标产出待托管值；再一次
 * 性投影。任一 Capture 或 Project 抛错 → 整体 fail-closed，调用方不交付、不发下游请求。
 */
export function applyResponseMasker(rules: MaskerRule[], raw: MaskerRawResponse): MaskerOutcome {
  const captured: CapturedCredential[] = [];
  for (const rule of rules) {
    const value =
      rule.capture.source === "header"
        ? captureHeader(rule.capture.name ?? "", raw)
        : captureJson(rule.capture.path ?? "", raw);
    if (rule.capture.destination.kind === "credential") {
      captured.push({ ruleId: rule.id, ref: rule.capture.destination.ref ?? "", value });
    }
  }
  const projected = projectResponse(rules, raw);
  return { captured, projected };
}
