/// 客户端 adapter 执行运行时 —— QuickJS（flutter_qjs / 全平台同一引擎）。
///
/// 与服务端 QuickJS-wasm（`server/src/runtime/sandbox.ts`）是**同一个 QuickJS
/// 引擎**，对同一份 adapter 源码零语义漂移（ADR-001 §8、ADR-005）。
///
/// 当前实现：**parser 模式**（无网络、无凭证、纯解析器）。
/// fetch 模式的受限 ctx.fetch（凭证白名单注入）是承重 + 安全敏感路径
/// （红线 #1、AGENTS.md §1），单独走人工审阅的 PR，此处不实现。
///
/// 不变量：
///  - adapter 在**后台 isolate** 执行（红线 #7：不在 UI 线程同步阻塞）。
///  - parser 模式的 ctx 只有 log/now，**没有 fetch**（无网络能力）。
///  - 两端用同一加载约定：以 ES module 加载 adapter、读其 `capabilities` 导出。
///  - 产出**不在此处按 schema 校验**——校验在宿主（Dart 核心）边界做，
///    与服务端一致（ADR-001 §2.2：QuickJS 不背校验器）。
library;

import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';

/// 运行时层面的失败原因。**不携带契约 error.kind**——错误词表是领域概念，
/// 由上层据此映射（与服务端 `SandboxFailureReason` 对称）。
enum AdapterFailureReason {
  /// adapter 未导出指定 capability。
  capabilityMissing,

  /// parser capability 返回了 Promise（parser 模式必须同步、无 I/O）。
  asyncInParser,

  /// adapter 执行期抛错（或超时/内存越界，由引擎中断）。
  adapterThrew,

  /// adapter 未产出可解析的结果。
  badResult,
}

class AdapterRunException implements Exception {
  const AdapterRunException(this.reason, this.message);

  final AdapterFailureReason reason;
  final String message;

  @override
  String toString() => 'AdapterRunException(${reason.name}): $message';
}

/// 默认执行限额，与服务端 `DEFAULT_LIMITS` 对齐。
const int _defaultTimeoutMs = 5000;
const int _defaultMemoryBytes = 64 * 1024 * 1024;

/// 在后台 isolate 的 QuickJS 中执行一次 parser 模式的 adapter capability。
///
/// [source] 是 adapter 源码（同一份脚本，两端共用）；[responses] 是核心代取并
/// 脱敏后的原始响应（按 manifest `requests[].key` 索引）；[nowMs] 注入 ctx.now()，
/// golden 双跑应固定它以保证确定性。
///
/// 返回归一化后的产出（已 JSON 往返的 Dart 结构）。失败抛 [AdapterRunException]。
Future<dynamic> runParserAdapter({
  required String source,
  required String capability,
  Map<String, dynamic>? params,
  Map<String, dynamic>? responses,
  int nowMs = 0,
  int timeoutMs = _defaultTimeoutMs,
  int memoryBytes = _defaultMemoryBytes,
}) async {
  final qjs = IsolateQjs(
    // 只解析名为 'adapter' 的模块；其余一律拒绝（无任意 import）。
    moduleHandler: (name) async {
      if (name == 'adapter') return source;
      throw JSError('module not found: $name');
    },
    timeout: timeoutMs,
    memoryLimit: memoryBytes,
  );

  try {
    final bootstrap = _buildParserBootstrap(
      capability: capability,
      params: params ?? const {},
      responses: responses ?? const {},
      nowMs: nowMs,
    );

    // 以 ES module 加载 adapter 并运行；产出经 globalThis 以 JSON 字符串回传。
    await qjs.evaluate(
      bootstrap,
      name: '<elecon-bootstrap>',
      evalFlags: JSEvalFlag.MODULE,
    );
    final raw = await qjs.evaluate('globalThis.__elecon_result');

    if (raw is! String) {
      throw const AdapterRunException(
        AdapterFailureReason.badResult,
        'adapter 未产出结果（capability 未返回值？）',
      );
    }
    return jsonDecode(raw);
  } on AdapterRunException {
    rethrow;
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('elecon:capability_missing')) {
      throw AdapterRunException(
        AdapterFailureReason.capabilityMissing,
        "capability '$capability' 不在 adapter 内",
      );
    }
    if (msg.contains('elecon:async_in_parser')) {
      throw const AdapterRunException(
        AdapterFailureReason.asyncInParser,
        'parser capability 返回了 Promise；parser 模式必须同步（无 I/O）',
      );
    }
    throw AdapterRunException(AdapterFailureReason.adapterThrew, msg);
  } finally {
    await qjs.close();
  }
}

/// 构造 parser bootstrap：import adapter → 组装受限 ctx（仅 log/now，无 fetch）
/// → 调用 capability → 把产出以 JSON 字符串写入 globalThis。
///
/// 入参以 `JSON.parse(<JS 字符串字面量>)` 注入，避免拼接 JS 代码引入注入面。
String _buildParserBootstrap({
  required String capability,
  required Object params,
  required Object responses,
  required int nowMs,
}) {
  final capLit = jsonEncode(capability);
  // 双重编码：内层得 JSON 文本，外层把它编成合法的 JS 字符串字面量。
  final paramsLit = jsonEncode(jsonEncode(params));
  final responsesLit = jsonEncode(jsonEncode(responses));

  return '''
import { capabilities } from 'adapter';
const params = JSON.parse($paramsLit);
const responses = JSON.parse($responsesLit);
const ctx = {
  log: function () {},
  now: function () { return $nowMs; }
};
const fn = capabilities[$capLit];
if (typeof fn !== "function") { throw new Error("elecon:capability_missing"); }
const out = fn(ctx, params, responses);
if (out !== null && typeof out === "object" && typeof out.then === "function") {
  throw new Error("elecon:async_in_parser");
}
globalThis.__elecon_result = JSON.stringify(out);
''';
}
