/**
 * adapter 校验器（CI 闸门）。契约校验用 ajv，与服务端共用同一套 schema。
 *
 * 检查项：
 *  C1 manifest 对 contract/manifest.schema.json 的合规性（ajv）
 *  C2 capability id ∈ registry.json，且 emits.schema/version 与 registry 一致（防漂移）
 *  C3 sideload 信任档**强制** parser 模式（拒绝 sideload + fetch，分发/签名路径，红线 #5）
 *  C4 网络白名单：fetch 模式须有 allow；parser 的每条 requests.url 须被 allow 覆盖
 *  C5 夹具：fixtures/*.json 的 expected 须通过该 capability 的 emits schema
 *  C6 凭证作用域：credentials.<name>.scope 每条须 ⊆ network.allow（ADR-013 §2.4 规则 1）
 *  C7 作用域消歧：不同凭证的 scope 前缀长度相同且重叠 → 拒绝（ADR-013 §2.4 规则 2 / ADR-009 §2.3b）
 *  C8 引用闭合：parser 的 requests.credential 须在 credentials 声明；声明未用 → warn（ADR-013 §2.4 规则 3）
 *  C9 凭证注入方式：credentials.<name>.type ∈ {cookie, header}（防御性，schema C1 亦拦）
 *  L1–L4 login 声明（ADR-015）：url 须 https（L1）；url ⊆ navigationAllow（L2）；
 *    success.whenUrlMatches 每条 ⊆ navigationAllow（L3）；login 存在但 credentials 空 → warn（L4）
 *  M1–M5 SSO 静默签票声明（ADR-017）：authEndpoint 须 https 且 ⊆ navigationAllow（M1）；
 *    每个 services[*].service 与 success ⊆ navigationAllow（M2）；services 键须 ∈ credentials（M3）；
 *    母凭证 ref（scope 覆盖 authEndpoint 者）须存在且 scope 不与下游数据域重叠（M4）；
 *    services[*].via 须为本 manifest 声明的 capability 且 official（M5，红线 #1 门禁，类比 C3）
 *
 * 尚未覆盖（留给优先级 #3 客户端落地）：
 *  - 完整 golden 双跑：客户端 QuickJS 与服务端 QuickJS-wasm 对同一夹具产出比对。
 *    服务端单引擎 golden 已由 server/src/runtime/sandbox.smoke.ts 证明。
 *    本校验器只做"夹具 expected 合 schema"这一不依赖沙箱的部分（见 C5）。
 *
 *   运行：cd tools && npm run validate                  # 校验 adapters/ 下全部
 *         cd tools && npm run validate -- --adapter=../adapters/_template/parser
 */

import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { allowToRegex, scopePrefix, urlCoveredByAllow } from "@elecon/broker-primitives";
import { Ajv2020, type ValidateFunction } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

// TS 侧 url-match 单源在 @elecon/broker-primitives（审阅 P2-4，原本文件内联拷贝已删）。
// re-export 保持既有 API 面（url-match.smoke.ts 经此面验证"校验器实际使用的实现"合 golden）。
export { allowToRegex, scopePrefix, urlCoveredByAllow };

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const contractDir = join(repoRoot, "contract");
// adapter 发现根：默认 repoRoot/adapters；ELECON_ADAPTERS_ROOT 可覆盖（相对 CWD 解析）。
// 用于镜像后的公开仓（ADR-018 §2.8）：vendored 校验器在 vendor/ 下，被校验的社区 adapter
// 却在仓库根 adapters/——二者不同根，故 discovery 路径必须可配。contract/stdlib 仍随 vendor 走。
const adaptersRoot = process.env.ELECON_ADAPTERS_ROOT
  ? resolve(process.env.ELECON_ADAPTERS_ROOT)
  : join(repoRoot, "adapters");

// ---- 类型 ----

export type Level = "error" | "warn";

export interface Finding {
  level: Level;
  code: string;
  message: string;
}

