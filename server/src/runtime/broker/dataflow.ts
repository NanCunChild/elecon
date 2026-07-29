/**
 * 声明式跨请求数据流执行器（ADR-023 §2.3/§2.4）—— **TS 参考实现**。
 *
 * 角色（2026-07-24 owner 定）：服务端**不做 declarative 生产代取**（红线 #2 公网零凭证）；
 * 本模块是数据流语义的**语言无关 golden 基准**，与客户端 Dart 生产实现（§5，
 * `client/lib/core/broker/dataflow.dart`）照同一 golden 向量双跑，钉死两端逐字节一致
 * （ADR-001 §8）。校验器（`tools/src/validator/dataflow.ts` D1–D16）已在**声明期**保证
 * 引用闭合 / 无环 / 类型匹配 / 密钥形态 / 复杂度限额，故本执行器可假定输入**已通过静态校验**，
 * 只保留**运行期 fail-closed**（提取/匹配失败、限额超出、越界）——纵深防御，不重复静态判定。
 *
 * 纯函数分解（每件都有 golden 向量，见 contract/golden/broker/dataflow.json）：
 *   ① extractHandle(bind, response)      抽取：响应 → 不透明句柄（text）。脱敏**前**求值。
 *   ② evalOp(op, args, params, nowMs)     计算：封闭 op 原生执行。含 hmac/hkdf/摘要/aes-cbc（bytes，ADR-028）。
 *   ③ applyInjections(req, injects, env)  注入：句柄 → 下游请求静态汇聚点（url/header）。
 *   ④ stripEchoes(response, injected)     脱敏：剥掉响应里回显的注入值（🔒 MVP 必做，堵回读）。
 *   ⑤ planRequestOrder(requests, injects) 拓扑：无依赖请求并发、有依赖等上游（返回分层）。
 *
 * 🔒 红线 #1（凭证派生值 / 句柄不进 adapter）+ 承重路径：AI 起草，须人工 + 安全清单复核，
 *    不得 AI 独自闭环（AGENTS.md §1 / ADR-023 §5）。
 *
 * regex 使用 ADR-023 严格安全子集及确定性 matcher，不调用原生 RegExp。AI 起草，须人工安全复核。
 */

import { createCipheriv, createHash, createHmac, hkdfSync } from "node:crypto";
import {
  type LinearRegexPattern,
  LinearRegexSyntaxError,
  matchLinearRegex,
  parseLinearRegex,
} from "@elecon/broker-primitives";

// ---- 限额（docs/reference/declarative_dataflow_ops.md §4；两端必须一致）----

/** 🔒 单句柄值上限（主闸门之一）。text 按 UTF-8 字节计、bytes 按字节计。 */
export const MAX_HANDLE_BYTES = 64 * 1024;
/** 🔒 全 DAG 句柄总预算（主闸门之一），超出 fail-closed。 */
export const MAX_DAG_HANDLE_BYTES = 4 * 1024 * 1024;
/** header 提取输入上限。 */
export const MAX_HEADER_INPUT_BYTES = 4 * 1024;
/** regex 提取输入上限（超出即失败，不静默截断）。 */
export const MAX_REGEX_INPUT_BYTES = 8 * 1024;
/** body 提取输入上限（对齐 DEFAULT_MAX_BODY_BYTES，见 transport/direct.ts）。 */
export const MAX_BODY_INPUT_BYTES = 8 * 1024 * 1024;

// ---- 类型 ----

/** 不透明句柄的运行期值。text=Unicode 文本；bytes=原始字节。 */
export type HandleValue =
  | { readonly type: "text"; readonly text: string }
  | { readonly type: "bytes"; readonly bytes: Uint8Array };

/** 数据流执行期错误。整条 capability fail-closed；🔒 错误只进宿主日志，绝不回流 adapter。 */
export class DataflowError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "DataflowError";
  }
}

export interface BindDecl {
  var: string;
  from: string;
  source: "header" | "body" | "regex";
  extract: { name?: string; jsonpath?: string; pattern?: string; group?: number };
}
export interface ComputeArg {
  ref?: string;
  text?: string;
}
export interface ComputeDecl {
  var: string;
  op: string;
  args: ComputeArg[];
  params?: Record<string, unknown>;
}
export interface InjectDecl {
  var: string;
  into: string;
  at: "url" | "header";
  name: string;
}
export interface RequestDecl {
  key: string;
  method?: string;
  url: string;
  credential?: string;
}

