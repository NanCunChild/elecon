/// Response Masker 策略装配（ADR-026 §2.7 / §2.7.1 落地）—— 已验签 bundle 内 `masker.json` 的
/// **运行时严格解析** + firewall ② 步的**规则选取**。与 TS
/// `server/src/runtime/broker/masker-policy.ts` 逐字对齐，行为由
/// `contract/golden/broker/masker-policy.json` 双端钉死（ADR-001 §8 两端双跑）。
///
/// 职责边界：
///  - [parseMaskerPolicy]：字节 → 策略对象。形状与 `contract/response-masker.schema.json` 逐字
///    对齐（多余字段 / 缺字段 / 错枚举一律 fail-closed）。**不**重做 policy⟷manifest 的闭合性
///    校验（capability / network.allow / credential ref / bind 引用属签发期 validator RM1–RM15，
///    签名已背书；客户端不带 ajv，也不该在热路径重跑签发期检查）。
///  - [selectMaskerRules]：按 (capability, method, 最终 URL, requestKey) 选出本次响应适用的规则，
///    交给纯引擎 `applyResponseMasker`。AND 语义、保持策略序；`handle` 目标**不进引擎**
///    （由 ADR-023 dataflow `bind` 承接，ADR-026 §3）。
///
/// 装配纪律（ADR-026 §2.7）：official adapter 加载时 policy / sink / store / host gate 任一缺失
/// 即拒载，空规则不放宽——本模块只提供解析与选取，拒载判定在 `adapter_launcher` / `adapter_runtime`。
///
/// 🔒 红线 #1 承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:convert';

import 'response_masker.dart';
import 'url_match.dart';

/// `masker.json` 规则条数上限（与 `contract/response-masker.schema.json` 的 `maxItems` 一致）。
const int kMaxMaskerRules = 64;

/// 策略解析 / 装配错误。整条 capability fail-closed；🔒 消息不含原值。
class MaskerPolicyException implements Exception {
  const MaskerPolicyException(this.code, this.message);

  /// 稳定错误码：`policy_bad_json` / `policy_bad_shape` / `policy_duplicate_rule_id`。
  final String code;
  final String message;

  @override
  String toString() => 'MaskerPolicyException($code): $message';
}

/// 规则的 `match` 块（ADR-026 §2.8 封闭维度，全部 AND）。
class MaskerMatch {
  const MaskerMatch({
    required this.capability,
    required this.method,
    required this.urlScope,
    this.requestKey,
  });

  final String capability;

  /// declarative 逻辑请求 key；缺省 = 不约束该维度。
  final String? requestKey;

  /// `GET` | `POST`（已大写归一）。
  final String method;

  /// 最终响应 URL 的 acquisition scope（与 network.allow 同形模板）。
  final String urlScope;
}

/// 一条带 `match` 的策略规则。[capture] 为 null 表示 handle 目标（不进纯引擎）。
class MaskerPolicyRule {
  const MaskerPolicyRule({
    required this.id,
    required this.match,
    required this.project,
    this.capture,
    this.handleRef,
  });

  final String id;
  final MaskerMatch match;

  /// 引擎可执行的 capture 声明；handle 目标时为 null。
  final MaskerCaptureDecl? capture;

  /// handle 目标引用的 `bind.var`；非 handle 目标时为 null。
  final String? handleRef;

  final String project; // delete | replace
}

/// 已验签 `masker.json` 的解析结果。
class MaskerPolicy {
  const MaskerPolicy({required this.rules});

  /// 空规则合法（`rules: []`）——表示该版本无非标准响应凭证规则，**不等价于缺文件**。
  final List<MaskerPolicyRule> rules;
}

final RegExp _reRuleId = RegExp(r'^[a-z][a-z0-9-]{0,63}$');
final RegExp _reHeaderName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
final RegExp _reCredentialRef = RegExp(r'^[a-z][a-z0-9-]*$');
final RegExp _reHandleRef = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

Never _bad(String message) =>
    throw MaskerPolicyException('policy_bad_shape', message);

