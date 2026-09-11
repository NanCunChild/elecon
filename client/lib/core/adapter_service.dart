/// 🔒 生产装配层 —— 把加载链原语组装成可跑的 [AdapterService]，桥接 loadAdapter → runLoadedAdapter。
///
/// 片 E–G 造好了原语（编排器 / 端点 D 拉取 / 接线），本层把它们**按生产形态拼起来**：
///   - bundle 缓存 + last-good 落在 app 私有目录（[FileBlobStore]）；
///   - bootstrap 基线读 app assets（[FlutterAssetSource]）；
///   - 在线拉取走端点 D（[HttpDistributionSource] + [IoHttpByteFetcher]）；
///   - 加载器用**生产 verifier**（`AdapterLoader.new`，真实预埋 pin，红线 #4）；
///   - 执行走 [runLoadedAdapter]（唯一生产入口，绑定 source⟷凭据 digest；transport = [DirectTransport]）。
///
/// **凭证解析器由调用方注入**（session 的 `CredentialStore`，它 `implements CredentialResolver`）——
/// 本层不持有凭证，只搬「哪个 adapter、跑哪个 capability」（红线 #1：凭证仍只在核心闭包侧注入）。
///
/// **分发 base URL 由客户端自持**（ADR-018 §2.5.1）：catalog 只描述文件，三类产物的路径全部相对
/// [kDistributionBaseUrl]。端点内容未就位或不可达时加载器退化到 last-good / bootstrap（fail-closed）。
/// DEV-Sideload 可用 `--dart-define=ELECON_DISTRIBUTION_BASE_URL=…` 覆盖 base（见 [effectiveDistributionBaseUrl]）。
///
/// 🔒 红线 #1/#4 承重件：改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:io' show Directory;

import '../catalog/schools.dart' show SchoolDescriptor;
import 'adapter_runtime.dart'
    show
        AdapterFailureReason,
        AdapterLaunchException,
        AdapterRunException,
        HarvestTarget,
        planLaunch,
        runLoadedAdapter;
import 'broker/cookie_jar.dart' show CookieJar;
import 'broker/fetch_proxy.dart' show Transport;
import 'broker/ports.dart' show CredentialResolver;
import 'credential/blob_store.dart' show FileBlobStore;
import 'loader/bootstrap.dart' show BootstrapBaseline, FlutterAssetSource;
import 'loader/bundle.dart' show readEnvelopeManifestJson;
import 'loader/bundle_cache.dart' show BundleCache;
import 'loader/distribution_http.dart'
    show HttpByteFetcher, HttpDistributionSource, IoHttpByteFetcher;
import 'loader/last_good_store.dart' show LastGoodStore;
import 'loader/diagnostics.dart' show AdapterDiagnostic;
import 'loader/loader.dart' show AdapterLoader;
import 'transport/direct.dart' show DirectTransport;
import 'trust/trust_profile.dart' show kSideloadEnabled;

/// 官方分发 base URL（端点 D）。端点只提供公开、已签名的静态产物；内容未就位时加载器仍退化到
/// last-good/bootstrap（fail-closed，不 fail-open）。DEPLOY **恒用此值**。
const String kDistributionBaseUrl = 'https://elecon.xidian.one/adapters/';

/// DEV 覆盖值（`--dart-define=ELECON_DISTRIBUTION_BASE_URL=…`）。缺省空串 = 不覆盖。
const String kDistributionBaseUrlOverride = String.fromEnvironment(
  'ELECON_DISTRIBUTION_BASE_URL',
);

/// 覆盖是否生效：**仅 DEV-Sideload profile** 且给了非空 dart-define。两者皆编译期常量，
/// DEPLOY 构建中本值折叠为 false、覆盖路径被整体裁掉（ADR-024 release gate 另断言 DEPLOY 无 DEV profile）。
/// 覆盖只改变「从哪拉字节」——digest 重算 / Ed25519 验签 / 吊销门一步不少，来源不影响信任裁定。
const bool kDistributionOverrideActive =
    kSideloadEnabled && kDistributionBaseUrlOverride != '';

/// 生效的分发 base URL：DEPLOY = [kDistributionBaseUrl]；DEV 覆盖生效时 = 覆盖值。
/// 覆盖值畸形（非绝对 URL）时**不回退到官方端点**而是照样交给 [HttpDistributionSource]，
/// 由它拒拉 + 遥测——DEV 里给错参数应当可见，而不是静默连到线上。
Uri get effectiveDistributionBaseUrl => Uri.parse(
  kDistributionOverrideActive ? kDistributionBaseUrlOverride : kDistributionBaseUrl,
);

/// 一次 capability 执行的结果：成功携产出；失败分档（加载 / 接线 / 运行 / 认证）供 UI 分流。
enum CapabilityFailureKind {
  /// 加载链失败（无可信 catalog/revocation、内容寻址/验签不符、adapter 缺失、网络+基线均无……）。
  load,

  /// 接线拒绝（source⟷凭据绑定不符、manifest 畸形、能力越权）——[AdapterLaunchException]。
  launch,

  /// 运行期失败（引擎错误 / 超时 / 限额 / 信任闸门）——[AdapterRunException]。
  run,

  /// 凭证闸门未过：缺 session / mint 失败需可见登录 / 用户取消登录（mint 闭环 §4.2）。
  /// UI 应引导 [runSchoolLogin]，**不得**把 reason 当凭证值展示（红线 #1）。
  auth,
}

