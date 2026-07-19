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
/// **未闭合的最后一跳（发布前门禁）**：真实签名 `assets/bootstrap/*` 与已部署的端点 D + 已发布签名
/// catalog/bundle 尚未就位（阻塞于官方密钥 ceremony / 运营部署）。本层是**代码路径**，二者一到位即点亮；
/// [kPlaceholderDistributionBaseUrl] 是占位，须随端点 D 上线替换。
///
/// 🔒 红线 #1/#4 承重件：改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:io' show Directory;

import 'adapter_runtime.dart'
    show
        AdapterFailureReason,
        AdapterLaunchException,
        AdapterRunException,
        HarvestTarget,
        runLoadedAdapter;
import 'broker/cookie_jar.dart' show CookieJar;
import 'broker/fetch_proxy.dart' show Transport;
import 'broker/ports.dart' show CredentialResolver;
import 'credential/blob_store.dart' show FileBlobStore;
import 'loader/bootstrap.dart' show BootstrapBaseline, FlutterAssetSource;
import 'loader/bundle_cache.dart' show BundleCache;
import 'loader/distribution_http.dart'
    show HttpByteFetcher, HttpDistributionSource, IoHttpByteFetcher;
import 'loader/last_good_store.dart' show LastGoodStore;
import 'loader/loader.dart' show AdapterLoader, LoadResult;
import 'transport/direct.dart' show DirectTransport;

/// ⚠ **占位分发 base URL**（`.invalid` 为 RFC 2606 保留 TLD，恒不可解析）——须随端点 D 部署替换。
/// 在线拉取拉不到时加载器退化到 last-good/bootstrap（fail-closed，不 fail-open）。
const String kPlaceholderDistributionBaseUrl = 'https://dist.elecon.invalid/';

/// 一次 capability 执行的结果：成功携产出；失败分档（加载 / 接线 / 运行）供 UI 分流。
enum CapabilityFailureKind {
  /// 加载链失败（无可信 catalog/revocation、内容寻址/验签不符、adapter 缺失、网络+基线均无……）。
  load,

  /// 接线拒绝（source⟷凭据绑定不符、manifest 畸形、能力越权）——[AdapterLaunchException]。
  launch,

  /// 运行期失败（引擎错误 / 超时 / 限额 / 信任闸门）——[AdapterRunException]。
  run,
}

class CapabilityRun {
  const CapabilityRun.ok(this.data)
    : failureKind = null,
      reason = null,
      runReason = null;
  const CapabilityRun.failed(
    CapabilityFailureKind this.failureKind,
    this.reason, {
    this.runReason,
  }) : data = null;

  /// 归一化产出（JSON 往返的 Dart 结构）；仅 [ok] 时非 null。
  final Object? data;

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
  factory AdapterService.production({
    required Directory supportDir,
    required Uri distributionBaseUrl,
    HttpByteFetcher? fetcher,
    void Function(String message)? onWarning,
  }) {
    final blobs = FileBlobStore(Directory('${supportDir.path}/adapters'));
    final loader = AdapterLoader(
      cache: BundleCache(blobs),
      lastGood: LastGoodStore(blobs),
      bootstrap: BootstrapBaseline(const FlutterAssetSource()),
      source: HttpDistributionSource(
        baseUrl: distributionBaseUrl,
        fetcher: fetcher ?? IoHttpByteFetcher(),
        onWarning: onWarning,
      ),
      onWarning: onWarning,
    );
    return AdapterService(loader: loader, transport: DirectTransport());
  }

  final AdapterLoader _loader;
  final Transport _transport;

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
  }) async {
    final LoadResult load = await _loader.loadAdapter(adapterId);
    if (!load.ok) {
      return CapabilityRun.failed(CapabilityFailureKind.load, load.reason);
    }
    try {
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
      );
      return CapabilityRun.ok(data);
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
