/// 核心代取 declarative 请求（delivery A2）—— ADR-001 §6.2 / 红线 #5 / ADR-022。
///
/// declarative capability **无网络**：宿主据 manifest `capabilities[].requests[]` 出网代取，
/// 经 broker（allow 闸门 / 可选凭证注入 / 重定向自跟随 / 响应脱敏）后，按 `key`
/// 组装 `responses` 喂 declarative 入口。凭证值永不进 adapter（红线 #1）。
///
/// 公开能力（如 `school-xidian` `notice.list`）无 `credential` → passthrough。
library;

import 'broker/assemble.dart' show RequestInit;
import 'broker/cookie_jar.dart' show CookieJar;
import 'broker/dataflow.dart' as df;
import 'broker/fetch_proxy.dart'
    show
        BrokerFetchRejected,
        FetchProxyDeps,
        FetchRequestLimitExceeded,
        Transport,
        TransportBodyLimitException,
        proxyFetch;
import 'broker/inject_policy.dart'
    show BrokerManifestView, InjectDecision, InjectionDecision, decideInjection;
import 'broker/harvest.dart' show QueryHarvestTarget;
import 'broker/ports.dart' show CredentialResolver;

export 'broker/dataflow.dart'
    show BindDecl, ComputeArg, ComputeDecl, InjectDecl, DataflowException;

/// manifest `capabilities[].requests[]` 一项（运行时已 fail-closed 校验形状）。
class DeclarativeRequestDecl {
  const DeclarativeRequestDecl({
    required this.key,
    required this.method,
    required this.url,
    this.credential,
  });

  final String key;
  final String method;
  final String url;
  final String? credential;
}

/// 代取期 fail-closed（URL 展开 / broker 拒绝 / 网络 / 限额）。
class DeclarativeHostException implements Exception {
  const DeclarativeHostException(this.message, {this.limitExceeded = false});

  final String message;
  final bool limitExceeded;

  @override
  String toString() => 'DeclarativeHostException: $message';
}

/// 将 URL 模板中的 `{param}` 替换为 [params] 值（值做 URI 组件编码）。
String expandRequestUrl(String template, Map<String, dynamic> params) {
  return template.replaceAllMapped(RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}'), (
    m,
  ) {
    final name = m.group(1)!;
    final v = params[name];
    if (v == null) {
      throw FormatException('declarative request URL 缺参数 {$name}');
    }
    if (v is! String && v is! num && v is! bool) {
      throw FormatException('declarative request URL 参数 {$name} 类型非法');
    }
    return Uri.encodeComponent('$v');
  });
}