interface RegistryEntry {
  emits: { schema: string; schemaVersion: string };
  params?: { schema: string; schemaVersion: string };
}

interface CapabilityDecl {
  id: string;
  emits: { schema: string; schemaVersion: string };
  params?: { schema: string; schemaVersion: string };
  requests?: Array<{ key: string; method: string; url: string; credential?: string }>;
}

interface CredentialDecl {
  scope: string[];
  type: "cookie" | "header";
  /** 凭证角色（ADR-017）。sso-master=CAS 母凭证。可选；缺省=普通下游凭证。 */
  role?: "sso-master";
}

/** ssoMint 单个下游服务（ADR-017 §2.5）。 */
interface SsoMintService {
  service: string;
  success: string[];
  /** 非简单 GET-redirect 时指向承载 mint 请求构造的 adapter 能力 id（M5）。 */
  via?: string;
}

/** CAS SSO 静默签票声明（ADR-017 §2.5）。可选。 */
interface SsoMintDecl {
  authEndpoint: string;
  services: Record<string, SsoMintService>;
}

/** WebView 登录声明（ADR-015）。可选；仅带凭证学校声明。 */
interface LoginDecl {
  url: string;
  navigationAllow: string[];
  success: { whenUrlMatches: string[] };
  /** CAS SSO 静默签票（ADR-017）。可选；缺省=逐服务可见登录。 */
  ssoMint?: SsoMintDecl;
}

interface Manifest {
  adapterId: string;
  trustTier: "official" | "sideload";
  mode: "fetch" | "parser";
  /** 运行时声明。stdlibMin=依赖的 elecon:html stdlib 最低版本（ADR-018 §2.4）。可选。 */
  runtime?: { engine?: string; entry?: string; stdlibMin?: string };
  network: { allow: string[] };
  /** 凭证引用声明（ADR-013）。可选；缺省即无凭证注入。 */
  credentials?: Record<string, CredentialDecl>;
  /** WebView 登录配置（ADR-015）。可选；缺省即无 WebView 登录。 */
  login?: LoginDecl;
  capabilities: CapabilityDecl[];
}

interface Contract {
  manifestValidate: ValidateFunction;
  registry: Record<string, RegistryEntry>;
  /** 按 schema $id 取域 schema 的校验函数；未落盘的返回 undefined。 */
  schemaFor: (id: string) => ValidateFunction | undefined;
  /** 当前可用的 elecon:html stdlib 版本（读自 adapters/_stdlib/package.json）；读不到=null（C10 降级为 warn）。 */
  stdlibVersion: string | null;
}

/**
 * 极简 semver 比较（仅 x.y.z 数字段）。**刻意自包含**——不依赖 `tools/src/signer`，
 * 因为签名工具属私有核心、不随镜像发布给公开 adapters 仓（ADR-018 §2.8 所有权），
 * validator 必须能在镜像后的公开仓独立运行。
 */
function cmpSemver(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

// ---- 契约加载 ----

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

export function loadContract(): Contract {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);

  const manifestSchema = readJson<Record<string, unknown>>(join(contractDir, "manifest.schema.json"));
  const manifestValidate = ajv.compile(manifestSchema);

  const registryRaw = readJson<{ capabilities: Record<string, RegistryEntry> }>(
    join(contractDir, "capability", "registry.json"),
  );

  // 把所有已落盘的域 schema 编进同一个 ajv，按 $id 索引
  const schemaDir = join(contractDir, "schema");
  for (const file of readdirSync(schemaDir)) {
    if (!file.endsWith(".schema.json")) continue;
    const schema = readJson<Record<string, unknown>>(join(schemaDir, file));
    const id = typeof schema.$id === "string" ? schema.$id : undefined;
    if (id && !ajv.getSchema(id)) {
      ajv.addSchema(schema);
    }
  }

  // 当前 stdlib 版本（供 C10 stdlibMin 校验）。读不到不致命 → null，C10 降级 warn。
  let stdlibVersion: string | null = null;
  try {
    const pkg = readJson<{ version?: string }>(join(repoRoot, "adapters", "_stdlib", "package.json"));
    stdlibVersion = typeof pkg.version === "string" ? pkg.version : null;
  } catch {
    stdlibVersion = null;
  }

  return {
    manifestValidate,
    registry: registryRaw.capabilities,
    schemaFor: (id) => ajv.getSchema(id) as ValidateFunction | undefined,
    stdlibVersion,
  };
}

