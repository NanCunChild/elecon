/// 🔒🔒 客户端 adapter 加载编排器 —— ADR-018 §2.6 的 **fail-closed 顺序**总装（红线 #1/#4）。
///
/// 本文件把片 A→D 的原语串成一条不可重排的加载链，终点是铸造 official [TrustedAdapterContext]
/// 喂给 `runImperativeAdapter`。§2.6 顺序（**任一步失败即拒、不加载**）：
///
///   1. 取 catalog → **验签 + sequence 不回滚**（[_resolveCatalog]：fetch/last-good/bootstrap
///      三源各自验签，按 `pickNewerCatalog` 取最高 sequence，成功采纳则持久化 last-good）。
///   2. 在 catalog 定位目标 adapterId 的 entry（含 url / digest / capabilities）。
///   3. 取 bundle 字节：**cache → bootstrap → 网络**（内容寻址，来源不影响安全，只影响可用性）。
///   4. 解包 + **重算 envelope digest == catalog entry.digest**（内容寻址锚定「要用的就是 catalog 指的」）。
///   5. **Ed25519 验签**（active pin 公钥）→ 不可伪造 [VerifiedBundle]；再核 digest==entry.digest
///      与**身份绑定**（entry.adapterId/version == bundle 权威身份，评审 #1）。
///   6. 取 revocation → 验签 + 防回滚（[_resolveRevocation]；**无任何可信 revocation 即 fail-closed
///      拒载**——无法确认「未被吊销」，宁可不加载）。**刻意置于验签之后**：严格贴合 §2.6 声明的
///      「不可重排」顺序（catalog → bundle 下载/摘要 → 验签 → 吊销 → stdlibMin；评审 P1），避免后
///      续维护者误以为顺序不合规。功能上无差（revocation 仅被第 7 步消费），仅早失败点后移。
///   7. **吊销查询 + stdlibMin 门**（`mintOfficialGrant`：§2.6 第 5/6 步，先吊销后 stdlib）。
///   8. 全过 → 铸 official [TrustedAdapterContext]；顺带把已验签 packed 写入 cache 供下次加速。
///
/// **缓存/基线非信任源**：cache 命中也**每次重新验签**（§2.6「绝不验一次缓存永久信任」）；bootstrap
/// 基线与线上产物同格式同验签，随官方签名 app 分发但仍走完整裁定。
///
/// **网络经接缝 [DistributionSource] 注入**：本编排器**不含任何 HTTP**——真实端点 D 拉取是片 F 的
/// `DistributionSource` 实现。离线（source 为 null 或抛错）时退化为 last-good + bootstrap，仍 fail-closed。
///
/// **存储故障隔离（评审 P1：异常不得打断回退链）**：cache / last-good / bootstrap 的底层
/// [BlobStore]/[AssetSource] 读取可能抛 IOException（权限 / 坏扇区 / 半写）。这类**存储故障**一律经
/// [_readOrNull] 隔离成「本源不可用」（记遥测 + 继续回退），与「数据损坏」（各存储层自吞成 null）
/// 同样**不打断** catalog→last-good→bootstrap→网络 的回退链；只有**所有来源都取不到**时才
/// [LoadResult.fail]，绝不向上抛未包装异常。
///
/// **验签接缝**：三个 verifier 以 typedef 注入，默认生产实现（`verifyCatalog`/`verifyRevocation`/
/// `verifyBundleSignature`，用**预埋真实 pin**）；测试注入 golden 测试锚版本。这样生产代码不触
/// `@visibleForTesting` 的 `*With` 变体，而测试仍能跑同一条编排链。
///
/// 🔒 红线 #1/#4 承重件：改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
///
/// ⚠ **人工评审重点（本片政策裁定项）**：
///   - **无可信 revocation → 拒载**（步骤 6）：ADR-010 要求 bootstrap 打包初始 revocation，故「一份都
///     没有」属配置错误，fail-closed 拒是安全侧选择；若要放宽为「缺 revocation 时仅凭验签+吊销为空放行」
///     须走决策。
///   - **新鲜度不硬失败**：catalog/revocation 取「最高 sequence 的已验签份」而**不因 TTL 过期硬拒**——
///     离线时 last-good 回退的本意（stale 的已签清单仍含所有历史 kill，属 fail-closed 倾向；唯一残余
///     是离线窗口内新发的 kill 看不到，离线不可避免）。freshness 仅在 [LoadResult] 暴露供遥测/上层决策。
library;