/// 对 [requests] 代取，返回 `key → {status, headers, body}`（已脱敏）。
///
/// 声明式跨请求数据流（ADR-023）：给出 [binds]/[computes]/[injects] 时，宿主按**请求依赖
/// 拓扑序**代取——`bind` 在脱敏**前**抽取句柄（broker 内部）、`compute` 封闭 op 原生求值、
/// `inject` 把句柄注入下游请求的静态汇聚点、并在交回 adapter 前**剥除注入值回显**。句柄、
/// 中间响应、注入值全程**不进 adapter**（红线 #1）。三者皆空 → 退化为原平铺代取（等价）。
///
/// 数据流的抽取/计算/注入/脱敏/拓扑语义由 `broker/dataflow.dart` 承载，与服务端 TS 参考
/// 实现照 `contract/golden/broker/dataflow.json` 双跑逐字节一致（ADR-001 §8）。校验器
/// D1–D16 已在声明期保证结构合法；此处只保留运行期 fail-closed（纵深防御）。
Future<Map<String, dynamic>> fulfillDeclarativeRequests({
  required List<DeclarativeRequestDecl> requests,
  required Map<String, dynamic> params,
  required BrokerManifestView view,
  required CredentialResolver resolver,
  required Transport transport,
  CookieJar? jar,
  QueryHarvestTarget? queryHarvest,
  int maxRequests = 20,
  int nowMs = 0,
  List<df.BindDecl> binds = const [],
  List<df.ComputeDecl> computes = const [],
  List<df.InjectDecl> injects = const [],
}) async {
  final out = <String, dynamic>{};
  final effectiveJar = jar ?? CookieJar();
  var used = 0;

  final reqByKey = {for (final r in requests) r.key: r};

  // 请求依赖拓扑分层（无依赖同层；靠后层依赖靠前层）。无数据流 → 单层、保持声明序 = 原平铺。
  final List<List<String>> layers;
  try {
    layers = df.planRequestOrder(
      requests
          .map(
            (r) => df.DataflowRequestDecl(
              key: r.key,
              url: r.url,
              method: r.method,
            ),
          )
          .toList(),
      binds,
      computes,
      injects,
    );
  } on df.DataflowException catch (e) {
    throw DeclarativeHostException('declarative 数据流拓扑非法：${e.message}');
  }

  // 句柄环境：bind 结果 + compute 记忆化。compute 惰性按需求值（引用天然向前，DAG 无环）。
  final bound = <String, df.HandleValue>{};
  final computeByVar = {for (final c in computes) c.varName: c};
  final computeMemo = <String, df.HandleValue>{};
  var dagBytes = 0;

  // 🔒 全 DAG 4 MB 预算：**每个** bind 句柄 + **每个** compute 输出都计入，按 UTF-8 字节
  //（`df.handleByteLen`）——与服务端 `evalComputeGraph` 计量口径一致（审阅 issue 3 / C2）。
  void chargeBudget(df.HandleValue h) {
    dagBytes += df.handleByteLen(h);
    if (dagBytes > df.maxDagHandleBytes) {
      throw const DeclarativeHostException(
        '数据流全 DAG 句柄总预算超限',
        limitExceeded: true,
      );
    }
  }

  df.HandleValue resolveVar(String name) {
    final b = bound[name];
    if (b != null) return b;
    final m = computeMemo[name];
    if (m != null) return m;
    final c = computeByVar[name];
    if (c == null) {
      throw DeclarativeHostException('数据流引用未定义：$name（应由校验器 D7 挡下）');
    }
    final args = c.args
        .map(
          (a) => a.text != null ? df.TextHandle(a.text!) : resolveVar(a.ref!),
        )
        .toList();
    final df.HandleValue r;
    try {
      r = df.evalOp(c.op, args, c.params, nowMs);
    } on df.DataflowException catch (e) {
      throw DeclarativeHostException('数据流 compute 失败：${e.message}');
    }
    chargeBudget(r);
    computeMemo[name] = r;
    return r;
  }

  for (final layer in layers) {
    // 层内请求相互无依赖（可并发）；MVP 顺序执行，保证 cookie jar 与请求计量的确定性。
    for (final key in layer) {
      final req = reqByKey[key]!;

      // ① 解析注入本请求的效果（句柄须为 text；缺失/类型错 → fail-closed，决策 6）。
      final effects = <df.InjectionEffect>[];
      for (final inj in injects) {
        if (inj.into != key) continue;
        final v = resolveVar(inj.varName);
        if (v is! df.TextHandle) {
          throw DeclarativeHostException(
            'declarative 注入 ${inj.varName} 非 text（注入面只接受 text）',
          );
        }
        final effect = df.InjectionEffect(
          into: key,
          at: inj.at,
          name: inj.name,
          value: v.text,
        );
        effects.add(effect);
      }

      // ② 展开 URL 模板，再应用注入（url 追加 query / header 交 broker 置头）。
      final String expandedUrl;
      try {
        expandedUrl = expandRequestUrl(req.url, params);
      } on FormatException catch (e) {
        throw DeclarativeHostException('declarative 代取 URL 展开失败：${e.message}');
      }
      final applied = df.applyInjections(
        df.DataflowRequestDecl(key: key, url: expandedUrl, method: req.method),
        effects,
      );
      final url = applied.url;
      final headerInjects = applied.headers;

      // ③ 凭证策略（双向权威，红线 #1）：注入 URL 后再判，防展开/注入后落入凭证 scope。
      final decision = decideInjection(url, view);
      _assertCredentialPolicy(req, decision);

      if (used >= maxRequests) {
        throw const DeclarativeHostException(
          'declarative 代取超过单次执行请求上限',
          limitExceeded: true,
        );
      }

      // ④ 代取（脱敏前经 onRawResponse 抽取本请求的 bind 句柄）。
      df.RawResponse? rawForExtract;
      try {
        final outcome = await proxyFetch(
          url,
          RequestInit(method: req.method),
          FetchProxyDeps(
            view: view,
            resolver: resolver,
            jar: effectiveJar,
            transport: transport,
            queryHarvest: queryHarvest,
            brokerInjectHeaders: headerInjects.isEmpty ? null : headerInjects,
            onRawResponse: (status, headers, body) {
              rawForExtract = df.RawResponse(
                status: status,
                headers: headers,
                body: body ?? '',
              );
            },
            tryReserveRequest: () {
              if (used >= maxRequests) return false;
              used++;
              return true;
            },
          ),
        );

        // ⑤ 抽取本请求的 bind 句柄（脱敏前 raw；失败一律 fail-closed，决策 6）。
        for (final b in binds) {
          if (b.from != key) continue;
          if (rawForExtract == null) {
            throw const DeclarativeHostException(
              'declarative bind 抽取缺原始响应（内部错误）',
            );
          }
          final df.HandleValue handle;
          try {
            handle = df.extractHandle(b, rawForExtract!);
          } on df.DataflowException catch (e) {
            // 🔒 错误只进宿主诊断，不含句柄内容；adapter 侧只见整条 capability 失败。
            throw DeclarativeHostException(
              'declarative bind 抽取失败：${e.message}',
            );
          }
          bound[b.varName] = handle;
          chargeBudget(handle); // 🔒 bind 句柄计入全 DAG 预算（与服务端一致，issue 3）
        }

        // ⑥ 交回 adapter（注入值回显 blanket 剥离已退役，2026-08-05 ADR-023 §2.5：回显交
        //    Masker 作者 `redact` 承接，ADR-026 §2.10；此处不再做反射剥离）。
        out[key] = <String, dynamic>{
          'status': outcome.status,
          'headers': outcome.headers,
          if (outcome.body != null) 'body': outcome.body,
        };
      } on BrokerFetchRejected catch (e) {
        throw DeclarativeHostException('declarative 代取被拒绝：${e.reason}');
      } on FetchRequestLimitExceeded {
        throw const DeclarativeHostException(
          'declarative 代取超过单次执行请求上限',
          limitExceeded: true,
        );
      } on TransportBodyLimitException catch (e) {
        throw DeclarativeHostException(
          'declarative 代取响应体超限（${e.maxBytes} bytes）',
        );
      } catch (e) {
        if (e is DeclarativeHostException) rethrow;
        throw DeclarativeHostException('declarative 代取网络失败：$e');
      }
    }
  }

  // 🔒 补算未被任何注入引用到的 compute（全部 bind 此刻已就绪）：使**所有** compute 都被求值
  // 与计入预算，且任何求值失败都 fail-closed——与服务端 evalComputeGraph「eval 全部 + 计全部」
  // 对称（审阅 issue 3 / C2）。否则「惰性只算被引用的」会在两端产生放行/拒绝差异。
  for (final c in computes) {
    resolveVar(c.varName);
  }

  return out;
}

void _assertCredentialPolicy(
  DeclarativeRequestDecl req,
  InjectionDecision decision,
) {
  final want = req.credential;
  if (want == null || want.isEmpty) {
    // 未声明 credential 的请求：注入决策**不得**命中任何凭证。否则展开后的 URL 恰落在某
    // 凭证 scope 时会被 broker 静默注入，令 `requests[].credential` 字段失去可审计性
    // （审阅者读 manifest 会误判"无字段=不带凭证"）。fail-closed：强制每条带凭证的请求
    // 都在 manifest 里显式声明——`credential` 字段双向权威（红线 #1 可审计面）。
    if (decision is InjectDecision) {
      throw DeclarativeHostException(
        'declarative 请求未声明 credential，但 URL 命中凭证注入 ref=${decision.ref}'
        '（须在 requests[].credential 显式声明）→ fail-closed',
      );
    }
    return;
  }
  if (decision is! InjectDecision) {
    throw DeclarativeHostException(
      'declarative 请求 credential=$want 但注入决策非 inject（${decision.toJson()}）',
    );
  }
  if (decision.ref != want) {
    throw DeclarativeHostException(
      'declarative 请求 credential=$want 与注入决策 ref=${decision.ref} 不符',
    );
  }
}