/** 脱敏**前**的响应（抽取读它；含尚未剥除的 header）。 */
export interface RawResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

// ═══════════════════════════════════════════════════════════════════════════
// ① 抽取（bind）：响应 → 句柄（恒 text）。脱敏前求值，只在 broker 内部。
// ═══════════════════════════════════════════════════════════════════════════

const utf8 = new TextEncoder();

function utf8Len(s: string): number {
  return utf8.encode(s).length;
}

/** 从**脱敏前**响应抽取一个标量句柄。失败一律 fail-closed（决策 6）。 */
export function extractHandle(bind: BindDecl, response: RawResponse): HandleValue {
  switch (bind.source) {
    case "header":
      return extractHeader(bind, response);
    case "body":
      return extractBody(bind, response);
    case "regex":
      return extractRegex(bind, response);
    default:
      throw new DataflowError("extract_bad_source", `未知抽取源 '${bind.source}'`);
  }
}

function extractHeader(bind: BindDecl, response: RawResponse): HandleValue {
  const wanted = (bind.extract.name ?? "").toLowerCase();
  const matches: string[] = [];
  for (const [name, value] of Object.entries(response.headers)) {
    if (name.toLowerCase() === wanted) {
      if (utf8Len(value) > MAX_HEADER_INPUT_BYTES) {
        throw new DataflowError(
          "extract_input_too_large",
          `响应头 '${bind.extract.name}' 超过 ${MAX_HEADER_INPUT_BYTES} 字节`,
        );
      }
      matches.push(value);
    }
  }
  if (matches.length === 0) {
    throw new DataflowError("extract_not_found", `bind '${bind.var}'：响应头 '${bind.extract.name}' 不存在`);
  }
  if (matches.length > 1) {
    throw new DataflowError(
      "extract_ambiguous",
      `bind '${bind.var}'：响应头 '${bind.extract.name}' 出现 ${matches.length} 次（须恰 1）`,
    );
  }
  return capText(bind.var, matches[0]!);
}

function extractBody(bind: BindDecl, response: RawResponse): HandleValue {
  if (utf8Len(response.body) > MAX_BODY_INPUT_BYTES) {
    throw new DataflowError(
      "extract_input_too_large",
      `bind '${bind.var}'：响应体超过 ${MAX_BODY_INPUT_BYTES} 字节`,
    );
  }
  let root: unknown;
  try {
    root = JSON.parse(response.body);
  } catch {
    throw new DataflowError("extract_not_json", `bind '${bind.var}'：响应体非 JSON，无法 jsonpath 抽取`);
  }
  const selected = evalJsonPath(bind.extract.jsonpath ?? "", root);
  if (selected.length === 0) {
    throw new DataflowError(
      "extract_not_found",
      `bind '${bind.var}'：jsonpath '${bind.extract.jsonpath}' 未选中任何值`,
    );
  }
  if (selected.length > 1) {
    throw new DataflowError(
      "extract_ambiguous",
      `bind '${bind.var}'：jsonpath 选中 ${selected.length} 个值（须恰 1，不支持数组句柄）`,
    );
  }
  return scalarToText(bind.var, selected[0]);
}

function extractRegex(bind: BindDecl, response: RawResponse): HandleValue {
  if (utf8Len(response.body) > MAX_REGEX_INPUT_BYTES) {
    // 🔒 超输入上限**失败而非截断**：截断会让行为随响应大小静默改变（隐式数据依赖分支）。
    throw new DataflowError(
      "extract_input_too_large",
      `bind '${bind.var}'：regex 输入超过 ${MAX_REGEX_INPUT_BYTES} 字节`,
    );
  }
  let pattern: LinearRegexPattern;
  try {
    pattern = parseLinearRegex(bind.extract.pattern ?? "");
  } catch (err) {
    throw new DataflowError(
      "extract_bad_pattern",
      `bind '${bind.var}'：模式串非法（${err instanceof LinearRegexSyntaxError ? err.message : "fail-closed"}）`,
    );
  }
  const m = matchLinearRegex(pattern, response.body);
  if (m === null) {
    throw new DataflowError("extract_not_found", `bind '${bind.var}'：regex 未匹配`);
  }
  const group = bind.extract.group ?? 0;
  const captured = m.groups[group];
  if (captured === undefined) {
    throw new DataflowError("extract_not_found", `bind '${bind.var}'：regex group ${group} 未参与匹配`);
  }
  return capText(bind.var, captured);
}

