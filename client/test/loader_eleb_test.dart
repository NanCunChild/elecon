import 'dart:convert';
import 'dart:typed_data';

import 'package:elecon/core/loader/eleb.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a stored ELeB and computes its content digest', () {
    final zip = _zip({
      'manifest.json': _manifest(),
      'payload/source/main.js': utf8.encode('export default 1;'),
    });
    final parsed = parseEleb(zip);
    expect(parsed.manifest['manifestVersion'], '2.0');
    expect(
      parsed.entries.map((e) => e.path),
      containsAll(['manifest.json', 'payload/source/main.js']),
    );
    expect(
      parsed.contentDigest,
      '84146b78959444d819ab10dc8ff4c9b4d07208171f13f8ae24a41e560836cb3c',
    );
  });

  test('rejects traversal and duplicate paths', () {
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': _manifest(),
          'payload/source/../x.js': [1],
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': _manifest(),
          'payload/source/main.js': [1],
        }, duplicate: true),
      ),
      throwsFormatException,
    );
  });

  test('rejects bad CRC and central/local mismatch', () {
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': _manifest(),
          'payload/source/main.js': [1],
        }, badCrc: true),
      ),
      throwsFormatException,
    );
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': _manifest(),
          'payload/source/main.js': [1],
        }, wrongLocalMethod: true),
      ),
      throwsFormatException,
    );
  });

  test('rejects unsupported methods and flags', () {
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': _manifest(),
          'payload/source/main.js': [1],
        }, method: 12),
      ),
      throwsFormatException,
    );
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': _manifest(),
          'payload/source/main.js': [1],
        }, dataDescriptor: true),
      ),
      throwsFormatException,
    );
  });

  test('rejects malformed JSON', () {
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': utf8.encode(
            '{"manifestVersion":"2.0","manifestVersion":"2.0"}',
          ),
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => parseEleb(
        _zip({
          'manifest.json': [0xef, 0xbb, 0xbf, 0x7b, 0x7d],
        }),
      ),
      throwsFormatException,
    );
  });
}

List<int> _manifest() => utf8.encode(
  jsonEncode({
    'manifestVersion': '2.0',
    'adapterId': 'edu.example.adapter',
    'adapterVersion': '1.0.0',
    'minimumAppVersion': '1.0.0',
    'payload': {'kind': 'source', 'entry': 'payload/source/main.js'},
    'capabilities': <Object?>[],
    'files': [
      {'path': 'manifest.json', 'role': 'manifest', 'encoding': 'jcs'},
      {'path': 'payload/source/main.js', 'role': 'source', 'encoding': 'utf8'},
    ],
  }),
);

Uint8List _zip(
  Map<String, List<int>> input, {
  bool duplicate = false,
  bool badCrc = false,
  bool wrongLocalMethod = false,
  bool dataDescriptor = false,
  int method = 0,
}) {
  final locals = <int>[], centrals = <int>[];
  var offset = 0;
  final source = <MapEntry<String, List<int>>>[...input.entries];
  if (duplicate) source.add(source.last);
  for (final entry in source) {
    final name = utf8.encode(entry.key), data = entry.value, crc = _crc(data);
    final localMethod = wrongLocalMethod ? 8 : method;
    final local = _bytes(30 + name.length + data.length);
    _w32(local, 0, 0x04034b50);
    _w16(local, 4, 20);
    _w16(local, 6, 0x800 | (dataDescriptor ? 8 : 0));
    _w16(local, 8, localMethod);
    _w32(local, 14, badCrc ? crc ^ 1 : crc);
    _w32(local, 18, data.length);
    _w32(local, 22, data.length);
    _w16(local, 26, name.length);
    local.setRange(30, 30 + name.length, name);
    local.setRange(30 + name.length, local.length, data);
    locals.addAll(local);
    final central = _bytes(46 + name.length);
    _w32(central, 0, 0x02014b50);
    _w16(central, 4, 20);
    _w16(central, 6, 20);
    _w16(central, 8, 0x800 | (dataDescriptor ? 8 : 0));
    _w16(central, 10, method);
    _w32(central, 16, badCrc ? crc ^ 1 : crc);
    _w32(central, 20, data.length);
    _w32(central, 24, data.length);
    _w16(central, 28, name.length);
    _w32(central, 38, 0x81a40000);
    _w32(central, 42, offset);
    central.setRange(46, central.length, name);
    centrals.addAll(central);
    offset += local.length;
  }
  final end = _bytes(22);
  _w32(end, 0, 0x06054b50);
  _w16(end, 8, source.length);
  _w16(end, 10, source.length);
  _w32(end, 12, centrals.length);
  _w32(end, 16, locals.length);
  return Uint8List.fromList([...locals, ...centrals, ...end]);
}

List<int> _bytes(int n) => List<int>.filled(n, 0);
void _w16(List<int> b, int p, int v) {
  b[p] = v & 255;
  b[p + 1] = v >> 8 & 255;
}

void _w32(List<int> b, int p, int v) {
  for (var i = 0; i < 4; i++) b[p + i] = v >> (8 * i) & 255;
}

int _crc(List<int> data) {
  var c = 0xffffffff;
  for (final x in data) {
    c ^= x;
    for (var i = 0; i < 8; i++) c = c >> 1 ^ ((c & 1) == 1 ? 0xedb88320 : 0);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}