import 'dart:typed_data';

import '../trust/trusted_context.dart' show TrustedAdapterContext;
import 'bootstrap.dart' show BootstrapBaseline;
import 'bundle.dart'
    show
        BundleEnvelope,
        BundleFormatException,
        EnvelopeIdentity,
        envelopeDigest,
        unpackBundle;
import 'bundle_cache.dart' show BundleCache, CachedBundle;
import 'catalog.dart'
    show
        CatalogEntry,
        SignedCatalog,
        VerifiedCatalog,
        catalogFresh,
        pickNewerCatalog,
        verifyCatalog;
import 'diagnostics.dart' show AdapterDiagnostic, AdapterDiagnosticKind;
import 'last_good_store.dart' show LastGoodStore;
import 'load_grant.dart' show mintOfficialGrant;
import 'revocation.dart'
    show
        SignedRevocationList,
        VerifiedRevocationList,
        pickNewerRevocation,
        revocationFresh,
        verifyRevocation;
import 'signature.dart' show SignatureFile;
import 'verify.dart' show VerifiedBundle, VerifyResult, verifyBundleSignature;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 分发拉取接缝（片 F 实现，对接公网端点 D）。**零凭证、只读、静态**（红线 #2）。
///
/// 每个方法**离线/失败可返回 null 或抛**——编排器一律当「本源不可用」处理并退化到 last-good/bootstrap，
/// 绝不因网络错误 fail-open。实现须自带超时/大小上限（同 catalog/bundle 的规模护栏精神）。
abstract interface class DistributionSource {
  /// 拉取线上 `catalog.json`（已解 gzip 的 [SignedCatalog] 外层信封）；无/失败 → null。
  Future<SignedCatalog?> fetchCatalog();

  /// 拉取线上 `revocation.json`；无/失败 → null。
  Future<SignedRevocationList?> fetchRevocation();

  /// 按 catalog entry 的 url 拉取 packed bundle 字节（`gzip(JSON({envelope,signature}))`）；无/失败 → null。
  Future<Uint8List?> fetchBundle(String url);
}

// 生产默认 verifier（真实预埋 pin）。测试注入 golden 测试锚版本。
typedef CatalogVerifier =
    Future<VerifyResult<VerifiedCatalog>> Function(SignedCatalog signed);
typedef RevocationVerifier =
    Future<VerifyResult<VerifiedRevocationList>> Function(
      SignedRevocationList signed,
    );
typedef BundleVerifier =
    Future<VerifyResult<VerifiedBundle>> Function(
      BundleEnvelope env,
      SignatureFile signature,
    );

/// 加载结果。失败恒带 [reason]；成功携带 official 凭据 + 已验证的 envelope/身份/能力/digest。
class LoadResult {
  const LoadResult.ok({
    required TrustedAdapterContext this.trust,
    required BundleEnvelope this.envelope,
    required EnvelopeIdentity this.identity,
    required List<String> this.capabilities,
    required String this.digest,
    required this.catalogIsFresh,
    required this.revocationIsFresh,
  }) : reason = null;

  const LoadResult.fail(String this.reason)
    : trust = null,
      envelope = null,
      identity = null,
      capabilities = null,
      digest = null,
      catalogIsFresh = null,
      revocationIsFresh = null;

  /// official 运行时凭据（喂 `runImperativeAdapter`）。
  final TrustedAdapterContext? trust;

  /// 已验签 bundle 的 envelope（上层据此取 adapter 源码 / manifest / 资源）。
  final BundleEnvelope? envelope;

  /// 权威身份（取自签名覆盖的 manifest）。
  final EnvelopeIdentity? identity;

  /// catalog 声明的能力集（已在验签时校验 ⊆ registry）。
  final List<String>? capabilities;

  /// 已验证的内容寻址 digest。
  final String? digest;

  /// 采纳的 catalog / revocation 是否 TTL 内新鲜（遥测/上层决策用；不新鲜**不**阻断加载，见文件头政策注）。
  final bool? catalogIsFresh;
  final bool? revocationIsFresh;

  final String? reason;

  bool get ok => reason == null;
}