// ---- C1–C4：manifest 静态检查（纯函数，便于测试）----

export function checkManifest(
  manifest: Manifest,
  contract: Pick<Contract, "manifestValidate" | "registry"> & { stdlibVersion?: string | null },
): Finding[] {
  const findings: Finding[] = [];

  // C1 schema 合规
  if (!contract.manifestValidate(manifest)) {
    for (const err of contract.manifestValidate.errors ?? []) {
      findings.push({
        level: "error",
        code: "C1_manifest_schema",
        message: `manifest${err.instancePath} ${err.message}`,
      });
    }
    // schema 不合规时后续按字段假设可能不成立，但仍尽量继续给出更多线索
  }

  // C10 stdlibMin ≤ 当前可用 stdlib 版本（ADR-018 §2.4 B-host + append-only）。
  // stdlibMin 可选;声明了但高于当前 stdlib → 加载器会 fail-closed 拒载，作者期即拦。
  const stdlibMin = manifest.runtime?.stdlibMin;
  if (stdlibMin) {
    if (contract.stdlibVersion == null) {
      findings.push({
        level: "warn",
        code: "C10_stdlib_version_unknown",
        message: `声明 runtime.stdlibMin=${stdlibMin}，但读不到当前 stdlib 版本，跳过校验`,
      });
    } else if (cmpSemver(stdlibMin, contract.stdlibVersion) > 0) {
      findings.push({
        level: "error",
        code: "C10_stdlibmin_too_high",
        message: `runtime.stdlibMin=${stdlibMin} 高于当前可用 stdlib ${contract.stdlibVersion}：加载器将 fail-closed 拒载（ADR-018 §2.4）`,
      });
    }
  }

  // C3 sideload ⟹ parser（红线 #5）
  if (manifest.trustTier === "sideload" && manifest.mode !== "parser") {
    findings.push({
      level: "error",
      code: "C3_sideload_must_parser",
      message: `sideload 信任档必须为 parser 模式（无网络/无凭证），当前 mode=${manifest.mode}`,
    });
  }

  const allow = manifest.network?.allow ?? [];

  // C4-a fetch 模式须声明白名单
  if (manifest.mode === "fetch" && allow.length === 0) {
    findings.push({
      level: "error",
      code: "C4_fetch_empty_allow",
      message: "fetch 模式 network.allow 为空：无任何域名可注入凭证，adapter 取不到数",
    });
  }

  // 非 https 白名单项 → 警告
  for (const pattern of allow) {
    if (!/^https:\/\//.test(pattern)) {
      findings.push({ level: "warn", code: "C4_non_https_allow", message: `白名单项非 https：${pattern}` });
    }
  }

  for (const cap of manifest.capabilities ?? []) {
    // C2 capability ∈ registry
    const reg = contract.registry[cap.id];
    if (!reg) {
      findings.push({
        level: "error",
        code: "C2_unregistered_capability",
        message: `capability '${cap.id}' 未在 registry.json 注册`,
      });
      continue;
    }
    // C2 emits 与 registry 一致（防 schema 漂移）
    if (cap.emits?.schema !== reg.emits.schema || cap.emits?.schemaVersion !== reg.emits.schemaVersion) {
      findings.push({
        level: "error",
        code: "C2_emits_mismatch",
        message: `capability '${cap.id}' 的 emits 与 registry 不符：manifest=${cap.emits?.schema}@${cap.emits?.schemaVersion}，registry=${reg.emits.schema}@${reg.emits.schemaVersion}`,
      });
    }
    const declaredParams = cap.params;
    const registeredParams = reg.params;
    if (
      registeredParams &&
      declaredParams &&
      (declaredParams.schema !== registeredParams.schema ||
        declaredParams.schemaVersion !== registeredParams.schemaVersion)
    ) {
      findings.push({
        level: "error",
        code: "C2_params_mismatch",
        message: `capability '${cap.id}' 的 params 与 registry 不符：manifest=${declaredParams?.schema ?? "<missing>"}@${declaredParams?.schemaVersion ?? "<missing>"}，registry=${registeredParams.schema}@${registeredParams.schemaVersion}`,
      });
    } else if (!registeredParams && declaredParams) {
      findings.push({
        level: "error",
        code: "C2_unexpected_params",
        message: `capability '${cap.id}' 未在 registry 声明 params，但 manifest 提供了 params`,
      });
    }

    // C4-b parser 模式：每条 requests.url 须被白名单覆盖
    if (manifest.mode === "parser") {
      const requests = cap.requests ?? [];
      if (requests.length === 0) {
        findings.push({
          level: "warn",
          code: "C4_parser_no_requests",
          message: `parser capability '${cap.id}' 未声明 requests：核心无从代取数据`,
        });
      }
      for (const req of requests) {
        if (!urlCoveredByAllow(req.url, allow)) {
          findings.push({
            level: "error",
            code: "C4_request_outside_allow",
            message: `capability '${cap.id}' 的 request '${req.key}' 越出白名单：${req.url}`,
          });
        }
      }
    }
  }

  // C6–C8 凭证声明检查（ADR-013 §2.4）。credentials 可选；缺省即跳过。
  findings.push(...checkCredentials(manifest, allow));

  // L1–L4 WebView 登录声明检查（ADR-015）。login 可选；缺省即跳过。
  findings.push(...checkLogin(manifest));

  // M1–M5 SSO 静默签票声明检查（ADR-017）。login.ssoMint 可选；缺省即跳过。
  findings.push(...checkSsoMint(manifest));

  return findings;
}

