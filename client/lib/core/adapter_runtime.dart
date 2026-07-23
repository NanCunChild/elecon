/// 客户端 adapter 执行运行时 —— QuickJS（flutter_qjs_next / 全平台同一引擎）。
///
/// 与服务端 QuickJS-wasm（`server/src/runtime/sandbox.ts`）是**同一个 QuickJS
/// 引擎**，对同一份 adapter 源码零语义漂移（ADR-001 §8、ADR-005）。
///
/// 当前实现：**parser 模式**（无网络、无凭证、纯解析器）+ **fetch 模式**
/// （受限 ctx.fetch、凭证白名单注入，B6b-Dart，见文件下半部）。fetch 是承重 +
/// 安全敏感路径（红线 #1、AGENTS.md §1）：入口有信任闸门（ADR-002 §2.6），
/// 改动须人工 + 安全清单复核。
///
/// 不变量：
///  - adapter 在**后台 isolate** 执行（红线 #7：不在 UI 线程同步阻塞）。
///  - parser 模式的 ctx 只有 log/now，**没有 fetch**（无网络能力）。
///  - 两端用同一加载约定：以 ES module 加载 adapter、读其 `capabilities` 导出。
///  - 产出**不在此处按 schema 校验**——校验在宿主（Dart 核心）边界做，
///    与服务端一致（ADR-001 §2.2：QuickJS 不背校验器）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter_qjs_next/flutter_qjs.dart';

import 'broker/assemble.dart' show RequestInit;
import 'broker/cookie_jar.dart' show CookieJar, EphemeralWriteInput;
import 'broker/fetch_proxy.dart'
    show
        BrokerFetchRejected,
        FetchRequestLimitExceeded,
        FetchProxyDeps,
        FetchProxyOutcome,
        Transport,
        TransportBodyLimitException,
        TransportCancelToken,
        proxyFetch;
import 'broker/harvest.dart' show decideHarvest, harvestInto;
import 'broker/inject_policy.dart' show BrokerManifestView, CredentialDecl;
import 'broker/ports.dart' show CredentialResolver;
import 'credential/types.dart' show CredentialEntry;
import 'loader/bundle.dart'
    show
        BundleEnvelope,
        BundleFormatException,
        EnvelopeFile,
        envelopeDigest,
        readEnvelopeManifestJson;
import 'loader/loader.dart' show LoadResult;
import 'parser_host.dart'
    show
        ParserHostException,
        ParserRequestDecl,
        fulfillParserRequests;
import 'trust/trusted_context.dart'
    show AdapterTrustTier, TrustedAdapterContext, fetchTrustPermitted;

// 🔒 片 G 接线是本库的一部分（part），使其能调用 library-private 的 [_runFetchAdapter]——
// 从而「运行任意 (source, trust)」的低层入口**不在生产公开面上**，唯一生产入口是 [runLoadedAdapter]
// （绑定 source⟷凭据 digest，评审 P0-1）。part 共享本文件的 import。
part 'adapter_launcher.dart';

/// 运行时层面的失败原因。**不携带契约 error.kind**——错误词表是领域概念，
/// 由上层据此映射（与服务端 `SandboxFailureReason` 对称）。
enum AdapterFailureReason {
  /// adapter 未导出 `capabilities` 对象（与服务端 `bad_export` 对齐，双端词表一致）。
  badExport,

  /// adapter 未导出指定 capability。
  capabilityMissing,

  /// parser capability 返回了 Promise（parser 模式必须同步、无 I/O）。
  asyncInParser,

  /// 超过墙钟超时被引擎中断。
  timeout,

  /// 触碰内存上限被引擎中断。
  memory,

  /// adapter 执行期抛错（非上述可识别的引擎中断）。
  adapterThrew,

  /// adapter 未产出可解析的结果。
  badResult,

  /// fetch 模式：单请求 10s / 累计 30s / 单次 ≤20 请求任一超限（ADR-009 §2.7）。
  fetchLimit,

