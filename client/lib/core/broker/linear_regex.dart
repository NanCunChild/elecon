/// ADR-023 strict linear regex subset for adapter-controlled extraction patterns.
///
/// Parsing and matching never call Dart's native RegExp. The grammar excludes
/// alternation, assertions, backreferences, group quantifiers, lazy quantifiers,
/// and non-final variable quantifiers.
///
/// Security-sensitive broker path (ADR-023 section 5 decision 1). AI drafted;
/// requires human security review before merge (AGENTS.md section 1).
library;

const _maxPatternUnits = 256;
const _maxGroups = 32;
const _maxRepeat = 64;

class LinearRegexSyntaxException implements Exception {
  const LinearRegexSyntaxException(this.message);
  final String message;

  @override
  String toString() => 'LinearRegexSyntaxException: $message';
}

class LinearRegexMatch {
  const LinearRegexMatch(this.groups);

  /// Group zero is the whole match.
  final List<String> groups;
  int get groupCount => groups.length - 1;
  String? group(int index) =>
      index < 0 || index >= groups.length ? null : groups[index];
}

class LinearRegexPattern {
  const LinearRegexPattern._({
    required this.source,
    required this.anchoredStart,
    required this.anchoredEnd,
    required this.groupCount,
    required this.variableAtom,
    required List<_Atom> atoms,
    required List<_Capture> captures,
  }) : _atoms = atoms,
       _captures = captures;

  final String source;
  final bool anchoredStart;
  final bool anchoredEnd;
  final int groupCount;
  final int? variableAtom;
  final List<_Atom> _atoms;
  final List<_Capture> _captures;
}

LinearRegexPattern parseLinearRegex(String source) {
  if (source.length > _maxPatternUnits) {
    _fail('pattern exceeds $_maxPatternUnits UTF-16 code units');
  }
  _assertWellFormedUtf16(source);
  var i = 0;
  final anchoredStart = source.startsWith('^');
  if (anchoredStart) i++;
  final hasEndAnchor =
      source.endsWith(r'$') && !_isEscaped(source, source.length - 1);
  final end = hasEndAnchor ? source.length - 1 : source.length;
  final atoms = <_Atom>[];
  final captures = <_Capture>[];
  final stack = <_Capture>[];
  var groupCount = 0;
  int? variableAtom;

  while (i < end) {
    final c = source[i];
    if (c == '(') {
      if (i + 1 < end && source[i + 1] == '?') {
        _fail('special groups and lookaround are not supported');
      }
      groupCount++;
      if (groupCount > _maxGroups) {
        _fail('capture group count exceeds $_maxGroups');
      }
      final boundary = _Capture(groupCount, atoms.length);
      captures.add(boundary);
      stack.add(boundary);
      i++;
      continue;
    }
    if (c == ')') {
      if (stack.isEmpty) _fail("unmatched ')'");
      final boundary = stack.removeLast()..endAtom = atoms.length;
      if (boundary.startAtom == boundary.endAtom) {
        _fail('empty capture groups are not supported');
      }
      i++;
      if (i < end && _isQuantifierStart(source[i])) {
        _fail('group quantifiers are not supported');
      }
      continue;
    }
    final _ParsedAtom parsed;
    if (c == '[') {
      parsed = _parseClass(source, i, end);
    } else if (c == r'\') {
      parsed = _parseEscape(source, i, end);
    } else if (c == '.') {
      parsed = _ParsedAtom(_Atom.dot(), i + 1);
    } else {
      if ('|*+?{}[]^\$'.contains(c)) {
        _fail("unsupported or misplaced metacharacter '$c' at $i");
      }
      parsed = _ParsedAtom(_Atom.literal(source.codeUnitAt(i)), i + 1);
    }
    i = parsed.next;
    final quantifier = _parseQuantifier(source, i, end);
    i = quantifier.next;
    final atom = parsed.atom.withRepeat(quantifier.min, quantifier.max);
    atoms.add(atom);
    if (quantifier.max == null || quantifier.min != quantifier.max) {
      if (variableAtom != null) {
        _fail('only one variable quantifier is supported');
      }
      variableAtom = atoms.length - 1;
    }
  }

  if (stack.isNotEmpty) _fail('unclosed capture group');
  if (atoms.isEmpty) _fail('pattern must contain a consuming atom');
  if (variableAtom != null && variableAtom != atoms.length - 1) {
    // Narrow compatibility for `client_id:'(\w+)'`. ASCII \w cannot consume
    // either quote delimiter, so candidate scans cover disjoint word runs.
    final prefixDelimiter = variableAtom > 0 ? atoms[variableAtom - 1] : null;
    final suffix = atoms[variableAtom + 1];
    final variableEndsCapture = captures.any(
      (capture) => capture.endAtom == variableAtom! + 1,
    );
    final safeQuotedWord =
        variableAtom == atoms.length - 2 &&
        prefixDelimiter != null &&
        prefixDelimiter.kind == _AtomKind.literal &&
        prefixDelimiter.value == 39 &&
        prefixDelimiter.min == 1 &&
        prefixDelimiter.max == 1 &&
        atoms[variableAtom].setKind == _SetKind.word &&
        suffix.kind == _AtomKind.literal &&
        suffix.value == 39 &&
        suffix.min == 1 &&
        suffix.max == 1 &&
        variableEndsCapture;
    if (!safeQuotedWord) {
      _fail(
        'a variable quantifier is allowed only on the final consuming atom',
      );
    }
  }
  if (hasEndAnchor &&
      variableAtom != null &&
      !anchoredStart &&
      atoms[variableAtom].kind != _AtomKind.dot) {
    _fail(
      'an unanchored end-anchored variable quantifier is allowed only on dot',
    );
  }
  if (hasEndAnchor &&
      variableAtom != null &&
      !anchoredStart &&
      atoms[variableAtom].kind == _AtomKind.dot &&
      atoms.take(variableAtom).any((atom) => atom.canMatchLineTerminator)) {
    _fail(
      r'the fixed prefix before an unanchored .*$ must not match line terminators',
    );
  }
  return LinearRegexPattern._(
    source: source,
    anchoredStart: anchoredStart,
    anchoredEnd: hasEndAnchor,
    groupCount: groupCount,
    variableAtom: variableAtom,
    atoms: atoms,
    captures: captures,
  );
}

