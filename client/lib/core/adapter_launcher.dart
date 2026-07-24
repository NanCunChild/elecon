// 🔒🔒 片 G —— 把编排器产出的 official LoadResult 桥接到 adapter 运行时（ADR-018 §2.6 终点，红线 #1）。
//
// **本文件是 `adapter_runtime.dart` 的 part**（评审 P0-1）：唯一生产执行入口 [runLoadedAdapter] 需调用
// library-private 的 `_runImperativeAdapter`，故与其同库；从而「运行任意 (source, trust)」的低层入口**不在
// 生产公开面上**。编排器（片 E `loader.dart`）验签 + 全门后产出 LoadResult（official 凭据 + 已验签
// envelope）。本层在触达运行时前把三件事钉死一致：
//
//   1. **source⟷凭据绑定（落实评审 E#2 的 enforcement）**：`_runImperativeAdapter` 只收 source 字符串、
//      拿不到 envelope，无法自证「要跑的字节就是凭据所指的那份」。本层即那个核对点：source **只从
//      LoadResult.envelope 取**（不接受外部另传 source），并**重算 envelope digest 复核 == 凭据
//      digest**——从结构上消除「A 的 official 票 + B 的源码」的错配。
//   2. **注入策略取自权威 manifest**（ADR-002 §2.2）：BrokerManifestView（allow / credentials）从
//      bundle 内 manifest（digest 覆盖）解出，非 catalog 提示、非旁路配置。
//   3. **能力门**：只放行 manifest 声明的 capability（纵深，`_runImperativeAdapter` 内仍复核档位）。
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

/// 从 [LoadResult] 组装好、可直接喂 [runLoadedAdapter] 的入参。
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
    required this.capabilityRequestGraphs,
    required this.capabilityRequests,
    this.capabilityDataflow = const {},
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

  /// capability id → `requestGraph`（`declarative` | `imperative`；按本次 capability 分派）。
  final Map<String, String> capabilityRequestGraphs;

  /// capability id → `requests[]` 配方（仅 declarative 用；imperative 为空 map）。
  final Map<String, List<DeclarativeRequestDecl>> capabilityRequests;

  /// capability id → 声明式跨请求数据流（ADR-023 `bind`/`compute`/`inject`）。
  /// 仅 declarative 用；缺省即无数据流（退化为平铺代取）。校验器 D1–D16 已在提交期把关。
  final Map<String, CapabilityDataflow> capabilityDataflow;
}

/// 一个 declarative capability 的数据流三段（ADR-023）。空 = 无数据流。
class CapabilityDataflow {
  const CapabilityDataflow({
    this.binds = const [],
    this.computes = const [],
    this.injects = const [],
  });

  final List<BindDecl> binds;
  final List<ComputeDecl> computes;
  final List<InjectDecl> injects;

  bool get isEmpty => binds.isEmpty && computes.isEmpty && injects.isEmpty;
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
  final capabilityRequestGraphs = _capabilityRequestGraphs(manifest);
  final capabilityRequests = _capabilityRequests(manifest);
  final capabilityDataflow = _capabilityDataflow(manifest);

  return LaunchPlan(
    source: source,
    trust: trust,
    view: view,
    capabilities: capabilities,
    digest: boundDigest,
    capabilityRequestGraphs: capabilityRequestGraphs,
    capabilityRequests: capabilityRequests,
    capabilityDataflow: capabilityDataflow,
  );
}

