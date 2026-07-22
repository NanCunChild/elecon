/// 宿主侧 `elecon:html` stdlib 源码加载（ADR-011 / ADR-018）。
///
/// 与 `adapters/_stdlib/html.bundle.js` 同内容；随 app 资产打包，**不**随 adapter 分发。
/// adapter `import "elecon:html"` 时由 runtime moduleHandler 注入本源码。
library;

import 'package:flutter/services.dart' show rootBundle;

/// asset 路径（须在 `pubspec.yaml` flutter.assets 声明）。
const String kHtmlStdlibAsset = 'assets/stdlib/html.bundle.js';

String? _cached;

/// 读入并缓存 stdlib 源码；资产缺失时返回 null（fail-closed 由 runtime 拒 import）。
Future<String?> loadHtmlStdlib() async {
  final hit = _cached;
  if (hit != null) return hit;
  try {
    final src = await rootBundle.loadString(kHtmlStdlibAsset);
    _cached = src;
    return src;
  } catch (_) {
    return null;
  }
}

/// 测试用：清空缓存。
void clearHtmlStdlibCacheForTest() {
  _cached = null;
}