class CapabilityRun {
  const CapabilityRun.ok(
    this.data, {
    this.supportedCapabilities = const <String>{},
  }) : failureKind = null,
       reason = null,
       runReason = null;
  const CapabilityRun.failed(
    CapabilityFailureKind this.failureKind,
    this.reason, {
    this.runReason,
  }) : data = null,
       supportedCapabilities = const <String>{};

  /// 归一化产出（JSON 往返的 Dart 结构）；仅 [ok] 时非 null。
  final Object? data;

  /// 本次执行所用已验签 bundle manifest 的权威能力集；失败时为空。
  final Set<String> supportedCapabilities;

  final CapabilityFailureKind? failureKind;

  /// 人类可读失败原因。
  final String? reason;

  /// 运行期失败的结构化词表（[failureKind] == run 时非 null），供 UI 映射（续期/重登/升级……）。
  final AdapterFailureReason? runReason;

  bool get ok => failureKind == null;
}

/// 加载 + 执行服务。构造注入**已装配的**加载器与传输；生产装配见 [AdapterService.production]。
class AdapterService {
  AdapterService({required AdapterLoader loader, required Transport transport})
    : _loader = loader,
      _transport = transport;

  /// 🔒 生产装配：从 app 私有目录 [supportDir] + 分发端点 [distributionBaseUrl] 组装。
  ///
  /// [supportDir] 由 wiring 层用 path_provider 提供（同凭证库落盘），adapter 缓存落其下独立子目录
  /// （公开签名内容，无需备份排除，区别于凭证密文）。[fetcher] 仅供测试替身；生产用 [IoHttpByteFetcher]。
  /// [allowInsecureHttp] 只应传 [kDistributionOverrideActive]（DEV 覆盖 base 时允许本地 http 端点）。
  factory AdapterService.production({
    required Directory supportDir,
    required Uri distributionBaseUrl,
    bool allowInsecureHttp = false,
    HttpByteFetcher? fetcher,
    void Function(String message)? onWarning,
  }) {
    final blobs = FileBlobStore(Directory('${supportDir.path}/adapters'));
    void Function(AdapterDiagnostic)? reportDiagnostic;
    late AdapterLoader loader;
    if (allowInsecureHttp) {
      onWarning?.call('DEV：分发 base 已被 dart-define 覆盖为 $distributionBaseUrl（允许 http；验签门不变）');
    }
    final source = HttpDistributionSource(
      baseUrl: distributionBaseUrl,
      fetcher: fetcher ?? IoHttpByteFetcher(),
      allowInsecureHttp: allowInsecureHttp,
      onWarning: onWarning,
      onDiagnostic: (diagnostic) => reportDiagnostic?.call(diagnostic),
    );
    loader = AdapterLoader(
      cache: BundleCache(blobs),
      lastGood: LastGoodStore(blobs),
      bootstrap: BootstrapBaseline(const FlutterAssetSource()),
      source: source,
      onWarning: onWarning,
    );
    reportDiagnostic = loader.reportDiagnostic;
    return AdapterService(loader: loader, transport: DirectTransport());
  }

  final AdapterLoader _loader;
  final Transport _transport;

  /// 从完整验签后的 bundle manifest 读取学校认证声明。任何加载/解析失败均 fail-closed。
  Future<SchoolDescriptor?> describeSchool(String adapterId) async {
    final load = await _loader.loadAdapter(adapterId);
    if (!load.ok || load.envelope == null) return null;
    try {
      final manifest = readEnvelopeManifestJson(load.envelope!, load.blobs!);
      final descriptor = SchoolDescriptor.fromVerifiedManifest(manifest);
      return descriptor.adapterId == adapterId ? descriptor : null;
    } on FormatException {
      return null;
    }
  }

  /// 加载 [adapterId] 并执行 [capability]。全程 fail-closed 并归一化为 [CapabilityRun]，绝不上抛。
  ///
  /// [resolver] 由 session 注入（其 `CredentialStore`）；凭证只在核心闭包侧注入，本层不触其值。
  /// [htmlStdlib] 为 `elecon:html` stdlib bundle 源码（adapter 若 `import "elecon:html"` 则须给出，
  /// 否则该 import fail-closed）。
  Future<CapabilityRun> run({
    required String adapterId,
    required String capability,
    required CredentialResolver resolver,
    Map<String, dynamic>? params,
    CookieJar? jar,
    HarvestTarget? harvest,
    String? htmlStdlib,
    int? nowMs,
    void Function(String level, String message)? onLog,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) async {
    // 诊断 sink 随本次加载透传给编排器（call-scoped，见 AdapterLoader._activeSink），
    // 不再由本层持一个被并发 run() 争用的可变字段（评审：可维护性）。
    final load = await _loader.loadAdapter(
      adapterId,
      onDiagnostic: onDiagnostic,
    );
    if (!load.ok) {
      return CapabilityRun.failed(CapabilityFailureKind.load, load.reason);
    }
    try {
      final supportedCapabilities = Set<String>.unmodifiable(
        planLaunch(load).capabilities,
      );
      final data = await runLoadedAdapter(
        result: load,
        capability: capability,
        resolver: resolver,
        transport: _transport,
        params: params,
        jar: jar,
        harvest: harvest,
        htmlStdlib: htmlStdlib,
        nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
        onLog: onLog,
      );
      return CapabilityRun.ok(
        data,
        supportedCapabilities: supportedCapabilities,
      );
    } on AdapterLaunchException catch (e) {
      return CapabilityRun.failed(CapabilityFailureKind.launch, e.message);
    } on AdapterRunException catch (e) {
      return CapabilityRun.failed(
        CapabilityFailureKind.run,
        e.message,
        runReason: e.reason,
      );
    }
  }
}