LinearRegexMatch? matchLinearRegex(LinearRegexPattern pattern, String input) {
  final matchEnd = pattern.anchoredEnd ? _endAnchorOffset(input) : input.length;
  final finalVariableDot =
      pattern.anchoredEnd &&
      !pattern.anchoredStart &&
      pattern.variableAtom != null &&
      pattern._atoms[pattern.variableAtom!].kind == _AtomKind.dot;
  // `prefix.*$` 只可能命中最终行；从最终行起扫，避免重复扫描前序后缀。
  final firstStart = finalVariableDot ? _finalLineStart(input, matchEnd) : 0;
  final lastStart = pattern.anchoredStart ? 0 : matchEnd;
  for (var start = firstStart; start <= lastStart; start++) {
    final starts = List<int>.filled(pattern.groupCount + 1, -1);
    final ends = List<int>.filled(pattern.groupCount + 1, -1);
    var pos = start;
    var failed = false;

    for (var atomIndex = 0; atomIndex < pattern._atoms.length; atomIndex++) {
      for (final capture in pattern._captures) {
        if (capture.startAtom == atomIndex) starts[capture.group] = pos;
      }
      final atom = pattern._atoms[atomIndex];
      var count = 0;
      var width = 0;
      while ((atom.max == null || count < atom.max!) &&
          pos < matchEnd &&
          (width = atom.matchWidth(input, pos)) > 0) {
        pos += width;
        count++;
      }
      if (count < atom.min) {
        failed = true;
        break;
      }
      for (final capture in pattern._captures) {
        if (capture.endAtom == atomIndex + 1) ends[capture.group] = pos;
      }
    }

    if (!failed && (!pattern.anchoredEnd || pos == matchEnd)) {
      starts[0] = start;
      ends[0] = pos;
      return LinearRegexMatch([
        for (var group = 0; group <= pattern.groupCount; group++)
          input.substring(starts[group], ends[group]),
      ]);
    }
    if (pattern.anchoredStart) break;
  }
  return null;
}

Never _fail(String message) => throw LinearRegexSyntaxException(message);

_ParsedAtom _parseEscape(String source, int i, int end) {
  if (i + 1 >= end) _fail('dangling escape');
  final escaped = source[i + 1];
  if ((escaped.codeUnitAt(0) >= 49 && escaped.codeUnitAt(0) <= 57) ||
      escaped == 'k') {
    _fail('backreferences are not supported');
  }
  final atom = switch (escaped) {
    'd' => _Atom.set(_SetKind.digit),
    'w' => _Atom.set(_SetKind.word),
    's' => _Atom.set(_SetKind.space),
    'n' => _Atom.literal(10),
    'r' => _Atom.literal(13),
    't' => _Atom.literal(9),
    _ when r'\.()[]{}+*?^$-/'.contains(escaped) => _Atom.literal(
      source.codeUnitAt(i + 1),
    ),
    _ => _fail('unsupported escape \\$escaped'),
  };
  return _ParsedAtom(atom, i + 2);
}

