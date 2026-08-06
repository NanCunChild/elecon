/// 运行时日志环缓冲（Settings 可查看）—— client 唯一观测 sink。
///
/// 策略（红线 #1；跨端约定见 `docs/reference/cross_end_logging.md`）：
///  - **network**：任意 build 可记；仅记录无参 URL + 成败/状态码，永不记
///    header / body / cookie 值。
///  - **runtime / webview / adapter**：仅 [kDebugMode] 写入；release 丢弃。
///  - 凭证脱敏不可关闭；所有类别在进入内存、控制台或 UI 前统一净化。
///
/// 🔒 观测面贴近凭证路径：AI 起草，须人工复核脱敏边界。
library;

import 'package:flutter/foundation.dart';

/// 日志类别。
enum DevLogCategory {
  /// 出站 HTTP（transport）；release 唯一可见类别。
  network,

  /// 会话 / 存储 / 收割元数据 / loader 等（仅 debug）。
  runtime,

  /// WebView / 登录流程等（仅 debug）。
  webview,

  /// adapter `ctx.log` 桥接（仅 debug）。
  adapter,
}

/// 单条日志。
class DevLogEntry {
  const DevLogEntry({
    required this.time,
    required this.category,
    required this.message,
    this.ok,
    this.statusCode,
  });

  final DateTime time;
  final DevLogCategory category;
  final String message;

  /// network：请求是否成功完成（HTTP 层拿到响应为 true；抛错为 false）。
  final bool? ok;
  final int? statusCode;

  String get timeLabel {
    final t = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }
}

/// 环缓冲 sink；单例 [DevLog.instance]。
///
/// 生产路径（transport / session / login）应写入本 sink；UI 只订阅展示。
class DevLog extends ChangeNotifier {
  DevLog({this.capacity = 500});

  static final DevLog instance = DevLog();

  final int capacity;
  final List<DevLogEntry> _entries = <DevLogEntry>[];

  /// 凭证脱敏是永久边界，不能由 build mode 或 UI 关闭（红线 #1）。
  bool get redact => true;

  /// 兼容既有调用；凭证脱敏不可关闭。
  void setRedact(bool value) {}

  /// 新→旧。
  List<DevLogEntry> get entries => List<DevLogEntry>.unmodifiable(_entries);

  /// release 仅 network；debug 可全量。
  List<DevLogEntry> visible({DevLogCategory? only}) {
    Iterable<DevLogEntry> it = _entries;
    if (!kDebugMode) {
      it = it.where((e) => e.category == DevLogCategory.network);
    }
    if (only != null) {
      it = it.where((e) => e.category == only);
    }
    return List<DevLogEntry>.unmodifiable(it);
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// 通用写入。非 network 在 release 直接丢弃。
  void log(
    DevLogCategory category,
    String message, {
    bool? ok,
    int? statusCode,
  }) {
    if (category != DevLogCategory.network && !kDebugMode) return;
    final safeMessage = sanitizeLogMessage(message);
    final entry = DevLogEntry(
      time: DateTime.now(),
      category: category,
      message: safeMessage,
      ok: ok,
      statusCode: statusCode,
    );
    _entries.insert(0, entry);
    while (_entries.length > capacity) {
      _entries.removeLast();
    }
    if (kDebugMode) {
      debugPrint('[dev-log/${category.name}] $safeMessage');
    }
    notifyListeners();
  }

  void runtime(String message) => log(DevLogCategory.runtime, message);

  void webview(String message) => log(DevLogCategory.webview, message);

  /// adapter `ctx.log` / 诊断摘要的默认桥接。
  void adapter(String level, String message) {
    final lvl = level.trim().isEmpty ? 'info' : level.trim();
    log(DevLogCategory.adapter, '[$lvl] $message');
  }

  /// 网络请求：method + URL（受 [redact]）+ 可选 status / 错误摘要（不含 body）。
  void network({
    required String method,
    required String url,
    int? statusCode,
    bool? ok,
    String? error,
  }) {
    final safe = formatUrlForLog(url);
    final m = method.toUpperCase();
    final String msg;
    if (error != null && error.isNotEmpty) {
      msg = '$m $safe → fail (${_shortError(error)})';
    } else if (statusCode != null) {
      msg = '$m $safe → $statusCode';
    } else {
      msg = '$m $safe';
    }
    log(
      DevLogCategory.network,
      msg,
      ok: ok ?? (error == null),
      statusCode: statusCode,
    );
  }
}

/// 按脱敏策略格式化 URL。
///
/// userInfo、query、fragment 与路径会话参数永久移除（红线 #1、ADR-027）。
/// [redact] 仅为源兼容保留，不能放宽凭证边界。
String formatUrlForLog(String raw, {bool redact = true}) {
  final u = Uri.tryParse(raw.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) {
    return '<invalid-url>';
  }
  final port = u.hasPort ? ':${u.port}' : '';
  var path = u.path.replaceAll(
    RegExp(
      r';(?:jsessionid|phpsessid|asp\.net_sessionid|sessionid|sid)=[^/;]*',
      caseSensitive: false,
    ),
    '',
  );
  path = path.replaceAllMapped(
    RegExp(
      r'/(ticket|token|access_token|refresh_token|id_token)/[^/]*',
      caseSensitive: false,
    ),
    (m) => '/${m.group(1)}/<redacted>',
  );
  path = path.replaceAll(
    RegExp(r'/(?:ST|TGT|PT|PGT|PGTIOU)-\d+-[A-Za-z0-9._-]+'),
    '/<redacted>',
  );
  final base = '${u.scheme}://${u.host}$port$path';
  return base;
}

/// 兼容旧名：始终脱敏（无参 URL）。新代码优先 [formatUrlForLog]。
String sanitizeUrlForLog(String raw) => formatUrlForLog(raw, redact: true);

/// cookie / secret 值永久使用固定占位符，避免原文和长度泄漏。
String maskCookieValue(Object? value, {bool redact = true}) {
  return '<redacted>';
}

/// 净化 URL、认证 header、已知票据和敏感键赋值。
///
/// 无字段名或协议结构的任意裸秘密无法可靠识别，调用方仍不得记录原始响应或凭证值。
String sanitizeLogMessage(String message) {
  var out = message.replaceAllMapped(
    RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false),
    (m) => formatUrlForLog(m.group(0)!),
  );
  out = out.replaceAllMapped(
    RegExp(
      r'\b(cookie|set-cookie|authorization|proxy-authorization)\s*[:=]\s*[^\r\n]*',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}: <redacted>',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'''["']?\b([a-z0-9_-]*(?:session|credential|secret|(?:api|access|auth|client|private|signing)[_-]?key|password|passwd|passphrase|access[_-]?token|refresh[_-]?token|id[_-]?token|oauth[_-]?token|token|ticket|openid|samlresponse|samlart|tgc)[a-z0-9_-]*)["']?\s*[=:]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;)\]}]+)''',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}=<redacted>',
  );
  out = out.replaceAll(
    RegExp(r'\b(?:ST|TGT|PT|PGT|PGTIOU)-\d+-[A-Za-z0-9._-]+'),
    '<redacted>',
  );
  return out;
}

String _shortError(String error) {
  final one = sanitizeLogMessage(error).split('\n').first.trim();
  if (one.length <= 80) return one;
  return '${one.substring(0, 77)}...';
}
