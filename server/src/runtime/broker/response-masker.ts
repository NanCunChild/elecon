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
 *
 * 明文边界（A3）：body 须为传输层解码后的 UTF-8 明文；本引擎**绝不猜测编码**，非法 / 非 UTF-8
 *   由传输层→Broker 边界 fail-closed（见 fetch-proxy `TransportResponse.body`）。
 * 收割值语义（A5）：capture **不做数值语义**——数字 / 布尔按源码区间取文本、字符串仅反转义，
 *   凭证原值逐字节保真。
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
/**
 * JSON 嵌套深度上限（B2）。**超过即 fail-closed**（`capture_too_deep`）。
 *
 * 目的：`assertJson` 的平台 `JSON.parse` 是递归的，两端（V8 / Dart VM）栈深上限不同——极深
 * 嵌套 body 可致一端 `capture_not_json`、一端栈溢出，既是低成本 DoS 也留跨端分叉窗口。故在
 * 平台 parser 之前做一次**线性、非递归**的括号计深预检，两端同阈值 → 同点 fail-closed。
 * 极少数合法超深载荷不在覆盖目标内（寄希望于中转 / 合法 relay 方案）。两端常量必须一致，
 * 由 golden `json_too_deep_fail_closed` 锁定（ADR-001 §8）。
 */
export const MAX_JSON_DEPTH = 512;
/**
 * 累计扫描预算（finding 1）：整个 [applyResponseMasker] 交付事务里所有 JSON 扫描（每条规则的
 * 深度预检 + parse + 定位导航 + Project 各路径重定位）**累计扫过的 code unit 数**上限；超出即
 * `capture_budget_exceeded` fail-closed，封住 O(body × path depth × rule count) 的 CPU 放大
 * （深度限只防栈溢出、不限累计量）。
 *
 * 16 MiB = 2× [MAX_BODY_INPUT_BYTES]。这是**抗 DoS 天花板**，非合法流量目标——校园凭证响应
 * 通常 KB 级、远不触及；只有病态「大 body × 深路径 × 多规则」才撞上并 fail-closed。抬高该
 * 天花板 = 方案 B（一次建索引复用，去掉 ×rules×2 乘数），暂列待做。header 源另由
 * [MAX_HEADER_INPUT_BYTES] 单独限、非放大向量，不计入此预算。两端常量与计费点必须逐一致，
 * 使「跳预算发生点」确定性、可双跑锁定（ADR-001 §8）。
 */
export const MAX_SCAN_BUDGET = 16 * 1024 * 1024;

/** 累计扫描字符计数器（[applyResponseMasker] 内单实例，跨 Capture / Project 共享）。 */
interface ScanBudget {
  spent: number;
}
function newScanBudget(): ScanBudget {
  return { spent: 0 };
}
/** 记账 n 个已扫 code unit；累计超预算立即 fail-closed。🔒 两端计费点必须一致。 */
function charge(budget: ScanBudget, n: number): void {
  budget.spent += n;
  if (budget.spent > MAX_SCAN_BUDGET) {
    throw new MaskerError("capture_budget_exceeded", `累计扫描字符超过预算 ${MAX_SCAN_BUDGET}`);
  }
}

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

/**
 * Masker 错误的结构化定位字段（B5 §3.3 白名单里引擎层可得的部分）。**绝不含原值 / 命中片段**。
 * 目前仅重复键场景携带 `key`（重复的 sibling 键名）——C1 上层 catch 再补 `ruleId` / `path`
 * 等规则层上下文后按 ADR-024 DEV profile 决定发射（DEPLOY 只留稳定 `code`）。
 */
export interface MaskerErrorDetail {
  key?: string;
}

