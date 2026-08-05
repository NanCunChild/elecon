/**
 * Response Masker 策略组合校验（ADR-026 §2 / §6）。
 *
 * 🔒 安全承重路径（红线 #1/#5/#6）：JSON Schema 只封闭字段形状；本模块校验策略与
 * manifest 的 capability、network.allow、credential ref 和 ADR-023 bind 引用是否闭合。
 * `masker.json` 只在 official 签名 bundle 中生效，且旧 host 未具备拒载门前不得发布。
 */

import { scopePrefix, urlCoveredByAllow } from "@elecon/broker-primitives";
import type { ValidateFunction } from "ajv";
import type { BindDecl } from "./dataflow.js";
import type { Finding } from "./index.js";

export const MAX_MASKER_FILE_BYTES = 256 * 1024;

interface MaskerMatch {
  capability: string;
  requestKey?: string;
  method: "GET" | "POST";
  urlScope: string;
}

interface MaskerDestination {
  kind: "credential" | "handle" | "redact";
  ref?: string;
}

interface MaskerCapture {
  source?: "header" | "json";
  name?: string;
  path?: string;
  required: true;
  exactly: 1;
  destination: MaskerDestination;
}

export interface ResponseMaskerRule {
  id: string;
  match: MaskerMatch;
  capture: MaskerCapture;
  project: "delete" | "replace";
}

export interface ResponseMaskerPolicy {
  schemaVersion: 1;
  rules: ResponseMaskerRule[];
}

interface MaskerCapability {
  id: string;
  requestGraph: "declarative" | "imperative";
  requests?: Array<{ key: string; method: string; url: string }>;
  bind?: BindDecl[];
}

export interface ResponseMaskerManifest {
  trustTier: "official" | "sideload";
  network: { allow: string[] };
  credentials?: Record<string, { scope: string[]; type: string }>;
  capabilities: MaskerCapability[];
}

function error(code: string, message: string): Finding {
  return { level: "error", code, message };
}

/**
 * V1 scope 只接受既有 Broker 约定的 exact 或单个尾随 `*` 前缀模板。
 * 用范围内探针而非模板字符串本身做 allow 覆盖判断，避免把 `*` 当普通字符误判。
 */
function scopeCoveredByAllow(scope: string, allow: readonly string[]): boolean {
  // Acquisition scope 表示最终 URL 的集合；V1 不接受会展开为集合但无法做包含证明的 `{param}`。
  if (scope.includes("{") || scope.includes("}")) return false;
  const firstStar = scope.indexOf("*");
  if (firstStar !== -1 && firstStar !== scope.length - 1) return false;
  if (firstStar !== -1 && scope.indexOf("*", firstStar + 1) !== -1) return false;
  if (firstStar === -1) return urlCoveredByAllow(scope, allow);

  const sourcePrefix = scopePrefix(scope);
  return allow.some((allowed) => {
    const allowedStar = allowed.indexOf("*");
    if (allowedStar === -1 || allowedStar !== allowed.length - 1) return false;
    return sourcePrefix.startsWith(scopePrefix(allowed));
  });
}

/** 与 ADR-023 runtime 相同的封闭 JSONPath 语法：$、.key、['key']、["key"]、[n]。 */
function validJsonPath(path: string): boolean {
  if (!path.startsWith("$")) return false;
  let i = 1;
  while (i < path.length) {
    if (path[i] === ".") {
      i++;
      const start = i;
      while (i < path.length && /[A-Za-z0-9_]/.test(path[i]!)) i++;
      if (i === start) return false;
      continue;
    }
    if (path[i] === "[") {
      const close = path.indexOf("]", i);
      if (close === -1) return false;
      const inner = path.slice(i + 1, close).trim();
      if (/^\d+$/.test(inner)) {
        // 数组下标须为安全整数：超 2^53-1 两端 tokenizer 会漂移（发布期即拦，与 runtime 同口径）。
        if (!Number.isSafeInteger(Number(inner))) return false;
      } else if (!/^'[^']*'$/.test(inner) && !/^"[^"]*"$/.test(inner)) {
        return false;
      }
      i = close + 1;
      continue;
    }
    return false;
  }
  return true;
}

