/**
 * 声明式跨请求数据流校验（ADR-023 · 规则 D1–D16）。
 *
 * 🔒 **安全承重路径**：本模块是 `bind`/`compute`/`inject` 声明面的**唯一静态闸门**——
 * ADR-023 §5 决策 7（owner 2026-07-24）裁定 schema 层**不加 `if/then`**，故引用闭合、
 * DAG 无环、静态类型、密钥形态、复杂度限额、注入汇聚点全部落在这里。schema 只管
 * 字段形状与封闭枚举。改本文件 = 改承重墙，须人工 + 安全清单复核（AGENTS.md §1）。
 *
 * 逐 op 的元数 / 参数 / 类型签名与跨端语义见 `docs/reference/declarative_dataflow_ops.md`；
 * 本文件的 OP_SIGNATURES 是该表的可执行形式，二者漂移即 bug。
 *
 * 规则索引：
 *  D1  仅 declarative capability 可声明 bind/compute/inject（类比 C12）
 *  D2  bind.from 须指向本 capability 已声明的 requests[].key
 *  D3  变量名在 bind ∪ compute 内唯一
 *  D4  extract 键集合须与 source 严格对应（header→name / body→jsonpath / regex→pattern[+group]）
 *  D5  regex 语法白名单：禁嵌套量词、禁 lookbehind、禁反向引用、禁命名组；group ≤ 捕获组数
 *  D6  compute arg 须恰有 ref 或 text 之一
 *  D7  引用闭合 + 无环：ref 只能指向**声明序在前**的变量
 *  D8  op 元数与 params 键集合须与签名精确一致
 *  D9  静态类型检查：bytes/text 逐位置匹配；inject 的 var 须为 text
 *  D10 🔒 hmac-sha256 的 key / hkdf 的 ikm 必须是 ref，字面量密钥一律拒
 *  D11 静态复杂度限额：节点 ≤64、引用深度 ≤16、每 op args ≤8
 *  D12 inject 目标 request 已声明、var 已定义、同一汇聚点不重复
 *  D13 🔒 信任门：正向 tier 允许表（防扩散，ADR-023 §2.6——不得写成「非 official 即放行」）
 *  D14 死句柄（定义后既未被引用也未被注入）→ warn
 *  D15 请求依赖图无环（inject 使目标请求依赖 var 的全部上游请求）
 *  D16 🔒 at=header 的注入名不得为凭证头 / 逐跳头（红线 #1）
 */

import type { Finding } from "./index.js";

// ---- 声明面类型（对应 contract/manifest.schema.json）----

/** 抽取段一项：从响应取值绑为不透明句柄。产出类型恒为 text。 */
export interface BindDecl {
  var: string;
  from: string;
  source: "header" | "body" | "regex";
  extract: { name?: string; jsonpath?: string; pattern?: string; group?: number };
}

/** compute 的单个位置参数：引用句柄（ref）或内联文本字面量（text），恰择其一。 */
export interface ComputeArg {
  ref?: string;
  text?: string;
}

/** 计算段一项：封闭 op，broker 原生执行。 */
export interface ComputeDecl {
  var: string;
  op: string;
  args: ComputeArg[];
  params?: Record<string, unknown>;
}

/** 注入段一项：把句柄注入下游请求的静态汇聚点。 */
export interface InjectDecl {
  var: string;
  into: string;
  at: "url" | "header";
  name: string;
}

/** 本模块关心的 capability 切面（避免与 index.ts 的 CapabilityDecl 强耦合）。 */
export interface DataflowCapability {
  id: string;
  requestGraph: "declarative" | "imperative";
  requests?: Array<{ key: string; method?: string; url?: string; credential?: string }>;
  bind?: BindDecl[];
  compute?: ComputeDecl[];
  inject?: InjectDecl[];
}

// ---- 限额（§0.1；两端与 validator 必须一致）----

/** 单 capability 的数据流节点总数（bind + compute + inject）上限。 */
export const MAX_DATAFLOW_NODES = 64;
/** 句柄引用嵌套深度上限（bind 为 0 层）。 */
export const MAX_COMPUTE_DEPTH = 16;
/** 单个 op 的 args 个数上限。 */
export const MAX_OP_ARGS = 8;
/** regex 抽取器允许的 group 下标上限（与 schema 的 maximum 一致）。 */
const MAX_REGEX_GROUP = 32;