/// 🔒 加载编排器。构造注入存储原语 + 可选网络源 + 时钟。
///
/// **生产构造器 [AdapterLoader.new] 不暴露 verifier**（评审 P0-2）：三个验签器**固定为生产实现**
/// （`verifyCatalog`/`verifyRevocation`/`verifyBundleSignature`，用预埋真实 pin），杜绝生产调用方注入
/// 一个「恒返回成功」的 verifier 绕过签名验证。本端 stdlib 版本亦不经此层（固定在 `mintOfficialGrant`
/// 内读 `kHostStdlibVersion`，评审 P1）。测试注入 golden 测试锚请用 [AdapterLoader.forTesting]。
class AdapterLoader {
  /// 🔒 生产构造：verifier 固定为不可替换的生产实现（红线 #4：仅官方签名加载）。
  AdapterLoader({
    required BundleCache cache,
    required LastGoodStore lastGood,
    required BootstrapBaseline bootstrap,
    DistributionSource? source,
    int Function()? nowMs,
    void Function(String message)? onWarning,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) : this._(
         cache: cache,
         lastGood: lastGood,
         bootstrap: bootstrap,
         source: source,
         nowMs: nowMs,
         onWarning: onWarning,
         onDiagnostic: onDiagnostic,
         verifyCatalog: verifyCatalog,
         verifyRevocation: verifyRevocation,
         verifyBundle: verifyBundleSignature,
       );

  /// 🔒 **仅测试**：注入 golden 测试锚 verifier 跑同一条编排链（生产禁用；[visibleForTesting] lint
  /// 兜底，生产路径固定走 [AdapterLoader.new]，绝不注入 verifier）。
  @visibleForTesting
  AdapterLoader.forTesting({
    required BundleCache cache,
    required LastGoodStore lastGood,
    required BootstrapBaseline bootstrap,
    DistributionSource? source,
    int Function()? nowMs,
    void Function(String message)? onWarning,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
    required CatalogVerifier verifyCatalogFn,
    required RevocationVerifier verifyRevocationFn,
    required BundleVerifier verifyBundleFn,
  }) : this._(
         cache: cache,
         lastGood: lastGood,
         bootstrap: bootstrap,
         source: source,
         nowMs: nowMs,
         onWarning: onWarning,
         onDiagnostic: onDiagnostic,
         verifyCatalog: verifyCatalogFn,
         verifyRevocation: verifyRevocationFn,
         verifyBundle: verifyBundleFn,
       );

  AdapterLoader._({
    required BundleCache cache,
    required LastGoodStore lastGood,
    required BootstrapBaseline bootstrap,
    required DistributionSource? source,
    required int Function()? nowMs,
    required void Function(String message)? onWarning,
    required void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
    required CatalogVerifier verifyCatalog,
    required RevocationVerifier verifyRevocation,
    required BundleVerifier verifyBundle,
  }) : _cache = cache,
       _lastGood = lastGood,
       _bootstrap = bootstrap,
       _source = source,
       _nowMs = nowMs ?? _defaultNowMs,
       _verifyCatalog = verifyCatalog,
       _verifyRevocation = verifyRevocation,
       _verifyBundle = verifyBundle,
       _onWarning = onWarning,
       _onDiagnostic = onDiagnostic;

  final BundleCache _cache;
  final LastGoodStore _lastGood;
  final BootstrapBaseline _bootstrap;
  final DistributionSource? _source;
  final int Function() _nowMs;
  final CatalogVerifier _verifyCatalog;
  final RevocationVerifier _verifyRevocation;
  final BundleVerifier _verifyBundle;

  /// 非致命遥测钩子（如缓存写失败）。null = 静默。生产可接日志/上报。
  final void Function(String message)? _onWarning;
  final void Function(AdapterDiagnostic diagnostic)? _onDiagnostic;

  void _diagnose(AdapterDiagnosticKind kind, String stage, String message) {
    final diagnostic = AdapterDiagnostic(
      kind: kind,
      stage: stage,
      message: message,
    );
    (_activeSink ?? _onDiagnostic)?.call(diagnostic);
    _onWarning?.call(diagnostic.summary);
  }

  /// Deduplicate concurrent requests for the same adapter. Besides avoiding
  /// duplicate network and signature work, this keeps last-good writes ordered.
  final Map<String, Future<LoadResult>> _inFlight = {};

  /// 本次加载的 call-scoped 诊断 sink（[loadAdapter] 的 `onDiagnostic`）。编排器自身的
  /// [_diagnose] 与经 [reportDiagnostic] 上报的**分发源**诊断都路由到它；未设时回落构造期
  /// [_onDiagnostic]。由 [loadAdapter] 在加载生命周期内 set/restore，加载结束即复原——
  /// 取代旧的「AdapterService 持一个可变 sink 字段并被并发 run() 争用」两层间接（评审：可维护性）。
  ///
  /// **并发语义**：[loadAdapter] 按 adapterId 去重（[_inFlight]），故同一 adapter 的并发请求
  /// 会合流复用同一次加载与其 sink。分发源诊断经构造期固定的回调（[reportDiagnostic]）上报，属
  /// **环境态**、无法穿过 [DistributionSource] 接口逐调用透传：因此**并发加载不同 adapter** 时源诊断
  /// 可能落到相邻加载的 sink——仅影响 debug 诊断归属（不影响任何 fail-closed 裁定），可接受。
  void Function(AdapterDiagnostic diagnostic)? _activeSink;

  /// 供生产装配把**分发源**（[DistributionSource]）的诊断转接进本次加载的 [_activeSink]。
  void reportDiagnostic(AdapterDiagnostic diagnostic) {
    (_activeSink ?? _onDiagnostic)?.call(diagnostic);
  }

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// 🔒 加载指定 adapterId：走完 §2.6 全序，成功产出 official [LoadResult]。
  ///
  /// 全程 fail-closed：任一步不成立即 [LoadResult.fail]（带原因），绝不产出可加载结果。
  /// [onDiagnostic] 为**本次加载**的诊断 sink（debug/遥测用；见 [_activeSink]）。
  Future<LoadResult> loadAdapter(
    String adapterId, {
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) async {
    final existing = _inFlight[adapterId];
    if (existing != null) return existing;
    // 诊断 sink 随本次加载 call-scoped 挂载；onDiagnostic 为 null 时沿用外层（通常构造期）设置。
    final previousSink = _activeSink;
    _activeSink = onDiagnostic ?? previousSink;
    final future = _loadAdapter(adapterId);
    _inFlight[adapterId] = future;
    try {
      return await future;
    } finally {
      _activeSink = previousSink;
      if (identical(_inFlight[adapterId], future)) _inFlight.remove(adapterId);
    }
  }

  Future<LoadResult> _loadAdapter(String adapterId) async {
    // 步 1：解析 catalog（验签 + 防回滚 + 采纳持久化）。
    final catalog = await _resolveCatalog();
    if (catalog == null) {
      _diagnose(
        AdapterDiagnosticKind.missingSource,
        'catalog',
        '所有 catalog 来源均不可用或验签失败',
      );
      return const LoadResult.fail(
        '无可信 catalog（fetch/last-good/bootstrap 均缺或验签失败）',
      );
    }

    // 步 2：定位 entry（adapterId 在 catalog 内唯一——解析期已拒重复）。final → 可流敏提升，
    // 供下方闭包（[_readOrNull] 的 `() => _cache.read(entry.digest)`）安全解引用。
    final entry = _findEntry(catalog, adapterId);
    if (entry == null) {
      _diagnose(
        AdapterDiagnosticKind.policy,
        'catalog',
        'catalog 中不存在目标 adapter：$adapterId',
      );
      return LoadResult.fail('catalog 无此 adapter：$adapterId');
    }

    // 步 3/4：取 bundle 字节并还原 envelope+签名（内容寻址锚定到 entry.digest）。
    final BundleEnvelope env;
    final SignatureFile sig;
    Uint8List? packedToCache; // 非 null 时（来自 bootstrap/网络）在验签后写缓存。

    // cache 读取经 [_readOrNull]：存储故障（IOException）视为未命中并继续回退，绝不打断（评审 P1）。
    final cached = await _readOrNull(
      'bundle 缓存',
      () => _cache.read(entry.digest),
    );
    if (cached != null) {
      // cache.read 已保证「内容寻址 == entry.digest 且携带形状合法签名」。仍每次重验（下方步 5）。
      env = cached.envelope;
      sig = cached.signature;
    } else {
      final packed = await _fetchPacked(entry);
      if (packed == null) {
        _diagnose(
          AdapterDiagnosticKind.missingSource,
          'bundle',
          'cache、bootstrap 和网络均未提供 bundle：$adapterId',
        );
        return LoadResult.fail(
          '无法获取 bundle 字节（cache/bootstrap/网络均无）：$adapterId',
        );
      }
      final CachedBundle? unpacked = _unpackAndAddress(packed, entry.digest);
      if (unpacked == null) {
        return LoadResult.fail('bundle 内容寻址与 catalog 不符或缺签名/畸形：$adapterId');
      }
      env = unpacked.envelope;
      sig = unpacked.signature;
      packedToCache = packed;
    }

    // 步 5：Ed25519 验签 → 不可伪造 VerifiedBundle。
    final vr = await _verifyBundle(env, sig);
    if (!vr.ok) {
      _diagnose(
        AdapterDiagnosticKind.signature,
        'bundle',
        vr.reason ?? 'bundle 验签失败',
      );
      return LoadResult.fail('bundle 验签失败：${vr.reason}');
    }
    final verified = vr.value!;
    // 双保险：验签内部已核 sig.digest==envelopeDigest；此处再确认 == entry.digest（内容寻址锚定）。
    if (verified.digest != entry.digest) {
      _diagnose(
        AdapterDiagnosticKind.contentAddress,
        'bundle',
        'bundle digest 与 catalog 不符',
      );
      return LoadResult.fail(
        '验签 digest 与 catalog entry.digest 不符（fail-closed）',
      );
    }
    // 🔒 身份绑定（评审 #1，ADR-002 §2.2）：catalog entry 的身份必须 == bundle 的**权威身份**
    // （取自签名覆盖的 manifest，`verified.identity`）。否则一个 entry 可指向**另一个** adapter 的
    // 合法 signed bundle（内容寻址仍自洽），最终 LoadResult 会把 A 的 capabilities 贴到 B 的代码上
    // ——身份混淆。digest 只绑定内容，adapterId/version 是另一维，必须单独核对。
    if (verified.identity.adapterId != entry.adapterId ||
        verified.identity.adapterVersion != entry.adapterVersion) {
      return LoadResult.fail(
        'catalog entry 身份与 bundle 权威身份不符'
        '（entry ${entry.adapterId}@${entry.adapterVersion} vs '
        'bundle ${verified.identity.adapterId}@${verified.identity.adapterVersion}）'
        '→ fail-closed（ADR-002 §2.2）',
      );
    }

    // 步 6：解析 revocation（**验签之后**才做，贴合 §2.6 声明顺序，评审 P1）。无可信 revocation →
    // fail-closed 拒载（无法确认未被吊销，宁可不加载）。
    final revocation = await _resolveRevocation();
    if (revocation == null) {
      _diagnose(
        AdapterDiagnosticKind.missingSource,
        'revocation',
        '所有 revocation 来源均不可用或验签失败，无法确认未被吊销',
      );
      return const LoadResult.fail(
        '无可信 revocation（缺或验签失败）→ 无法确认未被吊销，fail-closed 拒载',
      );
    }

    // 步 7：吊销 + stdlibMin 门（先吊销后 stdlib；ref 取自 bundle 权威身份，不可伪造）。
    final grant = mintOfficialGrant(bundle: verified, revocation: revocation);
    if (!grant.ok) {
      _diagnose(AdapterDiagnosticKind.revoked, 'revocation', grant.reason!);
      return LoadResult.fail(grant.reason!);
    }

    // 步 8：铸 official 凭据；顺带把已验签 packed 写缓存。
    final trust = TrustedAdapterContext.official(grant.grant!);
    if (packedToCache != null) {
      // 缓存是 **best-effort 加速**（评审 #3）：本次加载已过全部门禁，缓存写入是否成功与本次结果
      // 无关。故**捕获一切**写入异常（不止 BundleFormatException——FileBlobStore 的目录/磁盘/rename
      // 失败是 IOException 等）并仅上报遥测，绝不让持久化故障毁掉一次已成功的加载（fail-open 反例）。
      try {
        await _cache.write(verified, packedToCache);
      } catch (e) {
        _diagnose(AdapterDiagnosticKind.storage, 'cache', 'bundle 缓存写入失败：$e');
      }
    }

    return LoadResult.ok(
      trust: trust,
      envelope: env,
      // 身份用**验签产物的权威身份**（`verified.identity`，已与 entry 核对一致），不再重新解析 envelope。
      identity: verified.identity,
      capabilities: entry.capabilities,
      digest: verified.digest,
      catalogIsFresh: catalogFresh(catalog, nowMs: _nowMs()),
      revocationIsFresh: revocationFresh(revocation, nowMs: _nowMs()),
    );
  }

  /// 取 packed bundle 字节：**bootstrap → 网络**（cache 命中在 [loadAdapter] 内先行处理）。
  /// 优先本地基线（离线可用），再退网络。两源同为内容寻址，安全等价，只差可用性。
  Future<Uint8List?> _fetchPacked(CatalogEntry entry) async {
    // bootstrap 读经 [_readOrNull]：存储故障不打断，继续退网络（评审 P1）。
    final baseline = await _readOrNull(
      'bootstrap bundle',
      () => _bootstrap.bundleByDigest(entry.digest),
    );
    if (baseline != null) return baseline;
    return _tryFetch((src) => src.fetchBundle(entry.url));
  }

  /// 在已验签 catalog 内按 adapterId 定位 entry（解析期已拒重复，故至多一条）；无 → null。
  /// 抽成方法使调用点得到 **final** 局部（可跨闭包流敏提升为非空）。
  CatalogEntry? _findEntry(VerifiedCatalog catalog, String adapterId) {
    for (final e in catalog.catalog.entries) {
      if (e.adapterId == adapterId) return e;
    }
    return null;
  }

  /// 🔒 读取一个**可选存储源**并把任何**存储故障**隔离成「本源不可用」（miss）（评审 P1）。
  ///
  /// 回退链（cache→bootstrap→网络 / bootstrap→last-good→网络）要求任一源失败都能继续尝试下一源。
  /// 「数据损坏」各存储层已自吞成 null（parse 失败 = miss）；但底层 [BlobStore]/[AssetSource] 的
  /// **存储故障**（IOException：权限 / 坏扇区 / 半写）会**抛**，若不隔离会直接掀翻整条回退链。此处
  /// 统一 catch：记录遥测（[_onWarning]）后返回 null，让调用方继续下一源。**所有来源都失败**时由
  /// 调用方各自返回 [LoadResult.fail]（见 [loadAdapter]），绝不向上抛未包装异常。
  Future<T?> _readOrNull<T>(String what, Future<T?> Function() read) async {
    try {
      return await read();
    } catch (e) {
      _diagnose(AdapterDiagnosticKind.storage, what, '读取失败，继续回退：$e');
      return null;
    }
  }

  /// 解包 + 内容寻址比对 + 取 detached 签名；不符/缺签名/畸形 → null（视为不可用）。
  CachedBundle? _unpackAndAddress(Uint8List packed, String expectedDigest) {
    try {
      final up = unpackBundle(packed);
      if (envelopeDigest(up.envelope) != expectedDigest) return null;
      final sigJson = up.signature;
      if (sigJson == null) return null; // 缺 detached 签名无法验签
      return CachedBundle(
        envelope: up.envelope,
        signature: SignatureFile.fromJson(sigJson),
      );
    } on BundleFormatException catch (e) {
      _diagnose(AdapterDiagnosticKind.decompression, 'bundle', '解包失败：$e');
      return null;
    } on FormatException catch (e) {
      _diagnose(AdapterDiagnosticKind.parse, 'bundle', '签名字段解析失败：$e');
      return null; // 签名字段畸形
    }
  }

  /// 解析当前 catalog：三源各自验签，取最高 sequence（防回滚）；采纳的若为网络份则持久化 last-good。
  ///
  /// 返回最高 sequence 的**已验签** catalog；一份都验不过 → null。
  Future<VerifiedCatalog?> _resolveCatalog() =>
      _resolveSigned<SignedCatalog, VerifiedCatalog>(
        label: 'catalog',
        readBootstrap: _bootstrap.catalog,
        readLastGood: _lastGood.readCatalog,
        fetchNetwork: (src) => src.fetchCatalog(),
        verify: _verifyCatalog,
        pickNewer: pickNewerCatalog,
        persist: _lastGood.writeCatalog,
      );

  /// 解析当前 revocation：同 [_resolveCatalog] 的三源 + 防回滚 + 采纳持久化。
  Future<VerifiedRevocationList?> _resolveRevocation() =>
      _resolveSigned<SignedRevocationList, VerifiedRevocationList>(
        label: 'revocation',
        readBootstrap: _bootstrap.revocation,
        readLastGood: _lastGood.readRevocation,
        fetchNetwork: (src) => src.fetchRevocation(),
        verify: _verifyRevocation,
        pickNewer: pickNewerRevocation,
        persist: _lastGood.writeRevocation,
      );

  /// 🔒 三源签名清单解析的公共骨架（catalog / revocation 同构：三源各自验签 → 取最高 sequence 防回滚
  /// → 网络份胜出才持久化 last-good）。抽出以杜绝两份易漂移的孪生实现（评审：重复逻辑）。
  ///
  /// **顺序不可乱**：bootstrap、last-good **先**加入，网络**最后**加入——[pickNewer] 仅在**严格新**时
  /// 替换，故与 last-good/bootstrap **同 sequence 的网络份不被采纳**（拒同序号替换 = 防回滚）。三源读取
  /// 均经 [_readOrNull] 隔离存储故障、各自验签失败仅记遥测；一份都验不过 → null（调用方据此 fail-closed）。
  Future<TVerified?> _resolveSigned<TSigned, TVerified>({
    required String label,
    required Future<TSigned?> Function() readBootstrap,
    required Future<TSigned?> Function() readLastGood,
    required Future<TSigned?> Function(DistributionSource source) fetchNetwork,
    required Future<VerifyResult<TVerified>> Function(TSigned signed) verify,
    required TVerified Function(TVerified a, TVerified b) pickNewer,
    required Future<void> Function(TVerified verified, TSigned signed) persist,
  }) async {
    final candidates = <TVerified>[];

    // 单源裁定：验签过则入选，否则仅记遥测（不打断其余源）。返回已验签值，供网络源记住以便持久化。
    Future<TVerified?> consider(String origin, TSigned? signed) async {
      if (signed == null) return null;
      final r = await verify(signed);
      if (r.ok) {
        final value = r.value as TVerified; // r.ok ⇒ value 非空（验签契约）。
        candidates.add(value);
        return value;
      }
      _diagnose(
        AdapterDiagnosticKind.signature,
        '$label/$origin',
        r.reason ?? '验签失败',
      );
      return null;
    }

    // bootstrap（基线，通常最旧）+ last-good（上次采纳）先加入；存储故障经 [_readOrNull] 隔离（评审 P1）。
    await consider(
      'bootstrap',
      await _readOrNull('bootstrap $label', readBootstrap),
    );
    await consider(
      'last-good',
      await _readOrNull('last-good $label', readLastGood),
    );

    // 网络（最新）最后加入；单独记住已验签结果 + 原始 signed，供采纳后持久化。
    final fetchedSigned = await _tryFetch(fetchNetwork);
    final fetched = await consider('network', fetchedSigned);

    if (candidates.isEmpty) return null;

    // 取最高 sequence（pickNewer：严格大于才替换 → 同序号保留先加入者 = 防回滚/防同序号替换）。
    var best = candidates.first;
    for (final c in candidates.skip(1)) {
      best = pickNewer(best, c);
    }

    // 仅当采纳的正是网络份（严格新于 last-good/bootstrap）才持久化为新 last-good。
    if (fetched != null && identical(best, fetched) && fetchedSigned != null) {
      try {
        await persist(fetched, fetchedSigned);
      } catch (_) {
        // 持久化失败不阻断本次加载（下次仍会重新拉取/验签）。
      }
    }
    return best;
  }

  /// 经**可选**网络源拉取（源为 null / 抛错 → null）：所有网络访问的统一 null-源 + 异常隔离点。
  Future<T?> _tryFetch<T>(
    Future<T?> Function(DistributionSource source) fetch,
  ) async {
    final src = _source;
    if (src == null) return null;
    try {
      return await fetch(src);
    } catch (_) {
      return null; // 网络失败 → 本源不可用（fail-closed 由上层退化处理）。
    }
  }
}
