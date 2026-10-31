/// ADR-043 §2: school-scoped, non-secret layout preferences in app storage.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'card_layout.dart';

class CardLayoutStore {
  CardLayoutStore({Directory? Function()? supportDirProvider})
    : _supportDirProvider = supportDirProvider;

  static final shared = CardLayoutStore();
  final Directory? Function()? _supportDirProvider;
  Future<void> _writes = Future.value();

  Future<File> _file(String scopeId) async {
    final dir =
        _supportDirProvider?.call() ?? await getApplicationSupportDirectory();
    // Scope is not a file path and never leaks into file names.
    final key = sha256.convert(utf8.encode(scopeId));
    return File('${dir.path}/home-layout/$key.json');
  }

  Future<HomeCardLayout> load(String scopeId) async {
    try {
      await _writes;
      final file = await _file(scopeId);
      if (!await file.exists() || await file.length() > 64 * 1024) {
        return HomeCardLayout();
      }
      return HomeCardLayout.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return HomeCardLayout();
    }
  }

  Future<void> save(String scopeId, HomeCardLayout layout) {
    final done = Completer<void>();
    // Serialize the entire read/replace lifecycle, including different schools.
    _writes = _writes.then((_) async {
      File? temporary;
      try {
        final file = await _file(scopeId);
        await file.parent.create(recursive: true);
        temporary = File('${file.path}.tmp');
        await temporary.writeAsString(jsonEncode(layout.toJson()), flush: true);
        await temporary.rename(file.path);
        done.complete();
      } catch (error, stack) {
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
        } catch (_) {
          // Preserve the original persistence error for the caller.
        }
        done.completeError(error, stack);
      }
    });
    return done.future;
  }
}