/**
 * 🔒 允许声明数据流的信任档 —— **正向允许表**（ADR-023 §2.6 防扩散条款）。
 *
 * 刻意**不**写成「非 official 即放行」的否定式：ADR-018 正在铺第三方分发与四信任域，
 * 否定式会让任何将来新增的、**在生产环境中可存在**的第三方档自动继承本能力。
 * `sideload` 之所以在表内，仅因它结构上只存在于 DEV 构建（`fetchTrustPermitted` /
 * `NODE_ENV !== "production"` / ADR-024 DEPLOY profile 编译期剔除）。
 * 新增任何信任档都必须**显式**重新裁定后才可加入本表。
 */
export const DATAFLOW_ALLOWED_TRUST_TIERS: ReadonlySet<string> = new Set(["official", "sideload"]);

/**
 * 🔒 不得作为 inject 目标的请求头（红线 #1）。
 *
 * 凭证只由 broker 依 `credentials` 声明注入；数据流不得伪造、覆盖或旁路之。逐跳头
 * （Host / Content-Length / Transfer-Encoding 等）由传输层拥有，adapter 改写它们等于
 * 请求走私面。**本表是 server broker `REQUEST_HEADER_DENYLIST` 的超集**，刻意本地复刻
 * 而非 import——validator 须能在镜像后的公开 adapters 仓独立运行（ADR-018 §2.8），
 * 与 `cmpSemver` / `BUNDLE_INCLUDE` 同理。二者漂移只会让本表更严，不会更松。
 */
export const INJECT_HEADER_DENYLIST: ReadonlySet<string> = new Set([
  "cookie",
  "cookie2",
  "set-cookie",
  "set-cookie2",
  "authorization",
  "proxy-authorization",
  "host",
  "content-length",
  "transfer-encoding",
  "connection",
  "keep-alive",
  "upgrade",
  "te",
  "trailer",
  "expect",
]);

// ---- op 签名表（docs/reference/declarative_dataflow_ops.md §1 的可执行形式）----

type HandleType = "text" | "bytes";

const TEXT: readonly HandleType[] = ["text"];
const ANY: readonly HandleType[] = ["text", "bytes"];

type ParamSpec = { kind: "int"; min: number; max: number } | { kind: "enum"; values: readonly string[] };

interface OpSignature {
  /** args 个数区间（闭区间）。 */
  minArgs: number;
  maxArgs: number;
  /** 逐位置可接受的类型；位置超出本表长度时沿用最后一项（供 concat 等变元数 op）。 */
  accepts: ReadonlyArray<readonly HandleType[]>;
  /** 🔒 必须是 ref（不得字面量）的 args 下标 —— 密钥位。 */
  refOnly: readonly number[];
  /** params 的键集合与取值域；须**精确**匹配，缺一多一皆错。 */
  params: Readonly<Record<string, ParamSpec>>;
  result: HandleType;
}

export const OP_SIGNATURES: Readonly<Record<string, OpSignature>> = {
  concat: { minArgs: 2, maxArgs: 8, accepts: [TEXT], refOnly: [], params: {}, result: "text" },
  substring: {
    minArgs: 1,
    maxArgs: 1,
    accepts: [TEXT],
    refOnly: [],
    // 越界 fail-closed（不钳制）由 runtime 承担；此处只约束声明面取值域。
    params: { start: { kind: "int", min: 0, max: 65536 }, length: { kind: "int", min: 1, max: 65536 } },
    result: "text",
  },
  base64: {
    minArgs: 1,
    maxArgs: 1,
    accepts: [ANY],
    refOnly: [],
    params: { variant: { kind: "enum", values: ["standard", "url"] } },
    result: "text",
  },
  hex: {
    minArgs: 1,
    maxArgs: 1,
    accepts: [ANY],
    refOnly: [],
    params: { case: { kind: "enum", values: ["lower", "upper"] } },
    result: "text",
  },
  urlencode: {
    minArgs: 1,
    maxArgs: 1,
    accepts: [TEXT],
    refOnly: [],
    params: { variant: { kind: "enum", values: ["component", "form"] } },
    result: "text",
  },
  "hmac-sha256": {
    minArgs: 2,
    maxArgs: 2,
    accepts: [ANY, ANY],
    refOnly: [0], // 🔒 key
    params: {},
    result: "bytes",
  },
  hkdf: {
    minArgs: 3,
    maxArgs: 3,
    accepts: [ANY, ANY, ANY],
    refOnly: [0], // 🔒 ikm
    params: { length: { kind: "int", min: 1, max: 64 } },
    result: "bytes",
  },
  now: {
    minArgs: 0,
    maxArgs: 0,
    accepts: [],
    refOnly: [],
    params: { format: { kind: "enum", values: ["epoch-seconds", "epoch-millis", "iso8601"] } },
    result: "text",
  },
};

