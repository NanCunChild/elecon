/// ADR-073: immutable, digest-authorized HTML pages. No remote/file resources.
library;

import 'dart:convert';

class ScriptWebContent {
  const ScriptWebContent._(this.id, this.title, this.html);

  factory ScriptWebContent.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        !raw.keys.toSet().containsAll({'id', 'title', 'html'})) {
      throw const FormatException('invalid web content declaration');
    }
    final id = raw['id'];
    final title = raw['title'];
    final html = raw['html'];
    if (id is! String ||
        !RegExp(r'^[a-z][a-z0-9._-]{0,63}$').hasMatch(id) ||
        id.contains('\n') ||
        title is! String ||
        title.trim().isEmpty ||
        title.runes.length > 80 ||
        RegExp(
          r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
        ).hasMatch(title) ||
        html is! String ||
        html.isEmpty ||
        utf8.encode(html).length > 256 * 1024 ||
        html.contains('\u0000') ||
        _hasUnpairedSurrogate(html) ||
        _hasUnpairedSurrogate(title)) {
      throw const FormatException('invalid web content declaration');
    }
    return ScriptWebContent._(id, title, html);
  }

  final String id;
  final String title;
  final String html;

  static List<ScriptWebContent> parseList(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > 8) {
      throw const FormatException('webContent must contain 1–8 pages');
    }
    final pages = raw.map(ScriptWebContent.fromJson).toList(growable: false);
    if (pages.map((page) => page.id).toSet().length != pages.length ||
        pages.fold<int>(0, (sum, page) => sum + utf8.encode(page.html).length) >
            512 * 1024) {
      throw const FormatException('duplicate or oversized webContent');
    }
    return List.unmodifiable(pages);
  }
}

bool _hasUnpairedSurrogate(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) return true;
      final next = value.codeUnitAt(i);
      if (next < 0xdc00 || next > 0xdfff) return true;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return true;
    }
  }
  return false;
}