  /// fetch 模式：信任闸门拒绝——档位 × build 模式不满足入场条件
  /// （ADR-002 §2.6 结构化权限错误；非 official 在 release 永不触达凭证注入）。
  trustRejected,
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
/// [htmlStdlib] 是 `elecon:html` 标准库 bundle 源码（`adapters/_stdlib/html.bundle.js`）。
/// 给出时，adapter 可 `import { parseDocument, selectAll, ... } from "elecon:html"`；
/// 两端加载**同一份** bundle，确定性容错由此而来（ADR-011 §2.1/§2.3）。不给出（默认
/// null）则该模块名 fail-closed：import 它的 adapter 会以"module not found"失败——与
/// 服务端 `setModuleLoader` 的未知模块语义对称（红线 #5：解析器无网络、无副作用）。
///
/// 返回归一化后的产出（已 JSON 往返的 Dart 结构）。失败抛 [AdapterRunException]。
Future<dynamic> runParserAdapter({
  required String source,
  required String capability,
  Map<String, dynamic>? params,
  Map<String, dynamic>? responses,
  String? htmlStdlib,
  int nowMs = 0,
  int timeoutMs = _defaultTimeoutMs,
  int memoryBytes = _defaultMemoryBytes,
}) async {
  final qjs = IsolateQjs(
    // 模块解析 allowlist：'adapter' → 源码；'elecon:html' → SDK bundle（若注入）。
    // 其余一律拒绝（无任意 import）。与服务端 sandbox.ts 的 setModuleLoader 同语义。
    moduleHandler: (name) async {
      if (name == 'adapter') return source;
      if (name == 'elecon:html' && htmlStdlib != null) return htmlStdlib;
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

    // 以 ES module 加载 adapter 并运行。控制信号（capability 缺失 / 返回 Promise）
    // 由 bootstrap 写成 globalThis 上的**结构化 outcome**，不经异常传递——避免靠
    // 异常消息子串匹配误判。只有真正的 adapter 抛错 / 引擎中断才走下面的 catch。
    await qjs.evaluate(
      bootstrap,
      name: '<elecon-bootstrap>',
      evalFlags: JSEvalFlag.MODULE,
    );
    final raw = await qjs.evaluate('globalThis.__elecon_outcome');

    if (raw is! String) {
      throw const AdapterRunException(
        AdapterFailureReason.badResult,
        'adapter 未产出 outcome',
      );
    }
    final outcome = jsonDecode(raw) as Map<String, dynamic>;
    switch (outcome['status']) {
      case 'ok':
        if (!outcome.containsKey('data')) {
          throw const AdapterRunException(
            AdapterFailureReason.badResult,
            'capability 未返回值',
          );
        }
        return outcome['data'];
      case 'bad_export':
        throw const AdapterRunException(
          AdapterFailureReason.badExport,
          "adapter 未导出 'capabilities' 对象",
        );
      case 'capability_missing':
        throw AdapterRunException(
          AdapterFailureReason.capabilityMissing,
          "capability '$capability' 不在 adapter 内",
        );
      case 'async_in_parser':
        throw const AdapterRunException(
          AdapterFailureReason.asyncInParser,
          'parser capability 返回了 Promise；parser 模式必须同步（无 I/O）',
        );
      default:
        throw AdapterRunException(
          AdapterFailureReason.badResult,
          '未知 outcome status: ${outcome['status']}',
        );
    }
  } on AdapterRunException {
    rethrow;
  } catch (e) {
    throw _mapEngineError(e);
  } finally {
    await qjs.close();
  }
}

/// 把引擎/adapter 抛出的异常映射为 [AdapterRunException]。
///
/// 超时与内存越界为**最佳努力识别**：QuickJS 中断时抛出确定的英文消息
/// （interrupt / out of memory）。识别不出的一律归 [AdapterFailureReason.adapterThrew]。
AdapterRunException _mapEngineError(Object e) {
  final msg = e.toString();
  final lower = msg.toLowerCase();
  if (lower.contains('interrupt')) {
    return AdapterRunException(
      AdapterFailureReason.timeout,
      'adapter 执行超时被中断：$msg',
    );
  }
  if (lower.contains('out of memory')) {
    return AdapterRunException(
      AdapterFailureReason.memory,
      'adapter 触碰内存上限：$msg',
    );
  }
  return AdapterRunException(AdapterFailureReason.adapterThrew, msg);
}

/// 构造 parser bootstrap：import adapter → 组装受限 ctx（仅 log/now，无 fetch）
/// → 调用 capability → 把**结构化 outcome** 以 JSON 字符串写入 globalThis。
///
/// 入参以 `JSON.parse(<JS 字符串字面量>)` 注入，避免拼接 JS 代码引入注入面。
/// adapter 自身抛错不在此拦截——任其冒泡为异常，由宿主侧 catch 处理。
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

  // 命名空间 import：缺 `capabilities` 导出时不在模块实例化期抛错（命名 import 会），
  // 而是走结构化 bad_export outcome——与服务端 getProp + typeof 检查同语义。
  return '''
import * as __adapterMod from 'adapter';
const params = JSON.parse($paramsLit);
const responses = JSON.parse($responsesLit);
const ctx = {
  log: function () {},
  now: function () { return $nowMs; }
};
const capabilities = __adapterMod.capabilities;
if (capabilities === null || typeof capabilities !== "object") {
  globalThis.__elecon_outcome = JSON.stringify({ status: "bad_export" });
} else {
  const fn = capabilities[$capLit];
  if (typeof fn !== "function") {
    globalThis.__elecon_outcome = JSON.stringify({ status: "capability_missing" });
  } else {
    const out = fn(ctx, params, responses);
    if (out !== null && typeof out === "object" && typeof out.then === "function") {
      globalThis.__elecon_outcome = JSON.stringify({ status: "async_in_parser" });
    } else {
      globalThis.__elecon_outcome = JSON.stringify({ status: "ok", data: out });
    }
  }
}
''';
}

// ───────────────────────────────────────────────────────────────────────────
// fetch 模式运行时（Gate A · B6b-Dart）—— ADR-009 §2.1/§2.7 · ADR-014（host-fn 通道）
//
// 镜像服务端 sandbox.ts runFetchAdapter：用 fork 的 host-fn 通道把受限 ctx.fetch 接到
// B6a proxyFetch（Dart 镜像 fetch_proxy.dart）。**host 闭包跑在主 isolate**（凭证 resolver /
// transport / jar 都在主 isolate），worker/JS 只见脱敏 {status,headers,body}——凭证永不入
// isolate（红线 #1，ADR-014 核心安全断言）。
//
// 🔒 触引擎 + 凭证注入 + 出网承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环。
// ───────────────────────────────────────────────────────────────────────────

/// fetch 模式资源限额（ADR-009 §2.7；数值占位，待实测校准 §2.8）。
class FetchLimits {
  const FetchLimits({
    this.perRequestTimeoutMs = 10000,
    this.totalNetworkMs = 30000,
    this.maxRequests = 20,
    this.maxHopsPerRequest = 5,
  });