// ---- L1–L4：login 声明（ADR-015 §2.2）----

export function checkLogin(manifest: Pick<Manifest, "login" | "credentials">): Finding[] {
  const findings: Finding[] = [];
  const login = manifest.login;
  if (!login) return findings; // 可选；缺省跳过

  const navAllow = login.navigationAllow ?? [];

  // L1 登录页须 https（凭证经手页面，TLS 底线）；navigationAllow 非 https → 警告
  if (!/^https:\/\//.test(login.url ?? "")) {
    findings.push({
      level: "error",
      code: "L1_login_url_not_https",
      message: `login.url 非 https：${login.url}`,
    });
  }
  for (const p of navAllow) {
    if (!/^https:\/\//.test(p)) {
      findings.push({
        level: "warn",
        code: "L1_non_https_nav",
        message: `login.navigationAllow 项非 https：${p}`,
      });
    }
  }

  // L2 login.url 须落在 navigationAllow 内（WebView 起始页须可导航）
  if (login.url && !urlCoveredByAllow(login.url, navAllow)) {
    findings.push({
      level: "error",
      code: "L2_login_url_outside_nav",
      message: `login.url 不在 navigationAllow 内（WebView 起始页不可达）：${login.url}`,
    });
  }

  // L3 success.whenUrlMatches 每条须 ⊆ navigationAllow（否则 WebView 拦截导航、永不判成功）
  for (const p of login.success?.whenUrlMatches ?? []) {
    if (!urlCoveredByAllow(p, navAllow)) {
      findings.push({
        level: "error",
        code: "L3_success_url_outside_nav",
        message: `login.success.whenUrlMatches 越出 navigationAllow（WebView 拦截，永不判成功）：${p}`,
      });
    }
  }

  // L4 login 存在 ⟹ credentials 非空（登录建立 session，但无声明 ref 则收割判据 b 丢弃一切）
  if (Object.keys(manifest.credentials ?? {}).length === 0) {
    findings.push({
      level: "warn",
      code: "L4_login_without_credentials",
      message: "声明了 login 但 credentials 为空：登录建立的 session 无声明 ref，收割（判据 b）将丢弃一切",
    });
  }

  return findings;
}

