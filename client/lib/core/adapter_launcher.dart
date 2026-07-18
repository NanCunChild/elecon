// 🔒🔒 片 G —— 把编排器产出的 official LoadResult 桥接到 fetch 运行时（ADR-018 §2.6 终点，红线 #1）。
//
// **本文件是 `adapter_runtime.dart` 的 part**（评审 P0-1）：唯一生产执行入口 [runLoadedAdapter] 需调用
// library-private 的 `_runFetchAdapter`，故与其同库；从而「运行任意 (source, trust)」的低层入口**不在
// 生产公开面上**。编排器（片 E `loader.dart`）验签 + 全门后产出 LoadResult（official 凭据 + 已验签
// envelope）。本层在触达运行时前把三件事钉死一致：
//
//   1. **source⟷凭据绑定（落实评审 E#2 的 enforcement）**：`_runFetchAdapter` 只收 source 字符串、
//      拿不到 envelope，无法自证「要跑的字节就是凭据所指的那份」。本层即那个核对点：source **只从
//      LoadResult.envelope 取**（不接受外部另传 source），并**重算 envelope digest 复核 == 凭据
//      digest**——从结构上消除「A 的 official 票 + B 的源码」的错配。
//   2. **注入策略取自权威 manifest**（ADR-002 §2.2）：BrokerManifestView（allow / credentials）从
//      bundle 内 manifest（digest 覆盖）解出，非 catalog 提示、非旁路配置。
//   3. **能力门**：只放行 manifest 声明的 capability（纵深，`_runFetchAdapter` 内仍复核档位）。
//
// fail-closed：[planLaunch] 任一步不一致即抛 [AdapterLaunchException]，绝不产出可执行 plan；只有
// official 档 LoadResult 走此路（dev 侧载有独立 debug-only 路径）。
//
// 🔒 红线 #1 凭证注入入口的上游接线：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
part of 'adapter_runtime.dart';

/// 接线期 fail-closed 拒绝（源⟷凭据不符 / manifest 畸形 / 能力越权等）。
class AdapterLaunchException implements Exception {
  const AdapterLaunchException(this.message);
  final String message;
  @override
  String toString() => 'AdapterLaunchException: $message';
}

/// 从 [LoadResult] 组装好、可直接喂 [runFetchAdapter] 的入参。
///
/// [source] 恒取自 [LoadResult.envelope]（不接受外部另传）；[view] 取自 bundle 内权威 manifest；
/// [trust] 为 official 凭据，其 [TrustedAdapterContext.digest] 已复核 == 本 envelope 的重算 digest。
class LaunchPlan {
  const LaunchPlan({
    required this.source,
    required this.trust,
    required this.view,
    required this.capabilities,
    required this.digest,
  });

  /// adapter 入口 JS 源码（envelope 内 `runtime.entry` 指向的 utf-8 文件）。
  final String source;

  /// official 运行时凭据（已绑定到本 bundle）。
  final TrustedAdapterContext trust;

  /// 权威注入策略视图（manifest.network.allow + credentials）。
  final BrokerManifestView view;

  /// manifest 声明的能力集（权威；能力门据此裁定）。
  final List<String> capabilities;

  /// 绑定 digest（== trust.digest == 重算 envelope digest）。
  final String digest;
}

/// 🔒 纯函数：校验 official [LoadResult] 并组装 [LaunchPlan]。任何不一致 → [AdapterLaunchException]。
///
/// **无副作用、无网络、无引擎**——安全逻辑全在此，便于单测穷举负例；真正执行是 [runLoadedAdapter] 的薄尾。
LaunchPlan planLaunch(LoadResult result) {
  if (!result.ok) {
    throw const AdapterLaunchException('不能启动失败的加载结果（fail-closed）');
  }
  final trust = result.trust!;
  if (trust.tier != AdapterTrustTier.official) {
    throw AdapterLaunchException(
      '仅 official 档走此接线（收到 ${trust.tier.name}）——dev 侧载另有 debug-only 路径',
    );
  }
  final env = result.envelope!;
  final boundDigest = trust.digest;
  if (boundDigest == null || boundDigest.isEmpty) {
    throw const AdapterLaunchException('official 凭据缺绑定 digest（fail-closed）');
  }

  // 🔒 source⟷凭据绑定（评审 E#2 的 enforcement 点）：重算 envelope digest 复核 == 凭据 digest。
  final String actualDigest;
  try {
    actualDigest = envelopeDigest(env);
  } on BundleFormatException catch (e) {
    throw AdapterLaunchException(
      'envelope 无法计算 digest：${e.message}（fail-closed）',
    );
  }
  if (actualDigest != boundDigest) {
    throw AdapterLaunchException(
      '将执行的源字节 digest 与凭据绑定 digest 不符 '
      '(${_short(actualDigest)} vs ${_short(boundDigest)}) → fail-closed（评审 E#2）',
    );
  }
  // 冗余但 fail-closed：LoadResult 内 digest 亦须与凭据一致（防手工构造的不一致 LoadResult）。
  if (result.digest != boundDigest) {
    throw const AdapterLaunchException(
      'LoadResult.digest 与凭据 digest 不符（fail-closed）',
    );
  }

  final Map<String, dynamic> manifest;
  try {
    manifest = readEnvelopeManifestJson(env);
  } on BundleFormatException catch (e) {
    throw AdapterLaunchException('manifest 读取失败：${e.message}（fail-closed）');
  }

  final source = _entrySource(env, manifest);
  final view = _viewFromManifest(manifest);
  final capabilities = _capabilities(manifest);

  return LaunchPlan(
    source: source,
    trust: trust,
    view: view,
    capabilities: capabilities,
    digest: boundDigest,
  );
}

