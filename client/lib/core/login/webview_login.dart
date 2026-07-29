/// 核心托管 WebView 登录收割（ADR-012 §2.2 / ADR-015）。
///
/// 本文件只放核心侧纯逻辑：导航闭锁、成功 URL 判定、WebView cookie 视图转 B5
/// 收割输入、写入 CredentialStore。它不依赖 Flutter WebView 插件，便于测试。
///
/// 🔒 红线 #1：cookie 值只进入核心收割路径，调用方不得把 [WebViewCookie.value]
/// 写入 UI/log/adapter。
library;

import '../broker/cookie_jar.dart';
import '../broker/harvest.dart';
import '../broker/inject_policy.dart';
import '../broker/url_match.dart';
import '../credential/types.dart';

class LoginManifestView {
  const LoginManifestView({
    required this.schoolId,
    required this.url,
    required this.navigationAllow,
    required this.successUrlMatches,
    required this.brokerView,
    this.ssoMint,
  });

  final String schoolId;
  final String url;
  final List<String> navigationAllow;
  final List<String> successUrlMatches;
  final BrokerManifestView brokerView;

  /// CAS SSO 静默签票声明（ADR-017 §2.5）。可选；缺省=逐服务可见登录。
  final SsoMintDecl? ssoMint;
}

/// CAS 静默签票声明（ADR-017 §2.5）。key=换票产物 credential ref。
class SsoMintDecl {
  const SsoMintDecl({required this.authEndpoint, required this.services});

  /// CAS 认证端点模板，含 `{service}` 占位（母凭证只注入此域，ADR-017 §2.4）。
  final String authEndpoint;
  final Map<String, SsoMintServiceDecl> services;
}

/// 静默 mint 执行形态（ADR-017 §2.7）。可见登录不属于本枚举，由核心恒定兜底。
enum SsoMintForm {
  hiddenWebView('hidden-webview'),
  headless('headless');

  const SsoMintForm(this.wireName);

  final String wireName;

  static SsoMintForm? tryParse(Object? value) {
    for (final form in values) {
      if (form.wireName == value) return form;
    }
    return null;
  }
}

class SsoMintServiceDecl {
  const SsoMintServiceDecl({
    required this.service,
    required this.success,
    this.via,
    this.forms,
  });

  /// 目标服务 URL（填入 authEndpoint 的 `{service}`）。
  final String service;

  /// 换票成功检测 URL 模式（≥1）。
  final List<String> success;

  /// 非简单 GET-redirect 时指向承载 mint 请求构造的 adapter 能力 id（缺省=内置）。
  final String? via;

  /// 允许的静默形态及偏好顺序。null=客户端默认少模拟优先；非空=manifest 显式顺序。
  final List<SsoMintForm>? forms;
}

class WebViewCookie {
  const WebViewCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    this.isHttpOnly,
    this.isSecure,
  });

  final String name;
  final String value;
  final String domain;
  final String path;

  /// 平台 cookie 属性（仅诊断用；null=平台未上报）。收割/注入逻辑不依赖它们——
  /// 用于排查「CAS 母票 / 下游 session 常为 HttpOnly，是否被 WebView 桥丢弃导致收割不到」。
  final bool? isHttpOnly;
  final bool? isSecure;
}

class WebViewHarvestResult {
  const WebViewHarvestResult({required this.entries});

  final List<HarvestEntry> entries;

  bool get harvested => entries.isNotEmpty;
}

/// 收割需读取 cookie 的域代表 URL（origin）：取 brokerView.credentials 各 scope 的 host。
///
/// 跨子域覆盖的关键（ADR-017 母凭证收割）：CAS 母凭证（CASTGC）落在 `ids` 子域、
/// 下游 session 落在 `ehall`/`v8scan` 等子域；成功 URL 只在其中一个子域，若只 getCookies
/// 成功 URL 的 host 会**漏掉母凭证**。据此枚举全部声明域，逐一收割再合并。
Set<String> harvestCookieOrigins(LoginManifestView view) {
  final origins = <String>{};
  for (final decl in view.brokerView.credentials.values) {
    for (final scope in decl.scope) {
      final repr = scopeReprUrl(scope); // 'https://host/path'
      if (repr == null) continue;
      final uri = Uri.tryParse(repr);
      if (uri != null && uri.host.isNotEmpty) {
        origins.add('${uri.scheme}://${uri.host}/');
      }
    }
  }
  return origins;
}

bool isLoginNavigationAllowed(String url, LoginManifestView view) =>
    urlCoveredByAllow(url, view.navigationAllow);

bool isLoginSuccessUrl(String url, LoginManifestView view) =>
    view.successUrlMatches.any((pattern) => scopeMatches(url, pattern));

List<JarCookie> webViewCookiesToHarvestCookies(List<WebViewCookie> cookies) {
  return cookies
      .where((c) => c.name.isNotEmpty && c.domain.isNotEmpty)
      .map(
        (c) => JarCookie(
          name: c.name,
          value: c.value,
          domain: c.domain.toLowerCase().replaceFirst(RegExp(r'^\.'), ''),
          path: c.path.isEmpty ? '/' : c.path,
          source: 'origin',
        ),
      )
      .toList();
}

/// 收割干跑（纯，不写 store）：当前 WebView cookie 视图能收割出哪些声明凭证。
///
/// 供页面侧**有界轮询**用：成功 URL 命中后 session cookie 可能尚未全部落定
/// （此前用固定 600ms 延迟赌它落定），改为轮询本判定直至计划非空且稳定，
/// 或到轮询上限——比固定 sleep 更快也更稳（审阅建议 P2-5）。
List<HarvestEntry> planWebViewHarvest({
  required LoginManifestView login,
  required List<WebViewCookie> cookies,
  String? currentUrl,
}) {
  final plan = decideHarvest(
    webViewCookiesToHarvestCookies(cookies),
    login.brokerView,
  );
  if (currentUrl != null) {
    plan.addAll(decideQueryHarvest(currentUrl, login.brokerView));
    plan.sort((a, b) => a.ref.compareTo(b.ref));
  }
  return plan;
}

WebViewHarvestResult harvestWebViewCookies({
  required LoginManifestView login,
  required List<WebViewCookie> cookies,
  String? currentUrl,
  required void Function(CredentialEntry entry) put,
  required int Function() now,
}) {
  final plan = planWebViewHarvest(
    login: login,
    cookies: cookies,
    currentUrl: currentUrl,
  );
  harvestInto(plan, login.brokerView, put, schoolId: login.schoolId, now: now);
  return WebViewHarvestResult(entries: plan);
}