// ---- M1–M5：SSO 静默签票声明（ADR-017 §2.5）----

/**
 * 校验 login.ssoMint（CAS 母凭证静默换票声明）。ssoMint 可选；缺省跳过。
 * 只做可静态验证的部分——**不碰凭证值、不模拟换票**（红线 #1，实现在核心 + official adapter）。
 */
export function checkSsoMint(
  manifest: Pick<Manifest, "login" | "credentials" | "capabilities" | "trustTier">,
): Finding[] {
  const findings: Finding[] = [];
  const login = manifest.login;
  const mint = login?.ssoMint;
  if (!login || !mint) return findings; // 可选；缺省跳过

  const navAllow = login.navigationAllow ?? [];
  const creds = manifest.credentials ?? {};
  const capIds = new Set((manifest.capabilities ?? []).map((c) => c.id));
  const authEndpoint = mint.authEndpoint ?? "";

  // M1 authEndpoint 须 https 且落在 navigationAllow 内
  if (!/^https:\/\//.test(authEndpoint)) {
    findings.push({
      level: "error",
      code: "M1_auth_endpoint_not_https",
      message: `ssoMint.authEndpoint 非 https：${authEndpoint}`,
    });
  }
  if (authEndpoint && !urlCoveredByAllow(authEndpoint, navAllow)) {
    findings.push({
      level: "error",
      code: "M1_auth_endpoint_outside_nav",
      message: `ssoMint.authEndpoint 不在 navigationAllow 内（WebView 换票不可达）：${authEndpoint}`,
    });
  }

  // M2/M3/M5 逐服务
  for (const [ref, svc] of Object.entries(mint.services ?? {})) {
    // M2 service ⊆ navigationAllow
    if (svc.service && !urlCoveredByAllow(svc.service, navAllow)) {
      findings.push({
        level: "error",
        code: "M2_service_outside_nav",
        message: `ssoMint.services['${ref}'].service 越出 navigationAllow：${svc.service}`,
      });
    }
    // M2 success 每条 ⊆ navigationAllow
    for (const p of svc.success ?? []) {
      if (!urlCoveredByAllow(p, navAllow)) {
        findings.push({
          level: "error",
          code: "M2_success_outside_nav",
          message: `ssoMint.services['${ref}'].success 越出 navigationAllow（换票永不判成功）：${p}`,
        });
      }
    }
    // M3 换票产物 ref 须在 credentials 声明（否则收割判据 b 丢弃）
    if (!(ref in creds)) {
      findings.push({
        level: "error",
        code: "M3_service_ref_undeclared",
        message: `ssoMint.services 键 '${ref}' 未在 credentials 声明：换票产物无 ref 可收割`,
      });
    }
    // M5 via ⟹ official + 引用本 manifest 声明的 capability（红线 #1 门禁，类比 C3）
    if (svc.via !== undefined) {
      if (manifest.trustTier !== "official") {
        findings.push({
          level: "error",
          code: "M5_via_requires_official",
          message: `ssoMint.services['${ref}'].via='${svc.via}' 声明了 adapter mint 能力，但 trustTier=${manifest.trustTier}（敏感能力仅 official，红线 #5/#1）`,
        });
      }
      if (!capIds.has(svc.via)) {
        findings.push({
          level: "error",
          code: "M5_via_undeclared_capability",
          message: `ssoMint.services['${ref}'].via 引用未在本 manifest 声明的 capability '${svc.via}'`,
        });
      }
    }
  }

  // M4 母凭证：须有 credential 的 scope 覆盖 authEndpoint，且其 scope 不与任何下游数据域重叠
  const masterRefs = Object.keys(creds).filter((name) =>
    (creds[name]?.scope ?? []).some((s) => urlCoveredByAllow(authEndpoint, [s])),
  );
  if (authEndpoint && masterRefs.length === 0) {
    findings.push({
      level: "error",
      code: "M4_no_master_credential",
      message: `ssoMint.authEndpoint 无母凭证承接（无 credential 的 scope 覆盖 ${authEndpoint}）：静默换票无票可用`,
    });
  }
  const downstream = Object.keys(creds).filter((n) => !masterRefs.includes(n));
  for (const m of masterRefs) {
    for (const ms of creds[m]?.scope ?? []) {
      for (const d of downstream) {
        const overlap = (creds[d]?.scope ?? []).some((ds) =>
          prefixesOverlap(scopePrefix(ms), scopePrefix(ds)),
        );
        if (overlap) {
          findings.push({
            level: "error",
            code: "M4_master_scope_overlaps_downstream",
            message: `母凭证 '${m}' 的 scope '${ms}' 与下游凭证 '${d}' 域重叠：母凭证可能被注入数据请求（红线 #1 外泄）`,
          });
        }
      }
    }
  }
  // role 一致性：声明 role=sso-master 却非母凭证（scope 不覆盖 authEndpoint）→ warn
  for (const name of Object.keys(creds)) {
    if (creds[name]?.role === "sso-master" && !masterRefs.includes(name)) {
      findings.push({
        level: "warn",
        code: "M4_role_not_master",
        message: `credential '${name}' 标注 role=sso-master 但其 scope 未覆盖 ssoMint.authEndpoint`,
      });
    }
  }

  return findings;
}