/** source → extract 必备键（D4）。group 是 regex 的唯一可选键。 */
const EXTRACT_REQUIRED_KEYS: Readonly<Record<string, readonly string[]>> = {
  header: ["name"],
  body: ["jsonpath"],
  regex: ["pattern"],
};
const EXTRACT_OPTIONAL_KEYS: Readonly<Record<string, readonly string[]>> = {
  header: [],
  body: [],
  regex: ["group"],
};

// ---- D5：regex 语法白名单 ----

export interface RegexSyntaxResult {
  /** 拒绝理由；通过时为 null。 */
  reason: string | null;
  /** 捕获组个数（供 group 下标校验）；语法非法时为 0。 */
  groupCount: number;
}

/**
 * 🔒 regex 语法白名单（ADR-023 §5 决策 1）。
 *
 * **输入大小挡不住灾难性回溯**——`(a+)+$` 在 8 KB 输入上即可挂死，而模式串正由
 * adapter 作者提供。故静态侧禁掉可导致指数回溯的构造（嵌套量词、反向引用），
 * 运行期另有回溯步数预算兜底（两道闸门，缺一不可）。
 *
 * 首批禁用：
 *  - **嵌套量词**：对「内部已含量词的分组」再加量词（`(a+)+` / `(?:a*)*` / `(a{2}){3}`）
 *  - **lookbehind** `(?<=` `(?<!`：Dart/JS 引擎支持度与语义差异大，且回溯行为难界定
 *  - **命名捕获组** `(?<name>`：首批收窄语法面；group 恒按编号引用
 *  - **反向引用** `\1` `\k<n>`：强制指数回溯，无例外
 * lookahead `(?=` `(?!` 放行（ADR 未禁，且由步数预算兜底）。
 */