void _assertKeys(Map<String, dynamic> o, List<String> allowed, String where) {
  for (final k in o.keys) {
    if (!allowed.contains(k)) _bad('$where 含未知字段 "$k"');
  }
}

String _requireString(
  Map<String, dynamic> o,
  String key,
  String where, {
  int min = 1,
  int max = 1 << 30,
}) {
  final v = o[key];
  if (v is! String) _bad('$where.$key 缺失或非字符串');
  if (v.length < min || v.length > max) _bad('$where.$key 长度越界');
  return v;
}

MaskerMatch _parseMatch(Object? raw, String where) {
  if (raw is! Map<String, dynamic>) _bad('$where 非对象');
  _assertKeys(raw, const [
    'capability',
    'requestKey',
    'method',
    'urlScope',
  ], where);
  final capability = _requireString(raw, 'capability', where, max: 128);
  final method = _requireString(raw, 'method', where);
  if (method != 'GET' && method != 'POST') {
    _bad('$where.method 只允许 GET | POST');
  }
  final urlScope = _requireString(raw, 'urlScope', where, max: 2048);
  return MaskerMatch(
    capability: capability,
    method: method,
    urlScope: urlScope,
    requestKey: raw['requestKey'] == null
        ? null
        : _requireString(raw, 'requestKey', where, max: 64),
  );
}

({String kind, String? ref}) _parseDestination(Object? raw, String where) {
  if (raw is! Map<String, dynamic>) _bad('$where 非对象');
  final kind = raw['kind'];
  if (kind == 'credential') {
    _assertKeys(raw, const ['kind', 'ref'], where);
    final ref = _requireString(raw, 'ref', where, max: 64);
    if (!_reCredentialRef.hasMatch(ref)) _bad('$where.ref 不合 credential ref 模式');
    return (kind: 'credential', ref: ref);
  }
  if (kind == 'redact') {
    _assertKeys(raw, const ['kind'], where);
    return (kind: 'redact', ref: null);
  }
  if (kind == 'handle') {
    _assertKeys(raw, const ['kind', 'ref'], where);
    final ref = _requireString(raw, 'ref', where);
    if (!_reHandleRef.hasMatch(ref)) _bad('$where.ref 不合 handle ref 模式');
    return (kind: 'handle', ref: ref);
  }
  _bad('$where.kind 只允许 credential | redact | handle');
}

({MaskerCaptureDecl? capture, String? handleRef}) _parseCapture(
  Object? raw,
  String where,
) {
  if (raw is! Map<String, dynamic>) _bad('$where 非对象');
  if (raw['exactly'] != 1) _bad('$where.exactly 必须为 1');
  final destination = _parseDestination(raw['destination'], '$where.destination');
  final source = raw['source'];

  if (source == null) {
    // handleCapture：只允许 exactly + destination(kind=handle)。
    _assertKeys(raw, const ['exactly', 'destination'], where);
    if (destination.kind != 'handle') {
      _bad('$where 无 source 时 destination 只能是 handle');
    }
    return (capture: null, handleRef: destination.ref);
  }
  if (destination.kind == 'handle') _bad('$where handle 目标不得声明 source');

  if (source == 'header') {
    _assertKeys(raw, const ['source', 'name', 'exactly', 'destination'], where);
    final name = _requireString(raw, 'name', where);
    if (!_reHeaderName.hasMatch(name)) _bad('$where.name 不合响应头名模式');
    return (
      capture: MaskerCaptureDecl(
        source: 'header',
        name: name,
        destinationKind: destination.kind,
        destinationRef: destination.ref,
      ),
      handleRef: null,
    );
  }
  if (source == 'json') {
    _assertKeys(raw, const ['source', 'path', 'exactly', 'destination'], where);
    final path = _requireString(raw, 'path', where, max: 512);
    return (
      capture: MaskerCaptureDecl(
        source: 'json',
        path: path,
        destinationKind: destination.kind,
        destinationRef: destination.ref,
      ),
      handleRef: null,
    );
  }
  _bad('$where.source 只允许 header | json（或缺省 = handle）');
}