// ---- C6–C8：credentials 声明（ADR-013 §2.4）----

/**
 * 两个 scope 前缀是否重叠（其一是另一的字符串前缀，含相等）。
 * **注**：C7 在 `pa.length === pb.length` 守卫下调用本函数——等长 + 互为前缀 ⟺ 相等，
 * 故 C7 实质只在"前缀完全相同"时触发。等长但不相等的前缀（如 `/api/` vs `/apx/`）匹配的
 * URL 集合互斥、无注入歧义，正确地不被判错；不同长度的重叠由运行时最长前缀胜出消解。
 */
function prefixesOverlap(a: string, b: string): boolean {
  return a.startsWith(b) || b.startsWith(a);
}

export function checkCredentials(
  manifest: Pick<Manifest, "credentials" | "mode" | "capabilities">,
  allow: string[],
): Finding[] {
  const findings: Finding[] = [];
  const creds = manifest.credentials ?? {};
  const credNames = Object.keys(creds);

  // 收集所有 scope 条目（带所属凭证名），供 C6/C7 使用
  const scopes: Array<{ name: string; pattern: string }> = [];
  for (const name of credNames) {
    const decl = creds[name];
    if (!decl) continue;

    // C9（防御性，schema C1 亦拦）：type 合法
    if (decl.type !== "cookie" && decl.type !== "header") {
      findings.push({
        level: "error",
        code: "C9_bad_credential_type",
        message: `credential '${name}' 的 type 非法：${String(decl.type)}（须为 cookie | header）`,
      });
    }

    for (const pattern of decl.scope ?? []) {
      scopes.push({ name, pattern });
      // C6 scope ⊆ network.allow
      if (!urlCoveredByAllow(pattern, allow)) {
        findings.push({
          level: "error",
          code: "C6_scope_outside_allow",
          message: `credential '${name}' 的 scope 越出 network.allow：${pattern}（不能注入一个连出口都不允许的 URL）`,
        });
      }
    }
  }

  // C7 作用域消歧：不同凭证的 scope，前缀长度相同且重叠 = 歧义 → 拒绝。
  // （长度不同的重叠由运行时"最长前缀胜出"消解，非错误。）
  for (let i = 0; i < scopes.length; i++) {
    for (let j = i + 1; j < scopes.length; j++) {
      const a = scopes[i]!;
      const b = scopes[j]!;
      if (a.name === b.name) continue; // 同一凭证内部重叠无歧义
      const pa = scopePrefix(a.pattern);
      const pb = scopePrefix(b.pattern);
      if (pa.length === pb.length && prefixesOverlap(pa, pb)) {
        findings.push({
          level: "error",
          code: "C7_ambiguous_credential_scope",
          message: `credential '${a.name}' 与 '${b.name}' 的 scope 前缀等长且重叠，注入歧义：'${a.pattern}' vs '${b.pattern}'`,
        });
      }
    }
  }

  // C8 引用闭合：parser 的 requests.credential 须在 credentials 声明；声明未用 → warn。
  const referenced = new Set<string>();
  if (manifest.mode === "parser") {
    for (const cap of manifest.capabilities ?? []) {
      for (const req of cap.requests ?? []) {
        if (req.credential === undefined) continue;
        referenced.add(req.credential);
        if (!(req.credential in creds)) {
          findings.push({
            level: "error",
            code: "C8_undeclared_credential_ref",
            message: `capability '${cap.id}' 的 request '${req.key}' 引用未声明的 credential '${req.credential}'`,
          });
        }
      }
    }
    // 仅 parser 模式判定"声明未用"：fetch 模式凭证按 scope 隐式使用，不告警。
    for (const name of credNames) {
      if (!referenced.has(name)) {
        findings.push({
          level: "warn",
          code: "C8_unused_credential",
          message: `credential '${name}' 已声明但无 request 引用（parser 模式）`,
        });
      }
    }
  }

  return findings;
}