export function checkRegexSyntax(pattern: string): RegexSyntaxResult {
  let groupCount = 0;
  let inClass = false;
  /** 分组栈：每项记录「该组内部是否出现过量词」。 */
  const stack: Array<{ hasQuantifier: boolean }> = [];
  /** 刚闭合的分组（供「`)` 后紧跟量词」检测）；null 表示上一个 token 不是 `)`。 */
  let justClosed: { hasQuantifier: boolean } | null = null;

  const markQuantifier = (): void => {
    for (const g of stack) g.hasQuantifier = true;
  };

  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i]!;

    if (c === "\\") {
      const next = pattern[i + 1];
      if (next === undefined) return { reason: "模式串以孤立反斜杠结尾", groupCount: 0 };
      if (!inClass && /[1-9]/.test(next)) {
        return { reason: `禁反向引用 \\${next}（强制指数回溯）`, groupCount: 0 };
      }
      if (!inClass && next === "k") {
        return { reason: "禁命名反向引用 \\k<…>（强制指数回溯）", groupCount: 0 };
      }
      i++; // 跳过被转义字符
      justClosed = null;
      continue;
    }

    if (inClass) {
      if (c === "]") inClass = false;
      justClosed = null;
      continue;
    }

    if (c === "[") {
      inClass = true;
      justClosed = null;
      continue;
    }

    if (c === "(") {
      if (pattern.startsWith("(?<=", i) || pattern.startsWith("(?<!", i)) {
        return { reason: "禁 lookbehind（(?<= / (?<!）", groupCount: 0 };
      }
      if (pattern.startsWith("(?<", i)) {
        return { reason: "禁命名捕获组（(?<name>）；group 请按编号引用", groupCount: 0 };
      }
      const isCapturing = pattern[i + 1] !== "?";
      if (isCapturing) groupCount++;
      stack.push({ hasQuantifier: false });
      justClosed = null;
      continue;
    }

    if (c === ")") {
      const popped = stack.pop();
      if (popped === undefined) return { reason: "括号不配对（多余的 `)`）", groupCount: 0 };
      // 组内量词向外传播：外层组也算「内部含量词」，使 `((a+))+ ` 一并被拦。
      if (popped.hasQuantifier) markQuantifier();
      justClosed = popped;
      continue;
    }

    // 量词：* + ? 与 {n} / {n,} / {n,m}
    const quantifier = matchQuantifier(pattern, i);
    if (quantifier !== null) {
      if (justClosed?.hasQuantifier) {
        return {
          reason: `禁嵌套量词（对已含量词的分组再加量词，如 (a+)+）：位置 ${i}`,
          groupCount: 0,
        };
      }
      markQuantifier();
      if (justClosed !== null) justClosed.hasQuantifier = true;
      i = quantifier.end - 1;
      justClosed = null;
      continue;
    }

    justClosed = null;
  }

  if (inClass) return { reason: "字符类未闭合（缺 `]`）", groupCount: 0 };
  if (stack.length > 0) return { reason: "括号不配对（缺 `)`）", groupCount: 0 };

  // 兜底：交给引擎判一次真实语法合法性（Dart RegExp 同为 ECMA-262 兼容）。
  try {
    new RegExp(pattern);
  } catch (err) {
    return { reason: `模式串非法：${(err as Error).message}`, groupCount: 0 };
  }

  return { reason: null, groupCount };
}

/** 若 [pattern] 在下标 [i] 处是量词，返回其结束下标（不含）；否则 null。 */
function matchQuantifier(pattern: string, i: number): { end: number } | null {
  const c = pattern[i]!;
  if (c === "*" || c === "+" || c === "?") {
    // 惰性/占有修饰 `*?` 只是同一量词的变体，一并吞掉。
    const next = pattern[i + 1];
    return { end: next === "?" ? i + 2 : i + 1 };
  }
  if (c === "{") {
    const close = pattern.indexOf("}", i);
    if (close === -1) return null; // 字面量 `{`
    const inner = pattern.slice(i + 1, close);
    if (!/^\d+(,\d*)?$/.test(inner)) return null; // 字面量 `{`
    const next = pattern[close + 1];
    return { end: next === "?" ? close + 2 : close + 1 };
  }
  return null;
}

// ---- 主校验 ----

/**
 * 校验一个 manifest 内全部 capability 的数据流声明（D1–D16）。
 *
 * `bind`/`compute`/`inject` 均可选；三者全缺即跳过（除 D1 外无可查项）。
 */
export function checkDataflow(manifest: {
  trustTier?: string;
  capabilities?: DataflowCapability[];
}): Finding[] {
  const findings: Finding[] = [];
  for (const cap of manifest.capabilities ?? []) {
    findings.push(...checkCapabilityDataflow(cap, manifest.trustTier));
  }
  return findings;
}