/** 把标量 JSON 值转 text 句柄；对象 / 数组 / null 视为失败（无数组句柄）。 */
function scalarToText(varName: string, value: unknown): HandleValue {
  if (typeof value === "string") return capText(varName, value);
  if (typeof value === "number" && Number.isFinite(value)) {
    // 🔒 大整数跨端一致性：JSON.parse 已把 >2^53 的整数舍入进 double（精度不可恢复），
    // Dart `jsonDecode` 保 64 位精度——二者会静默漂移。对超安全整数范围的**整数值**一律
    // fail-closed（与 client `_maxSafeInteger` 对称），确保能通过者两端逐字节一致。非整值
    // 浮点保持既有序列化（`String(number)` ↔ `_numToText`）。
    if (Number.isInteger(value) && !Number.isSafeInteger(value)) {
      throw new DataflowError(
        "extract_number_unsafe",
        `bind '${varName}'：整数 ${value} 超出安全范围（|n|>2^53-1），跨端不可靠`,
      );
    }
    return capText(varName, String(value));
  }
  if (typeof value === "boolean") return capText(varName, value ? "true" : "false");
  throw new DataflowError(
    "extract_not_scalar",
    `bind '${varName}'：选中值非标量（${value === null ? "null" : typeof value}）`,
  );
}

/** 单句柄上限（64 KB）检查，超出 fail-closed。 */
function capText(varName: string, value: string): HandleValue {
  if (utf8Len(value) > MAX_HANDLE_BYTES) {
    throw new DataflowError("handle_too_large", `句柄 '${varName}' 超过单句柄上限 ${MAX_HANDLE_BYTES} 字节`);
  }
  return { type: "text", text: value };
}

/**
 * 极简 JSONPath 子集求值（抽取只需定位单标量）。
 *
 * 支持：`$`、`.key`、`['key']`、`[n]`。**不**支持通配 `*` / 递归 `..` / 过滤 `?()`——
 * 与「匹配数量=1、标量句柄」约束自洽（ADR-023 决策 1），也避免拉入完整 JSONPath 引擎
 * （跨端一致成本）。命中多个由上层判 ambiguous。
 */
export function evalJsonPath(path: string, root: unknown): unknown[] {
  const tokens = tokenizeJsonPath(path);
  if (tokens === null) throw new DataflowError("extract_bad_jsonpath", `不支持的 jsonpath 语法：'${path}'`);
  let cur: unknown = root;
  for (const tok of tokens) {
    if (cur == null) return [];
    if (typeof tok === "number") {
      if (!Array.isArray(cur) || tok < 0 || tok >= cur.length) return [];
      cur = cur[tok];
    } else {
      if (typeof cur !== "object" || Array.isArray(cur)) return [];
      if (!Object.hasOwn(cur as object, tok)) return [];
      cur = (cur as Record<string, unknown>)[tok];
    }
  }
  return [cur];
}

/** 把 jsonpath 串拆成步骤（string=对象键，number=数组下标）；不支持的语法返回 null。 */
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

// ═══════════════════════════════════════════════════════════════════════════
// ② 计算（compute）：封闭 op 词表，broker 原生执行。逐 op 语义见 dataflow_ops.md §2。
// ═══════════════════════════════════════════════════════════════════════════

/** text → UTF-8 字节；bytes 原样。crypto / base64 / hex 输入的唯一隐式转换。 */
function toBytes(v: HandleValue): Uint8Array {
  return v.type === "bytes" ? v.bytes : utf8.encode(v.text);
}
function asText(v: HandleValue, opName: string, pos: number): string {
  if (v.type !== "text")
    throw new DataflowError("op_type_mismatch", `${opName} args[${pos}] 需要 text，实得 bytes`);
  return v.text;
}
/**
 * 句柄字节长度：bytes 按字节、text 按 **UTF-8 字节**（非 UTF-16 码元）。
 * 🔒 全 DAG 4 MB 预算的计量口径——两端（server 此处 / client host）**必须一致**，
 * 否则同一 manifest 在两端的放行/拒绝会漂移（审阅 issue 3 / C2）。
 */