// ---- C11：bundle 体积上限（红线 #5 越薄;ADR-018 §2.9）----

/**
 * bundle 体积上限（超限 → 加载前拒,把"脚本非常大"在提交期挡掉,而非靠容器兜底）。
 * BUNDLE_INCLUDE/EXCLUDE **须与 tools/src/signer 保持一致**——validator 不能 import signer
 * （signer 不随镜像发布,ADR-018 §2.8 所有权）,故本地复刻;二者漂移会使"校验的"与"签名的"文件集不一致。
 */
const BUNDLE_INCLUDE = /\.(json|js|mjs|ts|html?|css|txt|svg|png)$/i;
const BUNDLE_EXCLUDE = /(^|\/)(signature\.json|node_modules|\.git|fixtures)(\/|$)/;
export const MAX_BUNDLE_BYTES = 256 * 1024; // 256 KiB

/** 纯：据总字节判定是否超限（便于单测,不碰文件系统）。 */
export function checkBundleSizeBytes(totalBytes: number): Finding[] {
  if (totalBytes > MAX_BUNDLE_BYTES) {
    return [
      {
        level: "error",
        code: "C11_bundle_too_large",
        message: `bundle 文件总计 ${totalBytes} 字节，超过上限 ${MAX_BUNDLE_BYTES}（红线 #5 越薄,ADR-018 §2.9）`,
      },
    ];
  }
  return [];
}

/** 汇总 BUNDLE_INCLUDE 文件（排除 fixtures 等）的总字节。 */
export function sumBundleBytes(dir: string): number {
  let total = 0;
  const walk = (d: string): void => {
    for (const entry of readdirSync(d)) {
      const p = join(d, entry);
      if (BUNDLE_EXCLUDE.test(relative(dir, p))) continue;
      if (statSync(p).isDirectory()) walk(p);
      else if (BUNDLE_INCLUDE.test(entry)) total += statSync(p).size;
    }
  };
  walk(dir);
  return total;
}

function checkBundleSize(dir: string): Finding[] {
  return checkBundleSizeBytes(sumBundleBytes(dir));
}

// ---- C5：夹具 expected 合 schema（不依赖沙箱）----