_ParsedAtom _parseClass(String source, int start, int end) {
  var i = start + 1;
  var negated = false;
  if (i < end && source[i] == '^') {
    negated = true;
    i++;
  }
  final ranges = <(int, int)>[];
  var hasItem = false;
  while (i < end && source[i] != ']') {
    final left = _parseClassLiteral(source, i, end);
    i = left.next;
    hasItem = true;
    if (i < end && source[i] == '-' && i + 1 < end && source[i + 1] != ']') {
      final right = _parseClassLiteral(source, i + 1, end);
      if (left.code > right.code) _fail('character class range is reversed');
      ranges.add((left.code, right.code));
      i = right.next;
    } else {
      ranges.add((left.code, left.code));
    }
  }
  if (!hasItem || i >= end || source[i] != ']') {
    _fail('unclosed or empty character class');
  }
  return _ParsedAtom(_Atom.charClass(negated, ranges), i + 1);
}

_ClassLiteral _parseClassLiteral(String source, int i, int end) {
  if (source[i] == r'\') {
    if (i + 1 >= end) _fail('dangling escape in character class');
    if ('dws'.contains(source[i + 1])) {
      _fail(
        'ASCII shorthand classes cannot be range endpoints or class members',
      );
    }
    final escaped = source[i + 1];
    final code = switch (escaped) {
      'n' => 10,
      'r' => 13,
      't' => 9,
      _ when r'\]-^/'.contains(escaped) => source.codeUnitAt(i + 1),
      _ => _fail('unsupported character class escape \\$escaped'),
    };
    return _ClassLiteral(code, i + 2);
  }
  final code = source.codeUnitAt(i);
  if (_isSurrogate(code)) {
    _fail('non-BMP characters are not supported inside character classes');
  }
  return _ClassLiteral(code, i + 1);
}

_Quantifier _parseQuantifier(String source, int i, int end) {
  if (i >= end) return _Quantifier(1, 1, i);
  final c = source[i];
  if (c == '?' || c == '*' || c == '+') {
    if (i + 1 < end && source[i + 1] == '?') {
      _fail('lazy quantifiers are not supported');
    }
    return switch (c) {
      '?' => _Quantifier(0, 1, i + 1),
      '*' => _Quantifier(0, null, i + 1),
      _ => _Quantifier(1, null, i + 1),
    };
  }
  if (c != '{') return _Quantifier(1, 1, i);
  final close = source.indexOf('}', i + 1);
  if (close < 0 || close >= end) _fail('invalid repeat quantifier');
  final body = source.substring(i + 1, close);
  final comma = body.indexOf(',');
  final int min;
  final int? max;
  if (comma < 0) {
    min = _parseRepeatNumber(body);
    max = min;
  } else {
    if (body.indexOf(',', comma + 1) >= 0) {
      _fail('invalid repeat quantifier');
    }
    min = _parseRepeatNumber(body.substring(0, comma));
    final maxText = body.substring(comma + 1);
    max = maxText.isEmpty ? null : _parseRepeatNumber(maxText);
    if (max != null && min > max) {
      _fail('repeat quantifier minimum exceeds maximum');
    }
  }
  if (close + 1 < end && source[close + 1] == '?') {
    _fail('lazy quantifiers are not supported');
  }
  return _Quantifier(min, max, close + 1);
}

int _parseRepeatNumber(String value) {
  if (value.isEmpty) _fail('invalid repeat quantifier');
  var number = 0;
  for (final code in value.codeUnits) {
    if (code < 48 || code > 57) _fail('invalid repeat quantifier');
    number = number * 10 + code - 48;
    if (number > _maxRepeat) _fail('repeat bound exceeds $_maxRepeat');
  }
  return number;
}

bool _isQuantifierStart(String c) =>
    c == '?' || c == '*' || c == '+' || c == '{';

