/// 外观偏好落盘：app 私有 support 目录下的 JSON（非凭证，明文可接受）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'theme_prefs.dart';

class ThemeStore {
  ThemeStore({Directory? Function()? supportDirProvider})
      : _supportDirProvider = supportDirProvider;

  final Directory? Function()? _supportDirProvider;

  static const _fileName = 'theme_prefs.json';

  Future<File> _file() async {
    final dir = _supportDirProvider?.call() ??
        await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<ThemePrefs> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return ThemePrefs.defaults;
      final text = await file.readAsString();
      final map = jsonDecode(text);
      if (map is! Map) return ThemePrefs.defaults;
      return ThemePrefs.fromJson(Map<String, Object?>.from(map));
    } catch (_) {
      return ThemePrefs.defaults;
    }
  }

  Future<void> save(ThemePrefs prefs) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(prefs.toJson()),
    );
  }
}