function checkCapabilityDataflow(cap: DataflowCapability, trustTier: string | undefined): Finding[] {
  const findings: Finding[] = [];
  const binds = cap.bind ?? [];
  const computes = cap.compute ?? [];
  const injects = cap.inject ?? [];
  const declared = cap.bind !== undefined || cap.compute !== undefined || cap.inject !== undefined;

  // D1 仅 declarative 可声明（有字段即拒，含空数组——空数组同样是「声明面被打开」的信号）
  if (declared && cap.requestGraph !== "declarative") {
    findings.push({
      level: "error",
      code: "D1_dataflow_requires_declarative",
      message: `capability '${cap.id}' 的 requestGraph=${cap.requestGraph ?? "<missing>"}，不得声明 bind/compute/inject（数据流是 declarative 专属，ADR-023 §2.2）`,
    });
    return findings; // 后续规则以 declarative 语义为前提，不再连锁报噪
  }
  if (!declared) return findings;

  // D13 🔒 信任门：正向 tier 允许表（防扩散，ADR-023 §2.6）
  if (!DATAFLOW_ALLOWED_TRUST_TIERS.has(trustTier ?? "")) {
    findings.push({
      level: "error",
      code: "D13_dataflow_trust_tier",
      message: `trustTier='${trustTier ?? "<missing>"}' 不在数据流允许表 {${[...DATAFLOW_ALLOWED_TRUST_TIERS].join(", ")}} 内：新增信任档不自动继承 bind/compute/inject 能力，须显式重新裁定（ADR-023 §2.6 防扩散条款）`,
    });
  }

  // D11-a 节点总数
  const nodeCount = binds.length + computes.length + injects.length;
  if (nodeCount > MAX_DATAFLOW_NODES) {
    findings.push({
      level: "error",
      code: "D11_too_many_nodes",
      message: `capability '${cap.id}' 的数据流节点数 ${nodeCount} 超过上限 ${MAX_DATAFLOW_NODES}（bind+compute+inject，ADR-023 §5 决策 3）`,
    });
  }

  const requestKeys = new Set((cap.requests ?? []).map((r) => r.key));
  /** 变量名 → 静态类型（D9 类型推导表）。 */
  const types = new Map<string, HandleType>();
  /** 变量名 → 引用深度（bind=0；compute=1+max(上游)）。 */
  const depths = new Map<string, number>();
  /** 变量名 → 其值可追溯到的上游 request key 集合（D15 请求依赖图用）。 */
  const originRequests = new Map<string, Set<string>>();
  /** 被引用过的变量（D14 死句柄告警用）。 */
  const referenced = new Set<string>();

  // ---- bind ----
  for (const b of binds) {
    const where = `capability '${cap.id}' 的 bind '${b.var}'`;

    // D3 变量名唯一
    if (types.has(b.var)) {
      findings.push({
        level: "error",
        code: "D3_duplicate_var",
        message: `${where}：变量名重复定义（bind ∪ compute 内须唯一）`,
      });
      continue;
    }

    // D2 from 指向已声明 request
    if (!requestKeys.has(b.from)) {
      findings.push({
        level: "error",
        code: "D2_bind_unknown_request",
        message: `${where}：from='${b.from}' 不是本 capability 已声明的 requests[].key`,
      });
    }

    // D4 extract 键集合与 source 严格对应
    findings.push(...checkExtractShape(b, where));

    // D5 regex 语法白名单
    if (b.source === "regex" && typeof b.extract?.pattern === "string") {
      const syntax = checkRegexSyntax(b.extract.pattern);
      if (syntax.reason !== null) {
        findings.push({
          level: "error",
          code: "D5_regex_syntax_rejected",
          message: `${where}：regex 语法被白名单拒绝——${syntax.reason}`,
        });
      } else {
        const group = b.extract.group ?? 0;
        if (group > syntax.groupCount) {
          findings.push({
            level: "error",
            code: "D5_regex_group_out_of_range",
            message: `${where}：group=${group} 超出模式串的捕获组数 ${syntax.groupCount}（0=整体匹配）`,
          });
        }
        if (group > MAX_REGEX_GROUP) {
          findings.push({
            level: "error",
            code: "D5_regex_group_out_of_range",
            message: `${where}：group=${group} 超过上限 ${MAX_REGEX_GROUP}`,
          });
        }
      }
    }

    // bind 产出恒为 text（三个抽取器都读文本）；深度 0。
    types.set(b.var, "text");
    depths.set(b.var, 0);
    originRequests.set(b.var, new Set(requestKeys.has(b.from) ? [b.from] : []));
  }

  // ---- compute ----
  for (const c of computes) {
    const where = `capability '${cap.id}' 的 compute '${c.var}'`;

    // D3 变量名唯一
    if (types.has(c.var)) {
      findings.push({
        level: "error",
        code: "D3_duplicate_var",
        message: `${where}：变量名重复定义（bind ∪ compute 内须唯一）`,
      });
      continue;
    }

    const sig = OP_SIGNATURES[c.op];
    if (sig === undefined) {
      findings.push({
        level: "error",
        code: "D8_unknown_op",
        message: `${where}：op='${c.op}' 不在封闭词表 {${Object.keys(OP_SIGNATURES).join(", ")}} 内`,
      });
      continue; // 无签名则后续元数/类型检查无从谈起
    }

    const args = c.args ?? [];

    // D11-b 每 op args 个数（纵深；schema maxItems 亦拦）
    if (args.length > MAX_OP_ARGS) {
      findings.push({
        level: "error",
        code: "D11_too_many_args",
        message: `${where}：args 个数 ${args.length} 超过上限 ${MAX_OP_ARGS}`,
      });
    }

    // D8 元数
    if (args.length < sig.minArgs || args.length > sig.maxArgs) {
      const expect = sig.minArgs === sig.maxArgs ? `${sig.minArgs}` : `${sig.minArgs}–${sig.maxArgs}`;
      findings.push({
        level: "error",
        code: "D8_op_arity_mismatch",
        message: `${where}：op='${c.op}' 需要 ${expect} 个 args，实得 ${args.length}`,
      });
    }

    // D8 params 键集合精确匹配 + 取值域
    findings.push(...checkOpParams(c, sig, where));

    // D6 / D7 / D9 / D10 逐参数
    let maxUpstreamDepth = -1;
    const origins = new Set<string>();
    let typeOk = true;

    for (let i = 0; i < args.length; i++) {
      const arg = args[i] ?? {};
      const hasRef = typeof arg.ref === "string";
      const hasText = typeof arg.text === "string";

      // D6 恰有 ref 或 text 之一
      if (hasRef === hasText) {
        findings.push({
          level: "error",
          code: "D6_bad_arg_shape",
          message: `${where}：args[${i}] 须**恰有** ref 或 text 之一（实得 ${hasRef && hasText ? "两者兼有" : "两者皆无"}）`,
        });
        typeOk = false;
        continue;
      }

      // D10 🔒 密钥位必须是 ref
      if (sig.refOnly.includes(i) && !hasRef) {
        findings.push({
          level: "error",
          code: "D10_literal_key_forbidden",
          message: `${where}：op='${c.op}' 的 args[${i}] 是密钥位，必须为 ref；manifest 是已签名分发的产物，字面量密钥等于公开（ADR-023 §5 决策 2）`,
        });
        typeOk = false;
        continue;
      }

      const accepted = sig.accepts[Math.min(i, sig.accepts.length - 1)] ?? TEXT;

      if (hasText) {
        // 字面量恒为 text
        if (!accepted.includes("text")) {
          findings.push({
            level: "error",
            code: "D9_type_mismatch",
            message: `${where}：args[${i}] 为文本字面量（text），但该位置只接受 {${accepted.join(", ")}}`,
          });
          typeOk = false;
        }
        continue;
      }

      const ref = arg.ref!;
      referenced.add(ref);

      // D7 引用闭合 + 无环：只能引用**声明序在前**的变量。
      // 声明序约束使数据流 DAG 结构上不可能成环，同时给出确定的求值顺序（两端一致）。
      const refType = types.get(ref);
      if (refType === undefined) {
        findings.push({
          level: "error",
          code: "D7_undefined_or_forward_ref",
          message: `${where}：args[${i}] 引用 '${ref}'——未定义，或声明序在本节点之后（禁前向引用，据此保证 DAG 无环）`,
        });
        typeOk = false;
        continue;
      }

      // D9 静态类型
      if (!accepted.includes(refType)) {
        findings.push({
          level: "error",
          code: "D9_type_mismatch",
          message: `${where}：args[${i}] 引用 '${ref}' 的类型为 ${refType}，但该位置只接受 {${accepted.join(", ")}}（bytes→text 唯一通道是 base64 / hex）`,
        });
        typeOk = false;
      }

      maxUpstreamDepth = Math.max(maxUpstreamDepth, depths.get(ref) ?? 0);
      for (const r of originRequests.get(ref) ?? []) origins.add(r);
    }

    const depth = maxUpstreamDepth + 1;
    // D11-c 引用嵌套深度
    if (depth > MAX_COMPUTE_DEPTH) {
      findings.push({
        level: "error",
        code: "D11_too_deep",
        message: `${where}：引用嵌套深度 ${depth} 超过上限 ${MAX_COMPUTE_DEPTH}`,
      });
    }

    // 类型有误时仍登记结果类型，避免下游连锁误报「未定义」淹没首因
    void typeOk;
    types.set(c.var, sig.result);
    depths.set(c.var, depth);
    originRequests.set(c.var, origins);
  }

  // ---- inject ----
  /** 已占用的静态汇聚点（into/at/name），用于查重。 */
  const sinks = new Set<string>();
  /** 请求依赖边：source request → 被注入的 request（D15）。 */
  const requestEdges: Array<{ from: string; to: string }> = [];

  for (const inj of injects) {
    const where = `capability '${cap.id}' 的 inject '${inj.var}' → ${inj.into}.${inj.at}:${inj.name}`;

    // D12 var 已定义
    const varType = types.get(inj.var);
    if (varType === undefined) {
      findings.push({
        level: "error",
        code: "D12_inject_undefined_var",
        message: `${where}：注入了未由 bind/compute 定义的变量 '${inj.var}'`,
      });
    } else {
      referenced.add(inj.var);
      // D9 注入面只接受 text
      if (varType !== "text") {
        findings.push({
          level: "error",
          code: "D9_type_mismatch",
          message: `${where}：句柄类型为 ${varType}，注入面（URL query / HTTP 头）只接受 text——bytes 须先经 base64 / hex 转换`,
        });
      }
    }

    // D12 into 指向已声明 request
    if (!requestKeys.has(inj.into)) {
      findings.push({
        level: "error",
        code: "D12_inject_unknown_request",
        message: `${where}：into='${inj.into}' 不是本 capability 已声明的 requests[].key`,
      });
    }

    // D12 静态汇聚点查重（同一 into/at/name 被注入两次 = 后者静默覆盖前者，语义不明）
    const sinkKey = `${inj.into} ${inj.at} ${inj.name.toLowerCase()}`;
    if (sinks.has(sinkKey)) {
      findings.push({
        level: "error",
        code: "D12_duplicate_sink",
        message: `${where}：同一汇聚点被重复注入（后者会静默覆盖前者）`,
      });
    }
    sinks.add(sinkKey);

    // D16 🔒 凭证头 / 逐跳头不得作为注入目标
    if (inj.at === "header" && INJECT_HEADER_DENYLIST.has(inj.name.toLowerCase())) {
      findings.push({
        level: "error",
        code: "D16_forbidden_inject_header",
        message: `${where}：请求头 '${inj.name}' 属凭证头 / 逐跳头，不得由数据流注入——凭证只由 broker 依 credentials 声明注入（红线 #1）`,
      });
    }

    for (const src of originRequests.get(inj.var) ?? []) {
      requestEdges.push({ from: src, to: inj.into });
    }
  }

  // D15 请求依赖图无环（含自环：注入的值取自被注入请求自身的响应）
  findings.push(...checkRequestCycles(cap.id, requestEdges));

  // D14 死句柄 → warn
  for (const name of types.keys()) {
    if (!referenced.has(name)) {
      findings.push({
        level: "warn",
        code: "D14_unused_handle",
        message: `capability '${cap.id}' 的句柄 '${name}' 定义后既未被 compute 引用也未被 inject：句柄永不进 adapter，该节点纯属死代码`,
      });
    }
  }

  return findings;
}