  /// 单请求超时（含重定向链总耗时，计划 §8 #3）。
  final int perRequestTimeoutMs;

  /// 单次执行累计网络耗时（跨所有 ctx.fetch）。
  final int totalNetworkMs;

  /// 单次执行最大请求数（每跳各计一次，含重定向跳）。
  final int maxRequests;

  /// 单请求最大重定向跳数（B3 默认 5）。
  final int maxHopsPerRequest;
}

/// 执行结束 B5 收割钩子目标。[put] 写入凭证库（`CredentialStore.put` 满足之）。
class HarvestTarget {
  const HarvestTarget({required this.put, required this.schoolId});

  final void Function(CredentialEntry entry) put;
  final String schoolId;
}

/// 🔒 **仅测试入口**：直接以任意 (source, trust, view) 跑 fetch 引擎，供 `fetch_runtime_test` 穷举
/// 引擎行为（bad export / 能力缺失 / 限额 / 注入等）。**生产禁用**（[visibleForTesting] lint 兜底）——
/// 生产唯一入口是 [runLoadedAdapter]（它绑定 source⟷凭据 digest，评审 P0-1）。本 shim 不做绑定，
/// 故绝不可暴露给生产调用方：那正是「official 票 + 任意源码」的绕过面。
@visibleForTesting
Future<dynamic> runFetchAdapterForTesting({
  required String source,
  required String capability,
  required TrustedAdapterContext trust,
  required BrokerManifestView view,
  required CredentialResolver resolver,
  required Transport transport,
  Map<String, dynamic>? params,
  CookieJar? jar,
  HarvestTarget? harvest,
  String? htmlStdlib,
  int nowMs = 0,
  int memoryBytes = _defaultMemoryBytes,
  FetchLimits fetchLimits = const FetchLimits(),
  void Function(String level, String message)? onLog,
}) => _runFetchAdapter(
  source: source,
  capability: capability,
  trust: trust,
  view: view,
  resolver: resolver,
  transport: transport,
  params: params,
  jar: jar,
  harvest: harvest,
  htmlStdlib: htmlStdlib,
  nowMs: nowMs,
  memoryBytes: memoryBytes,
  fetchLimits: fetchLimits,
  onLog: onLog,
);

/// 在后台 isolate 的 QuickJS 中执行一次 **fetch 模式** adapter capability。
/// 与 [runParserAdapter] 并列、互不干扰（parser 已签收，本路径独立新增）。
///
/// 🔒 **library-private（评审 P0-1）**：本函数接受裸 (source, trust)、只校验 [trust] 档位而**不核对
/// source 是否对应 [trust] 的 digest**。若公开，持一张合法 official 票的调用方即可传另一份源码绕过
/// 绑定与 manifest 策略组装。故它只对本库开放，生产唯一入口 [runLoadedAdapter] 经 [planLaunch] 完成
/// 绑定后才调用它；测试经 [runFetchAdapterForTesting]（[visibleForTesting]）。
///
/// 不变量（与 `sandbox.ts` 镜像，🔒 安全清单逐项）：
///  - **信任闸门（ADR-002 §2.6 · #79 P0-1）**：入口强制 [trust]（只能经核心裁定路径构造），
///    并在触达引擎/host-fn 注册**之前**以 [fetchTrustPermitted] 复核——非 official 在
///    release/profile 下得到结构化 [AdapterFailureReason.trustRejected]，永不触达凭证注入；
///    dev 侧载仅 debug build 放行（ADR-002 §2.5）。安全性不依赖调用方自觉。
///  - 凭证仅在主 isolate 闭包侧（`proxyFetch`）拼头/出网/脱敏；worker/JS/adapter 仅见脱敏响应
///    （Set-Cookie/Authorization 回显/中间 Location 已由 B2/B3 剥）。
///  - 出口 fail-closed：url 不在 allow → `ctx.fetch` 的 Promise 被拒（adapter 可 catch）。
///  - 限额硬执行：单请求/累计/请求数任一超限 → `fetchLimit` 终止；fatal 在读 outcome 前再校验
///    （adapter 吞拒绝也不放过）。
///  - fail 不收割：仅成功执行后调 B5 收割钩子。
///  - **限额终止 open question（ADR-014 §4.4）**：单请求由 host 侧 `.timeout` 兜；卡死的 worker
///    isolate 的主动中止（`#abort`/`Isolate.kill`）+ in-flight transport cancel（§4.7）为后续项。
Future<dynamic> _runFetchAdapter({
  required String source,
  required String capability,
  required TrustedAdapterContext trust,
  required BrokerManifestView view,
  required CredentialResolver resolver,
  required Transport transport,
  Map<String, dynamic>? params,
  CookieJar? jar,
  HarvestTarget? harvest,
  String? htmlStdlib,
  int nowMs = 0,
  int memoryBytes = _defaultMemoryBytes,
  FetchLimits fetchLimits = const FetchLimits(),
  void Function(String level, String message)? onLog,
}) async {
  // 信任闸门：在触达引擎、注册任何 host function 之前 fail-closed（ADR-002 §2.6）。
  // debugBuild 硬接 kDebugMode（编译期常量）——不提供注入点，release 语义不可被调用方改写。
  if (!fetchTrustPermitted(trust.tier, debugBuild: kDebugMode)) {
    throw AdapterRunException(
      AdapterFailureReason.trustRejected,
      '非 official adapter 无 fetch 权限（档位 ${trust.tier.name}，release/profile '
      'build）——ADR-002 §2.6 结构化权限错误，凭证注入路径不可达',
    );
  }

  final theJar = jar ?? CookieJar();
  final deps = FetchProxyDeps(
    view: view,
    resolver: resolver,
    jar: theJar,
    transport: transport,
    maxHops: fetchLimits.maxHopsPerRequest,
  );

  // 执行内计量状态（被 host 闭包按引用捕获）。
  var requestCount = 0;
  var remainingRequests = fetchLimits.maxRequests;
  var networkMs = 0;
  AdapterRunException? fatal;
  final cancelTokens = <TransportCancelToken>{};

  void cancelInFlight() {
    for (final token in List<TransportCancelToken>.of(cancelTokens)) {
      token.cancel();
    }
    cancelTokens.clear();
  }

  // 引擎墙钟：fetch 流程可合法跑到累计网络上限；引擎 interrupt 只防同步 CPU 死循环
  // （ADR-014 §4.4：interrupt 不在 await 期生效），故设宽到 totalNetworkMs + 缓冲。
  final engineTimeoutMs = fetchLimits.totalNetworkMs + _defaultTimeoutMs;

  // host 闭包：受限 ctx.fetch → proxyFetch（主 isolate）+ 限额计量。
  Future<Object?> hostFetch(dynamic url, dynamic init) async {
    if (fatal != null) throw fatal!;
    if (requestCount >= fetchLimits.maxRequests) {
      fatal = const AdapterRunException(
        AdapterFailureReason.fetchLimit,
        '单次执行请求数超限',
      );
      cancelInFlight();
      throw fatal!;
    }
    final start = DateTime.now().millisecondsSinceEpoch;
    final cancelToken = TransportCancelToken();
    cancelTokens.add(cancelToken);
    late final FetchProxyDeps fetchDeps;
    fetchDeps = FetchProxyDeps(
      view: deps.view,
      resolver: deps.resolver,
      jar: deps.jar,
      transport: deps.transport,
      maxHops: deps.maxHops,
      cancelToken: cancelToken,
      tryReserveRequest: () {
        if (remainingRequests <= 0) {
          fatal = const AdapterRunException(
            AdapterFailureReason.fetchLimit,
            '单次执行请求数超限',
          );
          cancelInFlight();
          return false;
        }
        remainingRequests--;
        return true;
      },
    );
    final FetchProxyOutcome outcome;
    try {
      outcome =
          await proxyFetch(
            url as String,
            _requestInitFromJs(init),
            fetchDeps,
          ).timeout(
            Duration(milliseconds: fetchLimits.perRequestTimeoutMs),
            onTimeout: () {
              fatal = const AdapterRunException(
                AdapterFailureReason.fetchLimit,
                '单请求超时',
              );
              cancelInFlight();
              throw fatal!;
            },
          );
    } on TransportBodyLimitException catch (e) {
      fatal = AdapterRunException(
        AdapterFailureReason.fetchLimit,
        e.toString(),
      );
      cancelInFlight();
      throw fatal!;
    } on FetchRequestLimitExceeded {
      fatal ??= const AdapterRunException(
        AdapterFailureReason.fetchLimit,
        '单次执行请求数超限',
      );
      cancelInFlight();
      throw fatal!;
    } finally {
      cancelTokens.remove(cancelToken);
    }
    networkMs += DateTime.now().millisecondsSinceEpoch - start;
    requestCount += outcome.requestCount;
    if (networkMs > fetchLimits.totalNetworkMs) {
      fatal = const AdapterRunException(
        AdapterFailureReason.fetchLimit,
        '累计网络耗时超限',
      );
      cancelInFlight();
      throw fatal!;
    }
    if (requestCount > fetchLimits.maxRequests) {
      fatal = const AdapterRunException(
        AdapterFailureReason.fetchLimit,
        '单次执行请求数超限',
      );
      cancelInFlight();
      throw fatal!;
    }
    return <String, Object?>{
      'status': outcome.status,
      'headers': outcome.headers,
      if (outcome.body != null) 'body': outcome.body,
    };
  }

  void hostSetEph(dynamic name, dynamic value, dynamic opts) {
    final o = (opts is Map) ? opts : const {};
    final domain = o['domain'];
    if (domain is! String) return; // 缺 domain 直接忽略（栅栏在 writeEphemeral）
    final path = o['path'];
    theJar.writeEphemeral(
      EphemeralWriteInput(
        name: name as String,
        value: value as String,
        domain: domain,
        path: path is String ? path : null,
      ),
      view,
      (m) => onLog?.call('warn', m),
    );
  }

  final qjs = IsolateQjs(
    moduleHandler: (name) async {
      if (name == 'adapter') return source;
      if (name == 'elecon:html' && htmlStdlib != null) return htmlStdlib;
      throw JSError('module not found: $name');
    },
    timeout: engineTimeoutMs,
    memoryLimit: memoryBytes,
  );
  qjs.setHostFunctions({
    '__elecon_fetch': hostFetch,
    '__elecon_setEph': hostSetEph,
    '__elecon_log': (dynamic level, dynamic message) => onLog?.call(
      level is String ? level : 'info',
      message is String ? message : '',
    ),
  });

  try {
    // step1（module）：加载 capabilities 到 globalThis（同步，复用 parser 加载约定）。
    // 命名空间 import：缺导出不在实例化期抛错，交给 step2 归为结构化 bad_export。
    await qjs.evaluate(
      "import * as __adapterMod from 'adapter'; "
      'globalThis.__elecon_caps = __adapterMod.capabilities;',
      name: '<elecon-fetch-load>',
      evalFlags: JSEvalFlag.MODULE,
    );
    // step2（global async）：组 ctx + 调 capability + 返回 outcome JSON 串。用 async-IIFE-返回值
    // （host_fn_bridge_test 已证），避开模块 TLA / 动态 import 在 2021-QuickJS 上的不确定性。
    final raw = await qjs
        .evaluate(
          _buildFetchInvoke(
            capability: capability,
            params: params ?? const {},
            nowMs: nowMs,
          ),
        )
        .timeout(
          Duration(milliseconds: engineTimeoutMs + 1000),
          onTimeout: () {
            cancelInFlight();
            throw const AdapterRunException(
              AdapterFailureReason.timeout,
              'fetch 执行未在墙钟内完成',
            );
          },
        );

    // 限额终止优先于 outcome：fatal 早于 handler settle 置位（adapter 吞拒绝也不放过）。
    if (fatal != null) throw fatal!;

    if (raw is! String) {
      throw const AdapterRunException(
        AdapterFailureReason.badResult,
        'adapter 未产出 outcome',
      );
    }
    final outcome = jsonDecode(raw) as Map<String, dynamic>;
    switch (outcome['status']) {
      case 'ok':
        if (!outcome.containsKey('data')) {
          throw const AdapterRunException(
            AdapterFailureReason.badResult,
            'capability 未返回值',
          );
        }
        // 执行结束 B5 收割（仅成功路径；fail 不收割）。
        if (harvest != null) {
          final plan = decideHarvest(theJar.harvestView(), view);
          harvestInto(
            plan,
            view,
            harvest.put,
            schoolId: harvest.schoolId,
            now: () => nowMs,
          );
        }
        return outcome['data'];
      case 'bad_export':
        throw const AdapterRunException(
          AdapterFailureReason.badExport,
          "adapter 未导出 'capabilities' 对象",
        );
      case 'capability_missing':
        throw AdapterRunException(
          AdapterFailureReason.capabilityMissing,
          "capability '$capability' 不在 adapter 内",
        );
      case 'adapter_threw':
        throw AdapterRunException(
          AdapterFailureReason.adapterThrew,
          outcome['message'] as String? ?? 'adapter threw',
        );
      default:
        throw AdapterRunException(
          AdapterFailureReason.badResult,
          '未知 outcome status: ${outcome['status']}',
        );
    }
  } on AdapterRunException {
    rethrow;
  } on BrokerFetchRejected catch (e) {
    // 一路冒泡到顶（adapter 未 catch）→ 归 adapterThrew（诚实报告）。
    throw AdapterRunException(AdapterFailureReason.adapterThrew, e.toString());
  } catch (e) {
    throw _mapEngineError(e);
  } finally {
    cancelInFlight();
    await qjs.close();
  }
}

/// 把 JS init 对象（{method, headers, body}）归一为 [RequestInit]。
RequestInit _requestInitFromJs(dynamic init) {
  if (init is! Map) return const RequestInit();
  final method = init['method'];
  final body = init['body'];
  final headersRaw = init['headers'];
  Map<String, String>? headers;
  if (headersRaw is Map) {
    final h = <String, String>{};
    headersRaw.forEach((k, v) {
      if (k is String && v is String) h[k] = v;
    });
    headers = h;
  }
  return RequestInit(
    method: method is String ? method : null,
    headers: headers,
    body: body is String ? body : null,
  );
}

/// step2 源：async-IIFE 组 ctx + 调 capability + 返回结构化 outcome JSON 串。
/// 入参经 `JSON.parse(<JS 字面量>)` 注入（不拼 JS 代码）。ctx.fetch/setEphemeralCookie/log
/// 转调 globalThis 上的 host 函数（setHostFunctions 绑定，求值前一次性）。
String _buildFetchInvoke({
  required String capability,
  required Object params,
  required int nowMs,
}) {
  final capLit = jsonEncode(capability);
  final paramsLit = jsonEncode(jsonEncode(params));
  return '''
(async () => {
  const params = JSON.parse($paramsLit);
  const caps = globalThis.__elecon_caps;
  if (caps === null || typeof caps !== "object") {
    return JSON.stringify({ status: "bad_export" });
  }
  const fn = caps[$capLit];
  if (typeof fn !== "function") {
    return JSON.stringify({ status: "capability_missing" });
  }
  const ctx = {
    log: (l, m) => globalThis.__elecon_log(String(l), String(m)),
    now: () => $nowMs,
    // 契约：ctx.fetch → Promise<Response>（contract/adapter-sdk）。QuickJS 无内建 Response，
    // 故把裸 {status,headers,body} 包成 Response 语义子集（status/ok/headers/text()/json()）；
    // body 仅经 text()/json() 暴露（同 DOM Response，不直接给 .body）。与 sandbox.ts shim 对齐。
    fetch: (url, init) => globalThis.__elecon_fetch(String(url), init || {}).then((r) => ({
      status: r.status,
      ok: r.status >= 200 && r.status < 300,
      headers: r.headers,
      text: () => Promise.resolve(r.body === undefined ? "" : r.body),
      json: () => Promise.resolve(JSON.parse(r.body === undefined ? "null" : r.body)),
    })),
    setEphemeralCookie: (n, v, o) => { globalThis.__elecon_setEph(String(n), String(v), o || {}); },
  };
  try {
    const data = await fn(ctx, params);
    return JSON.stringify({ status: "ok", data: data === undefined ? null : data });
  } catch (e) {
    return JSON.stringify({ status: "adapter_threw", message: String((e && e.message) || e) });
  }
})()
''';
}