function scopesOverlap(a: string, b: string): boolean {
  const aWildcard = a.endsWith("*");
  const bWildcard = b.endsWith("*");
  const ap = scopePrefix(a);
  const bp = scopePrefix(b);
  if (!aWildcard && !bWildcard) return a === b;
  if (aWildcard && bWildcard) return ap.startsWith(bp) || bp.startsWith(ap);
  return aWildcard ? b.startsWith(ap) : a.startsWith(bp);
}

function rulesCanMatchSameResponse(a: ResponseMaskerRule, b: ResponseMaskerRule): boolean {
  if (a.match.capability !== b.match.capability || a.match.method !== b.match.method) return false;
  if (a.match.requestKey && b.match.requestKey && a.match.requestKey !== b.match.requestKey) return false;
  return scopesOverlap(a.match.urlScope, b.match.urlScope);
}

export function checkResponseMasker(
  policy: unknown,
  manifest: ResponseMaskerManifest,
  schemaValidate: ValidateFunction,
): Finding[] {
  if (!schemaValidate(policy)) {
    return (schemaValidate.errors ?? []).map((schemaError) =>
      error("RM1_policy_schema", `masker.json${schemaError.instancePath} ${schemaError.message}`),
    );
  }

  const typed = policy as ResponseMaskerPolicy;
  const findings: Finding[] = [];

  if (manifest.trustTier !== "official") {
    findings.push(error("RM2_official_only", "masker.json 只允许 official 签名 adapter 声明"));
  }

  const capabilityList = (Array.isArray(manifest.capabilities) ? manifest.capabilities : []).filter(
    (capability): capability is MaskerCapability =>
      typeof capability === "object" && capability !== null && typeof capability.id === "string",
  );
  const capabilities = new Map(capabilityList.map((capability) => [capability.id, capability]));
  const networkAllow = (Array.isArray(manifest.network?.allow) ? manifest.network.allow : []).filter(
    (allowed): allowed is string => typeof allowed === "string",
  );
  const seenIds = new Set<string>();

  for (const rule of typed.rules) {
    if (seenIds.has(rule.id)) {
      findings.push(error("RM3_duplicate_rule_id", `Masker rule id '${rule.id}' 重复`));
    }
    seenIds.add(rule.id);

    const capability = capabilities.get(rule.match.capability);
    if (!capability) {
      findings.push(
        error(
          "RM4_unknown_capability",
          `Masker rule '${rule.id}' 引用了未声明 capability '${rule.match.capability}'`,
        ),
      );
      continue;
    }

    if (!scopeCoveredByAllow(rule.match.urlScope, networkAllow)) {
      findings.push(
        error(
          "RM5_source_outside_allow",
          `Masker rule '${rule.id}' 的 acquisition scope 不在 network.allow 内`,
        ),
      );
    }

    if (rule.match.requestKey !== undefined) {
      if (capability.requestGraph !== "declarative") {
        findings.push(
          error(
            "RM6_request_key_imperative",
            `Masker rule '${rule.id}' 的 imperative capability 不得声明 requestKey`,
          ),
        );
      } else {
        // requestKey 绑定逻辑请求；method/urlScope 匹配 redirect 后的最终响应，不能与初始
        // requests[] 强行判等（ADR-026 §2.8、工程说明 §4.2）。
        const requests = Array.isArray(capability.requests) ? capability.requests : [];
        const request = requests.find(
          (candidate) =>
            typeof candidate === "object" && candidate !== null && candidate.key === rule.match.requestKey,
        );
        if (!request) {
          findings.push(
            error(
              "RM7_unknown_request_key",
              `Masker rule '${rule.id}' 引用了 capability 内不存在的 requestKey '${rule.match.requestKey}'`,
            ),
          );
        }
      }
    }

    const destination = rule.capture.destination;
    if (destination.kind === "credential") {
      const credentials =
        typeof manifest.credentials === "object" && manifest.credentials !== null
          ? manifest.credentials
          : undefined;
      if (!destination.ref || !credentials?.[destination.ref]) {
        findings.push(
          error(
            "RM8_unknown_credential_ref",
            `Masker rule '${rule.id}' 引用了 manifest 未声明的 credential ref`,
          ),
        );
      }
    }

    if (destination.kind === "handle") {
      if (capability.requestGraph !== "declarative" || rule.match.requestKey === undefined) {
        findings.push(
          error(
            "RM9_handle_requires_request_key",
            `Masker rule '${rule.id}' 的 handle 目标须引用 declarative capability 的 requestKey`,
          ),
        );
      }
      const binds = Array.isArray(capability.bind) ? capability.bind : [];
      const bind = binds.find(
        (candidate) =>
          typeof candidate === "object" && candidate !== null && candidate.var === destination.ref,
      );
      if (!bind) {
        findings.push(
          error(
            "RM10_unknown_handle_ref",
            `Masker rule '${rule.id}' 引用了不存在的 bind.var '${destination.ref}'`,
          ),
        );
      } else {
        if (bind.from !== rule.match.requestKey) {
          findings.push(
            error(
              "RM11_handle_source_mismatch",
              `Masker rule '${rule.id}' 的 requestKey 与 bind '${bind.var}' 的 from 不一致`,
            ),
          );
        }
        if (bind.source === "regex") {
          findings.push(
            error(
              "RM12_handle_regex_deferred",
              `Masker rule '${rule.id}' 的 regex handle 投影不在 V1 契约内`,
            ),
          );
        }
        const expectedProject = bind.source === "header" ? "delete" : "replace";
        if (bind.source !== "regex" && rule.project !== expectedProject) {
          findings.push(
            error(
              "RM13_project_source_mismatch",
              `Masker rule '${rule.id}' 的 project 与 bind source 不匹配`,
            ),
          );
        }
      }
    } else {
      const expectedProject = rule.capture.source === "header" ? "delete" : "replace";
      if (rule.project !== expectedProject) {
        findings.push(
          error(
            "RM13_project_source_mismatch",
            `Masker rule '${rule.id}' 的 project 与 capture source 不匹配`,
          ),
        );
      }
      if (rule.capture.source === "json" && !validJsonPath(rule.capture.path ?? "")) {
        findings.push(error("RM14_bad_jsonpath", `Masker rule '${rule.id}' 使用了 V1 不支持的 JSONPath`));
      }

      if (rule.match.requestKey !== undefined) {
        const binds = Array.isArray(capability.bind) ? capability.bind : [];
        const duplicateBind = binds.find((bind) => {
          if (typeof bind !== "object" || bind === null || bind.from !== rule.match.requestKey) return false;
          if (rule.capture.source === "header") {
            return (
              bind.source === "header" &&
              bind.extract.name?.toLowerCase() === rule.capture.name?.toLowerCase()
            );
          }
          return bind.source === "body" && bind.extract.jsonpath === rule.capture.path;
        });
        if (duplicateBind) {
          findings.push(
            error(
              "RM16_selector_duplicates_bind",
              `Masker rule '${rule.id}' 与 bind '${duplicateBind.var}' 重复提取同一响应值；须改为 handle 目标引用 bind.var`,
            ),
          );
        }
      }
    }
  }

  const persistentRules = typed.rules.filter((rule) => rule.capture.destination.kind === "credential");
  for (let i = 0; i < persistentRules.length; i++) {
    for (let j = i + 1; j < persistentRules.length; j++) {
      const left = persistentRules[i]!;
      const right = persistentRules[j]!;
      if (rulesCanMatchSameResponse(left, right)) {
        findings.push(
          error(
            "RM15_multiple_persistent_targets",
            `Masker rules '${left.id}' 与 '${right.id}' 可命中同一响应，超过单响应一个持久 credential 的 V1 上限`,
          ),
        );
      }
    }
  }

  return findings;
}