export function handleByteLen(v: HandleValue): number {
  return v.type === "bytes" ? v.bytes.length : utf8Len(v.text);
}

/**
 * 执行单个封闭 op。[args] 已解引用为句柄值；[params] 是 op 的标量参数。
 * 假定已过静态校验（元数 / 类型 / params 键集合正确），此处只做运行期语义与限额。
 */
export function evalOp(
  op: string,
  args: HandleValue[],
  params: Record<string, unknown> | undefined,
  nowMs: number,
): HandleValue {
  const p = params ?? {};
  switch (op) {
    case "concat": {
      const out = args.map((a, i) => asText(a, "concat", i)).join("");
      return capText("concat", out);
    }
    case "substring": {
      const s = asText(args[0]!, "substring", 0);
      const start = p.start as number;
      const length = p.length as number;
      // 🔒 越界一律 fail-closed，不钳制（消除 JS 钳制 vs Dart 抛异常的分歧）。
      if (start + length > s.length) {
        throw new DataflowError(
          "substring_out_of_range",
          `substring 越界：start=${start}+length=${length} > 长度 ${s.length}`,
        );
      }
      return capText("substring", s.substring(start, start + length));
    }
    case "base64": {
      const variant = p.variant as string;
      const buf = Buffer.from(toBytes(args[0]!));
      const out = variant === "url" ? buf.toString("base64url") : buf.toString("base64");
      return capText("base64", out);
    }
    case "hex": {
      const buf = Buffer.from(toBytes(args[0]!));
      const lower = buf.toString("hex");
      return capText("hex", (p.case as string) === "upper" ? lower.toUpperCase() : lower);
    }
    case "urlencode": {
      const s = asText(args[0]!, "urlencode", 0);
      return capText("urlencode", urlencode(s, (p.variant as string) === "form"));
    }
    case "hmac-sha256": {
      const key = toBytes(args[0]!);
      const msg = toBytes(args[1]!);
      const mac = createHmac("sha256", key).update(msg).digest();
      return capBytes("hmac-sha256", new Uint8Array(mac));
    }
    case "hkdf": {
      const ikm = toBytes(args[0]!);
      const salt = toBytes(args[1]!);
      const info = toBytes(args[2]!);
      const length = p.length as number;
      // Node hkdfSync 遵循 RFC 5869（SHA-256 extract+expand）；salt 空串 → 全零 salt。
      const out = hkdfSync("sha256", ikm, salt, info, length);
      return capBytes("hkdf", new Uint8Array(out));
    }
    case "now": {
      return capText("now", formatNow(nowMs, p.format as string));
    }
    // ---- ADR-028 加密算子（确定性）----
    case "md5":
    case "sha1":
    case "sha256": {
      // 标准单向摘要，输出定长原始字节。message 为 text 时按 UTF-8。
      const digest = createHash(op).update(toBytes(args[0]!)).digest();
      return capBytes(op, new Uint8Array(digest));
    }
    case "aes-cbc": {
      return evalAesCbc(args, (p.padding as string) ?? "");
    }
    default:
      throw new DataflowError("op_unknown", `未知 op '${op}'`);
  }
}

/** bytes 句柄上限检查。 */
function capBytes(opName: string, bytes: Uint8Array): HandleValue {
  if (bytes.length > MAX_HANDLE_BYTES) {
    throw new DataflowError("handle_too_large", `${opName} 输出超过单句柄上限 ${MAX_HANDLE_BYTES} 字节`);
  }
  return { type: "bytes", bytes };
}

/**
 * AES-CBC 加密（ADR-028）。确定性：相同 key+iv+message+padding → 唯一密文。
 *
 * 🔒 语义逐端钉死（ops.md §2），Dart 端须逐字节复现：
 *  - **key 为原始字节，绝不走 passphrase KDF**；长度 16/24/32 → AES-128/192/256，否则 fail-closed。
 *  - iv 须恰 16 字节。
 *  - padding=pkcs7（Node setAutoPadding(true)，块整数倍时补整块 0x10×16）/ none（长度须为块整数倍）。
 */