bool _isEscaped(String source, int index) {
  var slashes = 0;
  for (var i = index - 1; i >= 0 && source[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

void _assertWellFormedUtf16(String value) {
  for (var i = 0; i < value.length; i++) {
    final code = value.codeUnitAt(i);
    if (_isHighSurrogate(code)) {
      if (i + 1 >= value.length || !_isLowSurrogate(value.codeUnitAt(i + 1))) {
        _fail('pattern contains an unpaired surrogate');
      }
      i++;
    } else if (_isLowSurrogate(code)) {
      _fail('pattern contains an unpaired surrogate');
    }
  }
}

bool _isSurrogate(int code) => code >= 0xd800 && code <= 0xdfff;
bool _isHighSurrogate(int code) => code >= 0xd800 && code <= 0xdbff;
bool _isLowSurrogate(int code) => code >= 0xdc00 && code <= 0xdfff;

int _endAnchorOffset(String value) {
  if (value.isEmpty) return 0;
  final last = value.codeUnitAt(value.length - 1);
  if (last == 10 &&
      value.length > 1 &&
      value.codeUnitAt(value.length - 2) == 13) {
    return value.length - 2;
  }
  return last == 10 || last == 13 || last == 0x2028 || last == 0x2029
      ? value.length - 1
      : value.length;
}

int _finalLineStart(String value, int end) {
  for (var i = end - 1; i >= 0; i--) {
    final code = value.codeUnitAt(i);
    if (code == 10 || code == 13 || code == 0x2028 || code == 0x2029) {
      return i + 1;
    }
  }
  return 0;
}

enum _AtomKind { literal, dot, set, charClass }

enum _SetKind { digit, word, space }

class _Atom {
  const _Atom._(
    this.kind, {
    this.value,
    this.setKind,
    this.negated = false,
    this.ranges = const [],
    this.min = 1,
    this.max = 1,
  });
  factory _Atom.literal(int value) => _Atom._(_AtomKind.literal, value: value);
  factory _Atom.dot() => const _Atom._(_AtomKind.dot);
  factory _Atom.set(_SetKind kind) => _Atom._(_AtomKind.set, setKind: kind);
  factory _Atom.charClass(bool negated, List<(int, int)> ranges) =>
      _Atom._(_AtomKind.charClass, negated: negated, ranges: ranges);

  final _AtomKind kind;
  final int? value;
  final _SetKind? setKind;
  final bool negated;
  final List<(int, int)> ranges;
  final int min;
  final int? max;

  _Atom withRepeat(int min, int? max) => _Atom._(
    kind,
    value: value,
    setKind: setKind,
    negated: negated,
    ranges: ranges,
    min: min,
    max: max,
  );

  int matchWidth(String input, int position) {
    final code = input.codeUnitAt(position);
    switch (kind) {
      case _AtomKind.literal:
        return code == value ? 1 : 0;
      case _AtomKind.dot:
        if (code == 10 || code == 13 || code == 0x2028 || code == 0x2029) {
          return 0;
        }
        if (_isHighSurrogate(code)) {
          return position + 1 < input.length &&
                  _isLowSurrogate(input.codeUnitAt(position + 1))
              ? 2
              : 0;
        }
        return _isLowSurrogate(code) ? 0 : 1;
      case _AtomKind.set:
        if (_isSurrogate(code)) return 0;
        return switch (setKind!) {
              _SetKind.digit => code >= 48 && code <= 57,
              _SetKind.word =>
                (code >= 48 && code <= 57) ||
                    (code >= 65 && code <= 90) ||
                    code == 95 ||
                    (code >= 97 && code <= 122),
              _SetKind.space => code == 32 || (code >= 9 && code <= 13),
            }
            ? 1
            : 0;
      case _AtomKind.charClass:
        if (_isSurrogate(code)) return 0;
        final included = ranges.any(
          (range) => code >= range.$1 && code <= range.$2,
        );
        return (negated ? !included : included) ? 1 : 0;
    }
  }

  bool get canMatchLineTerminator => const [
    10,
    13,
    0x2028,
    0x2029,
  ].any((code) => matchWidth(String.fromCharCode(code), 0) > 0);
}

class _Capture {
  _Capture(this.group, this.startAtom);
  final int group;
  final int startAtom;
  int endAtom = -1;
}

class _ParsedAtom {
  const _ParsedAtom(this.atom, this.next);
  final _Atom atom;
  final int next;
}

class _ClassLiteral {
  const _ClassLiteral(this.code, this.next);
  final int code;
  final int next;
}

class _Quantifier {
  const _Quantifier(this.min, this.max, this.next);
  final int min;
  final int? max;
  final int next;
}