/// 🔒 薄尾：[planLaunch] 后执行 adapter。session 注入 resolver / transport / jar / harvest 等运行时依赖
/// （它们属凭证存储 / 传输子系统，不由本层拥有）。能力越权在此 fail-closed。
///
/// 按本次 capability 的 `requestGraph` 分派（ADR-022）：
/// `declarative` → 核心代取 [fulfillDeclarativeRequests] + [runDeclarativeAdapter]；
/// `imperative` → 官方签名 imperative 路径 [_runImperativeAdapter]。
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
}) async {
  final plan = planLaunch(result);
  if (!plan.capabilities.contains(capability)) {
    throw AdapterLaunchException(
      'adapter 未声明能力 $capability（manifest 权威能力集：${plan.capabilities}）→ fail-closed',
    );
  }

  final requestGraph = plan.capabilityRequestGraphs[capability];
  if (requestGraph == null) {
    throw AdapterLaunchException(
      'capability $capability 缺 requestGraph（fail-closed）',
    );
  }

  if (requestGraph == 'declarative') {
    final requests = plan.capabilityRequests[capability] ?? const [];
    final dataflow =
        plan.capabilityDataflow[capability] ?? const CapabilityDataflow();
    final Map<String, dynamic> responses;
    try {
      responses = await fulfillDeclarativeRequests(
        requests: requests,
        params: params ?? const {},
        view: plan.view,
        resolver: resolver,
        transport: transport,
        jar: jar,
        maxRequests: fetchLimits.maxRequests,
        nowMs: nowMs,
        binds: dataflow.binds,
        computes: dataflow.computes,
        injects: dataflow.injects,
      );
    } on DeclarativeHostException catch (e) {
      throw AdapterRunException(
        e.limitExceeded
            ? AdapterFailureReason.fetchLimit
            : AdapterFailureReason.badResult,
        e.message,
      );
    }
    return runDeclarativeAdapter(
      source: plan.source,
      capability: capability,
      params: params,
      responses: responses,
      htmlStdlib: htmlStdlib,
      nowMs: nowMs,
      memoryBytes: memoryBytes,
    );
  }

  return _runImperativeAdapter(
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

/// 各 capability 的 `requestGraph`（`declarative` | `imperative`）。缺省 / 非法 → fail-closed。
Map<String, String> _capabilityRequestGraphs(Map<String, dynamic> manifest) {
  final raw = manifest['capabilities'];
  if (raw is! List) return const {};
  final out = <String, String>{};
  for (final c in raw) {
    if (c is! Map) continue;
    final id = c['id'];
    if (id is! String || id.isEmpty) continue;
    final rg = c['requestGraph'];
    if (rg != 'declarative' && rg != 'imperative') {
      throw AdapterLaunchException(
        'capabilities.$id.requestGraph 缺失或非法（fail-closed）',
      );
    }
    out[id] = rg as String;
  }
  return out;
}

/// 各 capability 的 `requests[]`（declarative 代取配方）。畸形 → fail-closed。
Map<String, List<DeclarativeRequestDecl>> _capabilityRequests(
  Map<String, dynamic> manifest,
) {
  final raw = manifest['capabilities'];
  if (raw is! List) return const {};
  final out = <String, List<DeclarativeRequestDecl>>{};
  for (final c in raw) {
    if (c is! Map) continue;
    final id = c['id'];
    if (id is! String || id.isEmpty) continue;
    final reqsRaw = c['requests'];
    if (reqsRaw == null) {
      out[id] = const [];
      continue;
    }
    if (reqsRaw is! List) {
      throw AdapterLaunchException(
        'capabilities.$id.requests 非数组（fail-closed）',
      );
    }
    final list = <DeclarativeRequestDecl>[];
    final keys = <String>{};
    for (final r in reqsRaw) {
      if (r is! Map) {
        throw AdapterLaunchException(
          'capabilities.$id.requests 含非法项（fail-closed）',
        );
      }
      final key = r['key'];
      final method = r['method'];
      final url = r['url'];
      if (key is! String ||
          key.isEmpty ||
          method is! String ||
          method.isEmpty ||
          url is! String ||
          url.isEmpty) {
        throw AdapterLaunchException(
          'capabilities.$id.requests 项缺 key/method/url（fail-closed）',
        );
      }
      if (!keys.add(key)) {
        throw AdapterLaunchException(
          'capabilities.$id.requests 重复 key=$key（fail-closed）',
        );
      }
      final cred = r['credential'];
      if (cred != null && cred is! String) {
        throw AdapterLaunchException(
          'capabilities.$id.requests.$key.credential 非字符串（fail-closed）',
        );
      }
      list.add(
        DeclarativeRequestDecl(
          key: key,
          method: method,
          url: url,
          credential: cred as String?,
        ),
      );
    }
    out[id] = list;
  }
  return out;
}

/// 解出各 declarative capability 的数据流三段（ADR-023 `bind`/`compute`/`inject`）。
///
/// 结构合法性（引用闭合、类型、汇聚点、限额）由提交期校验器 D1–D16 把关；此处只做**形状**
/// 解码 + fail-closed（畸形 = 拒启动）。imperative capability 若带这三段亦拒（对应校验器 D1）。
Map<String, CapabilityDataflow> _capabilityDataflow(
  Map<String, dynamic> manifest,
) {
  final raw = manifest['capabilities'];
  if (raw is! List) return const {};
  final out = <String, CapabilityDataflow>{};
  for (final c in raw) {
    if (c is! Map) continue;
    final id = c['id'];
    if (id is! String || id.isEmpty) continue;

    final binds = _parseBinds(id, c['bind']);
    final computes = _parseComputes(id, c['compute']);
    final injects = _parseInjects(id, c['inject']);
    if (binds.isEmpty && computes.isEmpty && injects.isEmpty) continue;

    // 纵深防御（校验器 D1）：非 declarative 不得带数据流。
    if (c['requestGraph'] != 'declarative') {
      throw AdapterLaunchException(
        'capabilities.$id 非 declarative 却声明了数据流 bind/compute/inject（fail-closed）',
      );
    }
    out[id] = CapabilityDataflow(
      binds: binds,
      computes: computes,
      injects: injects,
    );
  }
  return out;
}

List<BindDecl> _parseBinds(String capId, Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw AdapterLaunchException('capabilities.$capId.bind 非数组（fail-closed）');
  }
  return raw.map((e) {
    if (e is! Map) {
      throw AdapterLaunchException(
        'capabilities.$capId.bind 含非法项（fail-closed）',
      );
    }
    final varName = e['var'];
    final from = e['from'];
    final source = e['source'];
    final extract = e['extract'];
    if (varName is! String ||
        from is! String ||
        source is! String ||
        extract is! Map) {
      throw AdapterLaunchException(
        'capabilities.$capId.bind 项缺 var/from/source/extract（fail-closed）',
      );
    }
    return BindDecl(
      varName: varName,
      from: from,
      source: source,
      extract: extract.cast<String, dynamic>(),
    );
  }).toList();
}

List<ComputeDecl> _parseComputes(String capId, Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw AdapterLaunchException(
      'capabilities.$capId.compute 非数组（fail-closed）',
    );
  }
  return raw.map((e) {
    if (e is! Map) {
      throw AdapterLaunchException(
        'capabilities.$capId.compute 含非法项（fail-closed）',
      );
    }
    final varName = e['var'];
    final op = e['op'];
    final args = e['args'];
    if (varName is! String || op is! String || args is! List) {
      throw AdapterLaunchException(
        'capabilities.$capId.compute 项缺 var/op/args（fail-closed）',
      );
    }
    return ComputeDecl(
      varName: varName,
      op: op,
      args: args.map((a) {
        if (a is! Map) {
          throw AdapterLaunchException(
            'capabilities.$capId.compute.args 含非法项（fail-closed）',
          );
        }
        return ComputeArg(ref: a['ref'] as String?, text: a['text'] as String?);
      }).toList(),
      params: (e['params'] as Map?)?.cast<String, dynamic>(),
    );
  }).toList();
}