function evalAesCbc(args: HandleValue[], padding: string): HandleValue {
  const key = toBytes(args[0]!);
  const message = toBytes(args[1]!);
  const iv = toBytes(args[2]!);

  const variant =
    key.length === 16
      ? "aes-128-cbc"
      : key.length === 24
        ? "aes-192-cbc"
        : key.length === 32
          ? "aes-256-cbc"
          : undefined;
  if (variant === undefined) {
    throw new DataflowError("aes_bad_key_length", `aes-cbc：key 长度 ${key.length} 非法（须 16/24/32 字节）`);
  }
  if (iv.length !== 16) {
    throw new DataflowError("aes_bad_iv_length", `aes-cbc：iv 长度 ${iv.length} 非法（须恰 16 字节）`);
  }

  let autoPad: boolean;
  if (padding === "pkcs7") {
    autoPad = true;
  } else if (padding === "none") {
    if (message.length % 16 !== 0) {
      throw new DataflowError(
        "aes_bad_block",
        `aes-cbc padding=none：明文长度 ${message.length} 非 16 整数倍`,
      );
    }
    autoPad = false;
  } else {
    throw new DataflowError("aes_bad_padding", `aes-cbc：未知 padding '${padding}'`);
  }

  const cipher = createCipheriv(variant, key, iv);
  cipher.setAutoPadding(autoPad);
  const out = Buffer.concat([cipher.update(message), cipher.final()]);
  return capBytes("aes-cbc", new Uint8Array(out));
}