/** D4：extract 的键集合须与 source 严格对应，多余或缺失即拒。 */
function checkExtractShape(b: BindDecl, where: string): Finding[] {
  const findings: Finding[] = [];
  const required = EXTRACT_REQUIRED_KEYS[b.source];
  const optional = EXTRACT_OPTIONAL_KEYS[b.source];
  if (required === undefined || optional === undefined) {
    findings.push({
      level: "error",
      code: "D4_unknown_source",
      message: `${where}：source='${b.source}' 不在封闭词表 {header, body, regex} 内`,
    });
    return findings;
  }

  const present = Object.keys(b.extract ?? {});
  for (const key of required) {
    if (!present.includes(key)) {
      findings.push({
        level: "error",
        code: "D4_extract_shape",
        message: `${where}：source='${b.source}' 要求 extract.${key}，但缺失`,
      });
    }
  }
  const allowed = new Set([...required, ...optional]);
  for (const key of present) {
    if (!allowed.has(key)) {
      findings.push({
        level: "error",
        code: "D4_extract_shape",
        message: `${where}：source='${b.source}' 不接受 extract.${key}（允许键：${[...allowed].join(", ") || "无"}）`,
      });
    }
  }
  return findings;
}

/** D8：params 键集合须与 op 签名精确一致，且取值落在域内。 */
function checkOpParams(c: ComputeDecl, sig: OpSignature, where: string): Finding[] {
  const findings: Finding[] = [];
  const params = c.params ?? {};
  const expected = Object.keys(sig.params);
  const present = Object.keys(params);

  for (const key of expected) {
    if (!present.includes(key)) {
      findings.push({
        level: "error",
        code: "D8_missing_param",
        message: `${where}：op='${c.op}' 缺少必填 params.${key}（不设默认值——默认值会在两端漂移）`,
      });
    }
  }
  for (const key of present) {
    if (!expected.includes(key)) {
      findings.push({
        level: "error",
        code: "D8_unexpected_param",
        message: `${where}：op='${c.op}' 不接受 params.${key}（允许键：${expected.join(", ") || "无"}）`,
      });
      continue;
    }
    const spec = sig.params[key]!;
    const value = params[key];
    if (spec.kind === "int") {
      if (typeof value !== "number" || !Number.isInteger(value) || value < spec.min || value > spec.max) {
        findings.push({
          level: "error",
          code: "D8_param_out_of_range",
          message: `${where}：params.${key} 须为 [${spec.min}, ${spec.max}] 内的整数，实得 ${JSON.stringify(value)}`,
        });
      }
    } else if (typeof value !== "string" || !spec.values.includes(value)) {
      findings.push({
        level: "error",
        code: "D8_param_out_of_range",
        message: `${where}：params.${key} 须 ∈ {${spec.values.join(", ")}}，实得 ${JSON.stringify(value)}`,
      });
    }
  }
  return findings;
}