function checkFixtures(dir: string, manifest: Manifest, contract: Contract): Finding[] {
  const findings: Finding[] = [];
  const fixturesDir = join(dir, "fixtures");
  if (!existsSync(fixturesDir)) return findings;

  const byCapability = new Map(manifest.capabilities.map((c) => [c.id, c]));

  for (const file of readdirSync(fixturesDir)) {
    if (!file.endsWith(".json")) continue;
    const fx = readJson<{ kind?: string; capability?: string; expected?: unknown }>(join(fixturesDir, file));
    // fetch-replay fixture 的 expected 由 FakeTransport replay runner 断言；C5
    // 只负责 parser 的静态 expected schema 校验，避免把两种 fixture 语义混为一谈。
    if (fx.kind === "fetch-replay") continue;
    if (!fx.capability || fx.expected === undefined) {
      findings.push({
        level: "warn",
        code: "C5_fixture_shape",
        message: `fixtures/${file} 缺 capability 或 expected，跳过`,
      });
      continue;
    }
    const cap = byCapability.get(fx.capability);
    if (!cap) {
      findings.push({
        level: "error",
        code: "C5_fixture_unknown_capability",
        message: `fixtures/${file} 引用了 manifest 未声明的 capability '${fx.capability}'`,
      });
      continue;
    }
    const validate = contract.schemaFor(cap.emits.schema);
    if (!validate) {
      findings.push({
        level: "warn",
        code: "C5_schema_absent",
        message: `schema '${cap.emits.schema}' 尚未落盘，无法校验 fixtures/${file}`,
      });
      continue;
    }
    if (!validate(fx.expected)) {
      for (const err of validate.errors ?? []) {
        findings.push({
          level: "error",
          code: "C5_fixture_invalid",
          message: `fixtures/${file} expected${err.instancePath} ${err.message}`,
        });
      }
    }
  }
  return findings;
}

// ---- 编排 ----

export function validateAdapterDir(dir: string, contract: Contract): Finding[] {
  const manifestPath = join(dir, "manifest.json");
  if (!existsSync(manifestPath)) {
    return [{ level: "error", code: "no_manifest", message: `${dir} 下无 manifest.json` }];
  }
  let manifest: Manifest;
  try {
    manifest = readJson<Manifest>(manifestPath);
  } catch (err) {
    return [
      {
        level: "error",
        code: "manifest_unparseable",
        message: `manifest.json 解析失败：${(err as Error).message}`,
      },
    ];
  }
  return [
    ...checkManifest(manifest, contract),
    ...checkBundleSize(dir),
    ...checkFixtures(dir, manifest, contract),
  ];
}

/** 递归发现 adapters/ 下含 manifest.json 的目录。 */
function discoverAdapters(root: string): string[] {
  const out: string[] = [];
  const walk = (d: string): void => {
    if (existsSync(join(d, "manifest.json"))) {
      out.push(d);
      return; // adapter 目录不再下钻
    }
    for (const entry of readdirSync(d)) {
      const p = join(d, entry);
      if (statSync(p).isDirectory()) walk(p);
    }
  };
  walk(root);
  return out;
}

function main(): void {
  const arg = process.argv.find((a) => a.startsWith("--adapter="));
  const contract = loadContract();

  const dirs = arg ? [arg.slice("--adapter=".length)] : discoverAdapters(adaptersRoot);
  if (dirs.length === 0) {
    console.log("没有发现任何 adapter。");
    return;
  }

  let errorCount = 0;
  for (const dir of dirs) {
    const findings = validateAdapterDir(dir, contract);
    const errors = findings.filter((f) => f.level === "error");
    const warns = findings.filter((f) => f.level === "warn");
    errorCount += errors.length;

    const label = basename(dir);
    if (findings.length === 0) {
      console.log(`✓ ${label}`);
    } else {
      console.log(`${errors.length ? "✗" : "•"} ${label}  (${errors.length} error, ${warns.length} warn)`);
      for (const f of findings) {
        console.log(`    ${f.level === "error" ? "✗" : "⚠"} [${f.code}] ${f.message}`);
      }
    }
  }

  if (errorCount > 0) {
    console.error(`\n校验失败：${errorCount} 个 error。`);
    process.exit(1);
  }
  console.log("\n校验通过。");
}

// 仅在被直接执行时跑 CLI；被 import（如 smoke 测试）时不触发。
const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
