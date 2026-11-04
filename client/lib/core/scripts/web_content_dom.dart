/// Fixed host DOM operations for inert package HTML (ADR-073).
/// No caller string is interpreted as JavaScript or a native method name.
library;

import 'dart:convert';
import 'browser.dart' show ScriptBrowserException;

class ScriptContentOperation {
  const ScriptContentOperation(this.arguments, this.timeout);
  final Map<String, Object?> arguments;
  final Duration timeout;

  factory ScriptContentOperation.parse(Map<String, Object?> args) {
    final operation = args['operation'];
    final selector = args['selector'];
    const operations = {
      'setText',
      'setHtml',
      'setValue',
      'setAttribute',
      'setDisabled',
      'getText',
      'getValue',
      'exists',
      'queryAll',
      'waitForEvent',
    };
    if (!operations.contains(operation) ||
        selector is! String ||
        selector.isEmpty ||
        selector.length > 1024) {
      throw const ScriptBrowserException('browser_content_invalid_operation');
    }
    final keys = {'operation', 'selector'};
    if (const {
      'setText',
      'setHtml',
      'setValue',
      'setAttribute',
    }.contains(operation)) {
      keys.add('value');
      final value = args['value'];
      if (value is! String || utf8.encode(value).length > 65536) {
        throw const ScriptBrowserException('browser_content_invalid_operation');
      }
    }
    if (operation == 'setAttribute') {
      keys.add('attribute');
      final attribute = args['attribute'];
      if (attribute is! String ||
          !RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(attribute) ||
          attribute.startsWith('on') ||
          attribute.contains('\n')) {
        throw const ScriptBrowserException('browser_content_invalid_operation');
      }
    }
    if (operation == 'setDisabled') {
      keys.add('value');
      if (args['value'] is! bool) {
        throw const ScriptBrowserException('browser_content_invalid_operation');
      }
    }
    var timeout = const Duration(seconds: 30);
    if (operation == 'queryAll') {
      keys.add('limit');
      final limit = args['limit'];
      if (args.containsKey('limit') &&
          (limit is! int || limit < 1 || limit > 100)) {
        throw const ScriptBrowserException('browser_content_invalid_operation');
      }
    }
    if (operation == 'waitForEvent') {
      keys.addAll({'event', 'timeoutMs'});
      final milliseconds = args.containsKey('timeoutMs')
          ? args['timeoutMs']
          : 60000;
      if (!const {'click', 'submit', 'change'}.contains(args['event']) ||
          milliseconds is! int ||
          milliseconds < 1 ||
          milliseconds > 90000) {
        throw const ScriptBrowserException('browser_content_invalid_operation');
      }
      timeout = Duration(milliseconds: milliseconds + 2000);
    }
    if (args.keys.any((key) => !keys.contains(key))) {
      throw const ScriptBrowserException('browser_content_invalid_operation');
    }
    return ScriptContentOperation(Map.unmodifiable(args), timeout);
  }

  /// Direct native injection, deliberately without eval/Function. Content is
  /// encoded as a JSON string and parsed; even hostile HTML/selector text is data.
  String get source =>
      '''
(() => {
  const args = JSON.parse(${jsonEncode(jsonEncode(arguments))});
  const node = document.querySelector(args.selector);
  if (args.operation === 'exists') return node !== null;
  if (args.operation === 'queryAll') {
    return Array.from(document.querySelectorAll(args.selector)).slice(0,args.limit || 100)
      .map(e => ({tag:e.tagName.toLowerCase(),text:(e.textContent || '').slice(0,4096)}));
  }
  if (!node) throw new Error('missing_element');
  switch(args.operation) {
    case 'setText': node.textContent = args.value; return null;
    case 'setHtml': node.innerHTML = args.value; return null;
    case 'setValue':
      if (!('value' in node)) throw new Error('invalid_element');
      node.value = args.value; return null;
    case 'setAttribute': node.setAttribute(args.attribute,args.value); return null;
    case 'setDisabled':
      if (!('disabled' in node)) throw new Error('invalid_element');
      node.disabled = args.value; return null;
    case 'getText': return (node.textContent || '').slice(0,65536);
    case 'getValue':
      if (!('value' in node)) throw new Error('invalid_element');
      return String(node.value).slice(0,65536);
    case 'waitForEvent': return new Promise(resolve => {
      const event = args.event;
      const done = result => {
        clearTimeout(timer);
        node.removeEventListener(event, listener, true);
        resolve(result);
      };
      const listener = e => {
        if (!e.isTrusted) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (event !== 'change' && 'disabled' in node) node.disabled = true;
        done(true);
      };
      const timer = setTimeout(() => done(false),args.timeoutMs || 60000);
      node.addEventListener(event, listener, true);
    });
  }
  throw new Error('invalid_operation');
})()
''';
}