/** Masker 执行期错误。整条 capability fail-closed；🔒 错误只进宿主日志，绝不回流 adapter。 */
export class MaskerError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly detail?: MaskerErrorDetail,
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
export function captureJson(
  path: string,
  raw: MaskerRawResponse,
  budget: ScanBudget = newScanBudget(),
): string {
  assertBodyWithinLimit(raw.body);
  assertJson(raw.body, budget);
  const tokens = tokenizeJsonPath(path);
  if (tokens === null) {
    throw new MaskerError("capture_bad_jsonpath", `不支持的 jsonpath 语法：'${path}'`);
  }
  const span = locateJsonSpan(raw.body, tokens, budget);
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
 * 先做线性深度预检（B2），再交给递归的平台 parser——避免深度炸弹在 parser 内栈溢出且跨端分叉。
 */
function assertJson(body: string, budget: ScanBudget): void {
  // 深度预检 + 平台 parse 的线性成本（~body 长度）计入累计预算（finding 1）：per-rule 重复
  // 校验的放大在此被计量，多规则大 body 会累加撞预算 fail-closed。
  charge(budget, body.length);
  assertJsonDepth(body);
  try {
    JSON.parse(body);
  } catch {
    throw new MaskerError("capture_not_json", "响应体非 JSON");
  }
}

/**
 * B2 深度预检：线性、非递归地扫括号计深，超 [MAX_JSON_DEPTH] 即 `capture_too_deep`。
 * 字符串内的 `{` / `[` / `}` / `]` 不计（用与 [scanString] 同款 `\\ 跳两位` 转义规则跳过串）。
 * 在**尚未确认合法**的 body 上运行也安全：只计括号，畸形结构随后仍由 JSON.parse fail-closed。
 */
function assertJsonDepth(body: string): void {
  let depth = 0;
  let i = 0;
  const n = body.length;
  while (i < n) {
    const ch = body[i]!;
    if (ch === '"') {
      i++;
      while (i < n) {
        const c = body[i]!;
        if (c === "\\") {
          i += 2;
          continue;
        }
        if (c === '"') {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (ch === "{" || ch === "[") {
      depth++;
      if (depth > MAX_JSON_DEPTH) {
        throw new MaskerError("capture_too_deep", `JSON 嵌套深度超过 ${MAX_JSON_DEPTH}`);
      }
    } else if (ch === "}" || ch === "]") {
      depth--;
    }
    i++;
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
        const n = Number(inner);
        // 数组下标须为**安全整数**：超 2^53-1 时 JS `Number` 丢精 / Dart `int.parse` 抛，两端
        // 会漂移（TS→capture_not_found、Dart→逃逸非 MaskerException）。越界即视为不支持语法。
        if (!Number.isSafeInteger(n)) return null;
        out.push(n);
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
function locateJsonSpan(body: string, tokens: Array<string | number>, budget: ScanBudget): JsonSpan {
  const start = skipWs(body, 0);
  charge(budget, start);
  return navigate(body, start, tokens, 0, budget);
}

/**
 * 沿封闭路径定位命中标量的源码区间；把每次 helper 前进的 code unit 数计入累计预算（finding 1）。
 * 计费落在本函数的每处推进（scanString 键、scanValue 值、skipWs），故底层扫描器签名不变、
 * 无双计：一次 `scanValue` 的 delta 即其扫过的整棵子树；命中子树在父层与子层各计一次，正是要
 * 计量的 O(depth) 重扫放大。
 */
function navigate(
  s: string,
  at: number,
  tokens: Array<string | number>,
  depth: number,
  budget: ScanBudget,
): JsonSpan {
  let i = skipWs(s, at);
  charge(budget, i - at);
  if (depth === tokens.length) {
    const end = scanValue(s, i);
    charge(budget, end - i);
    return { start: i, end };
  }
  const tok = tokens[depth]!;
  if (typeof tok === "string") {
    if (s[i] !== "{") throw new MaskerError("capture_not_found", "路径期望对象");
    {
      const ni = skipWs(s, i + 1);
      charge(budget, ni - i);
      i = ni;
    }
    if (s[i] === "}") throw new MaskerError("capture_not_found", "键不存在");
    // 扫完**整个**对象层再决定：路径导航所经此层出现任一同名键 ≥2 次即 fail-closed
    // （capture_duplicate_key，无 first/last、不消歧；责任在学校侧畸形载荷，
    // json_locator §2）。命中键记录其值起点后仍继续扫描，以覆盖「命中在前、重复在后」。
    const seen = new Set<string>();
    let matchAt = -1;
    for (;;) {
      if (s[i] !== '"') throw new MaskerError("capture_not_json", "对象键非字符串");
      const keyEnd = scanString(s, i);
      charge(budget, keyEnd - i);
      const key = parseJsonStringToken(s.slice(i, keyEnd));
      if (seen.has(key)) throw new MaskerError("capture_duplicate_key", "JSON 对象重复键", { key });
      seen.add(key);
      {
        const ni = skipWs(s, keyEnd);
        charge(budget, ni - keyEnd);
        i = ni;
      }
      if (s[i] !== ":") throw new MaskerError("capture_not_json", "对象键后缺 ':'");
      {
        const ni = skipWs(s, i + 1);
        charge(budget, ni - i);
        i = ni;
      }
      if (key === tok) matchAt = i;
      {
        const ni = skipWs(s, scanValue(s, i));
        charge(budget, ni - i);
        i = ni;
      }
      if (s[i] === ",") {
        const ni = skipWs(s, i + 1);
        charge(budget, ni - i);
        i = ni;
        continue;
      }
      if (s[i] === "}") break;
      throw new MaskerError("capture_not_json", "对象格式错误");
    }
    if (matchAt === -1) throw new MaskerError("capture_not_found", "键不存在");
    return navigate(s, matchAt, tokens, depth + 1, budget);
  }
  if (s[i] !== "[") throw new MaskerError("capture_not_found", "路径期望数组");
  {
    const ni = skipWs(s, i + 1);
    charge(budget, ni - i);
    i = ni;
  }
  if (s[i] === "]") throw new MaskerError("capture_not_found", "数组下标越界");
  let idx = 0;
  for (;;) {
    if (idx === tok) return navigate(s, i, tokens, depth + 1, budget);
    {
      const ni = skipWs(s, scanValue(s, i));
      charge(budget, ni - i);
      i = ni;
    }
    if (s[i] === ",") {
      const ni = skipWs(s, i + 1);
      charge(budget, ni - i);
      i = ni;
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
export function projectResponse(
  rules: MaskerRule[],
  raw: MaskerRawResponse,
  budget: ScanBudget = newScanBudget(),
): MaskerRawResponse {
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
    assertJson(raw.body, budget);
    body = spliceSentinels(raw.body, jsonPaths, budget);
    headers = stripEntityHeaders(headers);
  }

  return { status: raw.status, headers, body };
}

/** 剪接：把每条 json 路径命中的标量区间替换为 sentinel。区间在**原始 body**上计算后由右向左应用。 */
function spliceSentinels(body: string, jsonPaths: string[], budget: ScanBudget): string {
  const spans = jsonPaths.map((path) => {
    const tokens = tokenizeJsonPath(path);
    if (tokens === null) throw new MaskerError("capture_bad_jsonpath", `不支持的 jsonpath 语法：'${path}'`);
    const span = locateJsonSpan(body, tokens, budget);
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
  // 单一累计预算跨全部 Capture + Project 共享（finding 1）：任一步累计扫描超 MAX_SCAN_BUDGET
  // → capture_budget_exceeded fail-closed，整体不交付、不半提交。
  const budget = newScanBudget();
  const captured: CapturedCredential[] = [];
  for (const rule of rules) {
    const value =
      rule.capture.source === "header"
        ? captureHeader(rule.capture.name ?? "", raw)
        : captureJson(rule.capture.path ?? "", raw, budget);
    if (rule.capture.destination.kind === "credential") {
      captured.push({ ruleId: rule.id, ref: rule.capture.destination.ref ?? "", value });
    }
  }
  const projected = projectResponse(rules, raw, budget);
  return { captured, projected };
}