/** RFC 3986 unreserved 之外一律 %XX（大写）；空格 component=%20 / form=+。UTF-8 逐字节。 */
export function urlencode(s: string, form: boolean): string {
  const bytes = utf8.encode(s);
  let out = "";
  for (const b of bytes) {
    // A-Z a-z 0-9 - _ . ~
    const unreserved =
      (b >= 0x41 && b <= 0x5a) ||
      (b >= 0x61 && b <= 0x7a) ||
      (b >= 0x30 && b <= 0x39) ||
      b === 0x2d ||
      b === 0x5f ||
      b === 0x2e ||
      b === 0x7e;
    if (unreserved) {
      out += String.fromCharCode(b);
    } else if (b === 0x20 && form) {
      out += "+";
    } else {
      out += `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
    }
  }
  return out;
}

/** now 定值格式化（不读真实时钟；nowMs 由宿主喂入）。 */
export function formatNow(nowMs: number, format: string): string {
  if (!Number.isFinite(nowMs) || nowMs < 0) {
    throw new DataflowError("now_out_of_range", `now：nowMs=${nowMs} 不在支持范围（须 ≥0 有限）`);
  }
  switch (format) {
    case "epoch-seconds":
      return String(Math.floor(nowMs / 1000));
    case "epoch-millis":
      return String(Math.floor(nowMs));
    case "iso8601":
      // 恒带毫秒与 Z：YYYY-MM-DDTHH:MM:SS.sssZ（JS toISOString 天然此形）。
      return new Date(Math.floor(nowMs)).toISOString();
    default:
      throw new DataflowError("now_bad_format", `now：未知 format '${format}'`);
  }
}

/**
 * 求解 bind + compute 全图，返回 var → 句柄值。**假定 compute 已按声明序拓扑排好**
 * （validator D7 禁前向引用）；逐条按声明序求值，引用向前解析。
 *
 * [bound] 是 bind 抽取结果（var → text 句柄）。累计句柄字节受全 DAG 4 MB 预算约束。
 */
export function evalComputeGraph(
  bound: Map<string, HandleValue>,
  computes: ComputeDecl[],
  nowMs: number,
): Map<string, HandleValue> {
  const env = new Map(bound);
  let totalBytes = 0;
  for (const v of env.values()) totalBytes += handleByteLen(v);

  for (const c of computes) {
    const argVals = c.args.map((arg): HandleValue => {
      if (typeof arg.text === "string") return { type: "text", text: arg.text };
      const ref = env.get(arg.ref ?? "");
      if (ref === undefined) {
        // 静态校验应已挡下；运行期兜底 fail-closed。
        throw new DataflowError("ref_undefined", `compute '${c.var}'：引用 '${arg.ref}' 未定义`);
      }
      return ref;
    });
    const result = evalOp(c.op, argVals, c.params, nowMs);
    totalBytes += handleByteLen(result);
    if (totalBytes > MAX_DAG_HANDLE_BYTES) {
      throw new DataflowError(
        "dag_budget_exceeded",
        `全 DAG 句柄总字节超过 ${MAX_DAG_HANDLE_BYTES}（累计 ${totalBytes}）`,
      );
    }
    env.set(c.var, result);
  }
  return env;
}

// ═══════════════════════════════════════════════════════════════════════════
// ③ 注入（inject）：句柄 → 下游请求静态汇聚点。返回对请求的修改，不改原对象。
// ═══════════════════════════════════════════════════════════════════════════

/** 一次注入对某请求的效果：追加 query 参数或设置请求头。 */
export interface InjectionEffect {
  into: string;
  at: "url" | "header";
  name: string;
  /** 已是 text（inject 面只接受 text，validator D9 保证）。用于注入 + 回显剥离。 */
  value: string;
}

/**
 * 把某请求相关的注入解析为效果列表。句柄须为 text（validator D9 静态保证；运行期兜底）。
 * 汇聚点静态（into/at/name 声明死），此处不依值选择目标。
 */
export function resolveInjections(injects: InjectDecl[], env: Map<string, HandleValue>): InjectionEffect[] {
  const effects: InjectionEffect[] = [];
  for (const inj of injects) {
    const v = env.get(inj.var);
    if (v === undefined) {
      // 决策 6：注入时句柄缺失 → 整条 capability fail-closed，不省略注入。
      throw new DataflowError("inject_missing_handle", `inject：句柄 '${inj.var}' 未就绪`);
    }
    if (v.type !== "text") {
      throw new DataflowError(
        "inject_type_mismatch",
        `inject '${inj.var}'：注入面只接受 text（bytes 须先 base64/hex）`,
      );
    }
    effects.push({ into: inj.into, at: inj.at, name: inj.name, value: v.text });
  }
  return effects;
}

/** 把注入效果应用到某请求的 URL / headers 上，返回新的 {url, headers}。 */
export function applyInjections(
  request: RequestDecl,
  effects: InjectionEffect[],
  baseHeaders: Record<string, string> = {},
): { url: string; headers: Record<string, string> } {
  let url = request.url;
  const headers = { ...baseHeaders };
  for (const eff of effects) {
    if (eff.into !== request.key) continue;
    if (eff.at === "url") {
      // 值按 RFC 3986 组件编码（component 变体）；名同样编码。
      const sep = url.includes("?") ? "&" : "?";
      url += `${sep}${urlencode(eff.name, false)}=${urlencode(eff.value, false)}`;
    } else {
      headers[eff.name] = eff.value;
    }
  }
  return { url, headers };
}

/**
 * 一次注入在下游响应里**可能回显的所有形态**——供 [stripEchoes] 堵回读（审阅 issue 1 / B7）。
 *
 * 🔒 `at=url` 时**上线的是 component 编码形**（如 `a b&c` → `a%20b%26c`）：下游既可能回显
 * 原始解码值（服务器解码后写回），也可能回显编码形（原样反射 query 串）。**两者都须剥**，
 * 否则 adapter 仍能看到秘密的等价物。`at=header` 值原样上线，只回原始值。
 */
export function injectionEchoTargets(effect: InjectionEffect): string[] {
  if (effect.at === "url") return [effect.value, urlencode(effect.value, false)];
  return [effect.value];
}

// ═══════════════════════════════════════════════════════════════════════════
// ④ 脱敏：剥掉响应里回显的注入值（🔒 MVP 必做，堵回读通道，ADR-023 §2.5）。
// ═══════════════════════════════════════════════════════════════════════════

/** 注入值在响应体 / 头里的回显掩码。 */
export const ECHO_MASK = "[stripped]";

/**
 * 从交给 adapter 前的响应里剥除注入值回显。broker 知道注入值的真实字节，像剥 Set-Cookie
 * 一样把它们替换为定值掩码——adapter 无从「注入猜测 → 观察回显」套值。
 *
 * 🔒 **剥除全部非空注入值，不设长度下限**（审阅 issue 2）：短 token / nonce / 凭证派生值
 * 同样是回读面，ADR-023 §2.5 只接受**比较 / 长度**预言机，**未接受**短值的直接回读。代价是
 * 极短且高频的注入值可能过度掩码 body——这是安全侧的取舍（掩码是保守方向，不泄露）。
 * 仅跳过空串（空串 replace 会在每个位置插掩码，且空串无秘密可言）。
 */
export function stripEchoes(response: RawResponse, injectedValues: readonly string[]): RawResponse {
  const targets = injectedValues.filter((v) => v.length > 0);
  if (targets.length === 0) return response;
  // 长值优先，避免短值先替换破坏长值边界。
  const ordered = [...new Set(targets)].sort((a, b) => b.length - a.length);
  let body = response.body;
  const headers: Record<string, string> = {};
  for (const val of ordered) body = replaceAllLiteral(body, val, ECHO_MASK);
  for (const [name, value] of Object.entries(response.headers)) {
    let masked = value;
    for (const val of ordered) masked = replaceAllLiteral(masked, val, ECHO_MASK);
    headers[name] = masked;
  }
  return { status: response.status, headers, body };
}

function replaceAllLiteral(haystack: string, needle: string, replacement: string): string {
  if (needle === "") return haystack;
  return haystack.split(needle).join(replacement);
}

// ═══════════════════════════════════════════════════════════════════════════
// ⑤ 拓扑：请求依赖分层。无依赖请求同层（可并发）；依赖上游的请求排后层。
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 据 bind（哪个 var 取自哪个 request）与 inject（哪个 var 注入哪个 request）推出请求依赖，
 * 返回**分层拓扑序**：同层内请求相互无依赖、可并发；靠后层依赖靠前层。
 *
 * 依赖边：若某 inject 把 var 注入 R_into，而 var 可追溯到 R_from 的响应，则 R_into 依赖 R_from。
 * validator D15 已静态保证无环；此处兜底：仍成环则 fail-closed（不静默破环）。
 */
export function planRequestOrder(
  requests: RequestDecl[],
  binds: BindDecl[],
  computes: ComputeDecl[],
  injects: InjectDecl[],
): string[][] {
  const keys = requests.map((r) => r.key);
  const origin = traceOrigins(binds, computes);

  // into → 依赖的 from 集合
  const deps = new Map<string, Set<string>>();
  for (const key of keys) deps.set(key, new Set());
  for (const inj of injects) {
    const froms = origin.get(inj.var) ?? new Set<string>();
    const set = deps.get(inj.into);
    if (set) for (const f of froms) if (f !== inj.into) set.add(f);
  }

  // Kahn 分层
  const remaining = new Set(keys);
  const layers: string[][] = [];
  while (remaining.size > 0) {
    const layer = [...remaining].filter((k) => {
      for (const d of deps.get(k) ?? []) if (remaining.has(d)) return false;
      return true;
    });
    if (layer.length === 0) {
      throw new DataflowError("request_cycle", `请求依赖成环，无拓扑序：${[...remaining].join(", ")}`);
    }
    // 层内保持原声明序，确定性输出。
    const ordered = keys.filter((k) => layer.includes(k));
    layers.push(ordered);
    for (const k of ordered) remaining.delete(k);
  }
  return layers;
}

/** 每个 var 可追溯到的上游 request key 集合（bind 直接给出；compute 沿引用并上游）。 */
export function traceOrigins(binds: BindDecl[], computes: ComputeDecl[]): Map<string, Set<string>> {
  const origin = new Map<string, Set<string>>();
  for (const b of binds) origin.set(b.var, new Set([b.from]));
  for (const c of computes) {
    const set = new Set<string>();
    for (const arg of c.args) {
      if (typeof arg.ref === "string") {
        for (const f of origin.get(arg.ref) ?? []) set.add(f);
      }
    }
    origin.set(c.var, set);
  }
  return origin;
}