/// 🔒 薄尾：[planLaunch] 后执行 adapter。session 注入 resolver / transport / jar / harvest 等运行时依赖
/// （它们属凭证存储 / 传输子系统，不由本层拥有）。能力越权在此 fail-closed。
Future<dynamic> runLoadedAdapter({
  required LoadResult result,
  required String capability,
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
}) {
  final plan = planLaunch(result);
  if (!plan.capabilities.contains(capability)) {
    throw AdapterLaunchException(
      'adapter 未声明能力 $capability（manifest 权威能力集：${plan.capabilities}）→ fail-closed',
    );
  }
  return _runFetchAdapter(
    source: plan.source,
    capability: capability,
    trust: plan.trust,
    view: plan.view,
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
}

/// 取 `runtime.entry` 指向的 **utf-8** 入口源码；缺失 / 非 utf-8 / 不在 bundle → fail-closed。
String _entrySource(BundleEnvelope env, Map<String, dynamic> manifest) {
  final runtime = manifest['runtime'];
  if (runtime is! Map) {
    throw const AdapterLaunchException('manifest 缺 runtime（fail-closed）');
  }
  final entry = runtime['entry'];
  if (entry is! String || entry.isEmpty) {
    throw const AdapterLaunchException(
      'manifest.runtime.entry 缺失或非法（fail-closed）',
    );
  }
  EnvelopeFile? file;
  for (final f in env.files) {
    if (f.path == entry) {
      file = f;
      break;
    }
  }
  if (file == null) {
    throw AdapterLaunchException('入口文件 $entry 不在 bundle（fail-closed）');
  }
  if (file.encoding != 'utf-8') {
    throw AdapterLaunchException('入口文件 $entry 非 utf-8 文本（fail-closed）');
  }
  try {
    return utf8.decode(file.bytes());
  } on FormatException catch (e) {
    throw AdapterLaunchException('入口文件 $entry 解码失败：$e（fail-closed）');
  }
}

/// 从权威 manifest 解出注入策略视图（allow + credentials）。任何畸形 → fail-closed。
BrokerManifestView _viewFromManifest(Map<String, dynamic> manifest) {
  final network = manifest['network'];
  if (network is! Map) {
    throw const AdapterLaunchException('manifest 缺 network（fail-closed）');
  }
  final allowRaw = network['allow'];
  if (allowRaw is! List) {
    throw const AdapterLaunchException(
      'manifest.network.allow 非数组（fail-closed）',
    );
  }
  final allow = <String>[];
  for (final a in allowRaw) {
    if (a is! String || a.isEmpty) {
      throw const AdapterLaunchException(
        'manifest.network.allow 含非法项（fail-closed）',
      );
    }
    allow.add(a);
  }

  final credentials = <String, CredentialDecl>{};
  final credRaw = manifest['credentials'];
  if (credRaw != null) {
    if (credRaw is! Map) {
      throw const AdapterLaunchException(
        'manifest.credentials 非对象（fail-closed）',
      );
    }
    credRaw.forEach((key, v) {
      if (key is! String || key.isEmpty) {
        throw const AdapterLaunchException(
          'manifest.credentials 含非法 ref（fail-closed）',
        );
      }
      if (v is! Map) {
        throw AdapterLaunchException(
          'manifest.credentials.$key 非对象（fail-closed）',
        );
      }
      final scopeRaw = v['scope'];
      if (scopeRaw is! List || scopeRaw.isEmpty) {
        throw AdapterLaunchException(
          'credentials.$key.scope 缺失或空（fail-closed）',
        );
      }
      final scope = <String>[];
      for (final s in scopeRaw) {
        if (s is! String || s.isEmpty) {
          throw AdapterLaunchException(
            'credentials.$key.scope 含非法项（fail-closed）',
          );
        }
        scope.add(s);
      }
      final type = v['type'];
      if (type != 'cookie' && type != 'header') {
        throw AdapterLaunchException(
          'credentials.$key.type 非 cookie/header（fail-closed）',
        );
      }
      final role = v['role'];
      if (role != null && role is! String) {
        throw AdapterLaunchException('credentials.$key.role 非字符串（fail-closed）');
      }
      credentials[key] = CredentialDecl(
        scope: scope,
        type: type,
        role: role as String?,
      );
    });
  }

  return BrokerManifestView(allow: allow, credentials: credentials);
}

/// manifest 权威能力集。
List<String> _capabilities(Map<String, dynamic> manifest) {
  final raw = manifest['capabilities'];
  if (raw is! List) {
    throw const AdapterLaunchException(
      'manifest.capabilities 非数组（fail-closed）',
    );
  }
  final caps = <String>[];
  for (final c in raw) {
    if (c is! String || c.isEmpty) {
      throw const AdapterLaunchException(
        'manifest.capabilities 含非法项（fail-closed）',
      );
    }
    caps.add(c);
  }
  return caps;
}

String _short(String d) => d.length <= 12 ? d : '${d.substring(0, 12)}…';