List<InjectDecl> _parseInjects(String capId, Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw AdapterLaunchException('capabilities.$capId.inject 非数组（fail-closed）');
  }
  return raw.map((e) {
    if (e is! Map) {
      throw AdapterLaunchException(
        'capabilities.$capId.inject 含非法项（fail-closed）',
      );
    }
    final varName = e['var'];
    final into = e['into'];
    final at = e['at'];
    final name = e['name'];
    if (varName is! String ||
        into is! String ||
        at is! String ||
        name is! String) {
      throw AdapterLaunchException(
        'capabilities.$capId.inject 项缺 var/into/at/name（fail-closed）',
      );
    }
    return InjectDecl(varName: varName, into: into, at: at, name: name);
  }).toList();
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
///
/// **与 `contract/manifest.schema.json` 是两处真值、刻意如此**：此处是**运行时**在已验签 bundle 上做的
/// **最小结构** fail-closed 校验（不能信任构建期校验，必须独立自证够安全再执行）；contract schema 是
/// **发布期**的更严格校验（如 `emits.schemaVersion` 须匹配 `^\d+\.\d+$`、`id` 须在 registry 注册）。
/// 二者会漂移：本函数**故意更宽松**（只查非空 + 形状 + 去重），严格规则不在此复刻。改 manifest 能力结构
/// 时须**同步**改这两处，并优先在 contract 侧收严（评审：重复逻辑）。
List<String> _capabilities(Map<String, dynamic> manifest) {
  final raw = manifest['capabilities'];
  if (raw is! List) {
    throw const AdapterLaunchException(
      'manifest.capabilities 非数组（fail-closed）',
    );
  }
  final caps = <String>[];
  for (final c in raw) {
    if (c is! Map) {
      throw const AdapterLaunchException(
        'manifest.capabilities 含非法项（fail-closed）',
      );
    }
    final id = c['id'];
    final emits = c['emits'];
    if (id is! String || id.isEmpty || emits is! Map) {
      throw const AdapterLaunchException(
        'manifest.capabilities 含非法项（fail-closed）',
      );
    }
    final schema = emits['schema'];
    final schemaVersion = emits['schemaVersion'];
    if (schema is! String ||
        schema.isEmpty ||
        schemaVersion is! String ||
        schemaVersion.isEmpty) {
      throw const AdapterLaunchException(
        'manifest.capabilities 含非法项（fail-closed）',
      );
    }
    if (caps.contains(id)) {
      throw const AdapterLaunchException(
        'manifest.capabilities 含重复项（fail-closed）',
      );
    }
    caps.add(id);
  }
  return caps;
}

String _short(String d) => d.length <= 12 ? d : '${d.substring(0, 12)}…';