MaskerPolicyRule _parseRule(Object? raw, String where) {
  if (raw is! Map<String, dynamic>) _bad('$where 非对象');
  _assertKeys(raw, const ['id', 'match', 'capture', 'project'], where);
  final id = _requireString(raw, 'id', where);
  if (!_reRuleId.hasMatch(id)) _bad('$where.id 不合规则 id 模式');
  final match = _parseMatch(raw['match'], '$where.match');
  final capture = _parseCapture(raw['capture'], '$where.capture');
  final project = _requireString(raw, 'project', where);
  if (project != 'delete' && project != 'replace') {
    _bad('$where.project 只允许 delete | replace');
  }
  return MaskerPolicyRule(
    id: id,
    match: match,
    capture: capture.capture,
    handleRef: capture.handleRef,
    project: project,
  );
}

/// 严格解析 `masker.json` 文本。**只在验签之后**对签名覆盖的字节调用（字节取自 blob 表，
/// digest v2 已证明它确属 `masker.json`，P0-01）。任何形状偏差 → [MaskerPolicyException]。
MaskerPolicy parseMaskerPolicy(String text) {
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } on FormatException catch (e) {
    throw MaskerPolicyException(
      'policy_bad_json',
      'masker.json 不是合法 JSON：${e.message}',
    );
  }
  if (raw is! Map<String, dynamic>) _bad('masker.json 顶层非对象');
  _assertKeys(raw, const ['schemaVersion', 'rules'], 'masker.json');
  if (raw['schemaVersion'] != 1) _bad('masker.json.schemaVersion 必须为 1');
  final rawRules = raw['rules'];
  if (rawRules is! List) _bad('masker.json.rules 缺失或非数组');
  if (rawRules.length > kMaxMaskerRules) {
    _bad('masker.json.rules 超过 $kMaxMaskerRules 条上限');
  }
  final rules = <MaskerPolicyRule>[];
  final seen = <String>{};
  for (var i = 0; i < rawRules.length; i++) {
    final rule = _parseRule(rawRules[i], 'rules[$i]');
    if (!seen.add(rule.id)) {
      throw MaskerPolicyException(
        'policy_duplicate_rule_id',
        "masker.json 规则 id '${rule.id}' 重复",
      );
    }
    rules.add(rule);
  }
  return MaskerPolicy(rules: List<MaskerPolicyRule>.unmodifiable(rules));
}

/// 选规则上下文（firewall ② 步输入）。
class MaskerSelectContext {
  const MaskerSelectContext({
    required this.capability,
    required this.method,
    required this.finalUrl,
    this.requestKey,
  });

  /// 本次执行的 capability id（manifest 权威能力集内）。
  final String capability;

  /// 最终响应所属请求的方法（重定向后最后一跳）。大小写不敏感。
  final String method;

  /// 最终响应 URL（重定向后最后一跳，含 query）。
  final String finalUrl;

  /// declarative 逻辑请求 key；imperative `ctx.fetch` 无 key（带 requestKey 的规则永不命中）。
  final String? requestKey;
}

/// firewall ② 步：选出本次响应适用的引擎规则（AND：capability = 、method = 、
/// urlScope ∋ finalUrl、requestKey 若声明则须相等）。保持策略序；`handle` 目标不进引擎。
List<MaskerRule> selectMaskerRules(
  MaskerPolicy policy,
  MaskerSelectContext ctx,
) {
  final method = ctx.method.toUpperCase();
  final out = <MaskerRule>[];
  for (final rule in policy.rules) {
    if (rule.match.capability != ctx.capability) continue;
    if (rule.match.method != method) continue;
    if (rule.match.requestKey != null &&
        rule.match.requestKey != ctx.requestKey) {
      continue;
    }
    if (!scopeMatches(ctx.finalUrl, rule.match.urlScope)) continue;
    final capture = rule.capture;
    if (capture == null) continue; // handle 目标：dataflow bind 承接
    out.add(
      MaskerRule(id: rule.id, capture: capture, project: rule.project),
    );
  }
  return out;
}