/**
 * D15：请求依赖图无环。
 *
 * `inject` 让目标请求依赖「句柄可追溯到的全部上游请求」。若这些上游里含目标请求自身
 * （直接或经他跳），拓扑序不存在——broker 无从决定先发哪个，运行期只能死锁或任意破环。
 * 必须在声明期拒绝。
 */
function checkRequestCycles(capId: string, edges: Array<{ from: string; to: string }>): Finding[] {
  if (edges.length === 0) return [];
  const adjacency = new Map<string, Set<string>>();
  for (const e of edges) {
    if (!adjacency.has(e.from)) adjacency.set(e.from, new Set());
    adjacency.get(e.from)!.add(e.to);
  }

  const WHITE = 0;
  const GRAY = 1;
  const BLACK = 2;
  const color = new Map<string, number>();
  const cycles: string[] = [];

  const visit = (node: string, path: string[]): void => {
    color.set(node, GRAY);
    path.push(node);
    for (const next of adjacency.get(node) ?? []) {
      const state = color.get(next) ?? WHITE;
      if (state === GRAY) {
        const start = path.indexOf(next);
        cycles.push([...path.slice(start === -1 ? 0 : start), next].join(" → "));
      } else if (state === WHITE) {
        visit(next, path);
      }
    }
    path.pop();
    color.set(node, BLACK);
  };

  for (const node of adjacency.keys()) {
    if ((color.get(node) ?? WHITE) === WHITE) visit(node, []);
  }

  return cycles.map((cycle) => ({
    level: "error" as const,
    code: "D15_request_cycle",
    message: `capability '${capId}' 的请求依赖成环：${cycle}（inject 使目标请求依赖句柄的全部上游请求，无拓扑序可执行）`,
  }));
}
