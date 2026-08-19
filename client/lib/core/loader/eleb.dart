import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart' show DartSha256;

const int elebMaxPackedBytes = 64 * 1024 * 1024;
const int elebMaxUnpackedBytes = 256 * 1024 * 1024;
const int elebMaxEntryBytes = 128 * 1024 * 1024;
const int elebMaxEntries = 256;
const int elebMaxCompressionRatio = 20;

class ElebEntry {
  const ElebEntry({
    required this.path,
    required this.data,
    required this.method,
    required this.packedSize,
  });
  final String path;
  final Uint8List data;
  final int method;
  final int packedSize;
}

class ElebSignature {
  const ElebSignature({
    required this.signatureFormat,
    required this.algorithm,
    required this.digestAlgorithm,
    required this.contentDigest,
    required this.publicKey,
    required this.signerFingerprint,
    required this.signature,
    this.keyId,
  });
  final String signatureFormat,
      algorithm,
      digestAlgorithm,
      contentDigest,
      publicKey,
      signerFingerprint,
      signature;
  final String? keyId;
}

class ParsedEleb {
  const ParsedEleb({
    required this.entries,
    required this.manifest,
    required this.contentDigest,
    this.signature,
  });
  final List<ElebEntry> entries;
  final Map<String, Object?> manifest;
  final String contentDigest;
  final ElebSignature? signature;
}

bool looksLikeEleb(Uint8List bytes) =>
    (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) ||
    (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        bytes[2] == 0x05 &&
        bytes[3] == 0x06);

ParsedEleb parseEleb(Uint8List zip) {
  final entries = _parseZip(zip);
  final manifestEntry = entries.where((e) => e.path == 'manifest.json');
  if (manifestEntry.length != 1)
    throw const FormatException('manifest.json missing');
  final manifest = _asManifest(
    _parseJson(manifestEntry.single.data, manifest: true),
  );
  final declared = <String, Map<String, Object?>>{};
  final files = manifest['files'] as List<Object?>;
  for (final raw in files) {
    if (raw is! Map<String, Object?> ||
        raw['path'] is! String ||
        raw['role'] is! String ||
        raw['encoding'] is! String) {
      throw const FormatException('manifest files closure invalid');
    }
    final path = raw['path']! as String;
    if (declared.containsKey(path))
      throw const FormatException('manifest files closure invalid');
    _pathBytes(path);
    declared[path] = raw;
  }
  if (!declared.containsKey('manifest.json'))
    throw const FormatException('manifest files closure invalid');
  for (final e in entries) {
    if (e.path == 'META-INF/signature.json') continue;
    final actual = _role(e.path), expected = declared[e.path];
    final encoding = actual == 'manifest'
        ? 'jcs'
        : actual == 'source'
        ? 'utf8'
        : 'binary';
    if (expected == null ||
        expected['role'] != actual ||
        expected['encoding'] != encoding) {
      throw const FormatException('manifest files closure invalid');
    }
  }
  if (declared.keys.any(
    (path) =>
        path != 'META-INF/signature.json' &&
        !entries.any((entry) => entry.path == path),
  )) {
    throw const FormatException('manifest files closure invalid');
  }
  final payload = manifest['payload']! as Map<String, Object?>;
  if (payload['kind'] == 'source') {
    final entry = payload['entry'];
    if (entry is! String ||
        !entries.any((e) => e.path == entry) ||
        !entry.startsWith('payload/source/') ||
        entries.any((e) => e.path.startsWith('payload/bytecode/')))
      throw const FormatException('source entry missing');
  } else {
    final variants = payload['variants']! as Map<String, Object?>;
    if (entries.any((e) => e.path.startsWith('payload/source/')) ||
        variants.values.any(
          (v) => v is! String || !entries.any((e) => e.path == v),
        )) {
      throw const FormatException('bytecode variants invalid');
    }
  }
  final sigEntry = entries.where((e) => e.path == 'META-INF/signature.json');
  final signature = sigEntry.isEmpty
      ? null
      : _asSignature(_parseJson(sigEntry.single.data));
  final digest = _contentDigest(entries, manifest);
  if (signature != null && signature.contentDigest != digest)
    throw const FormatException('content digest mismatch');
  return ParsedEleb(
    entries: entries,
    manifest: manifest,
    contentDigest: digest,
    signature: signature,
  );
}

List<ElebEntry> _parseZip(Uint8List z) {
  if (z.length > elebMaxPackedBytes)
    throw const FormatException('packed ZIP exceeds limit');
  final eocd = _lastSignature(z, 0x06054b50);
  if (eocd < 0 || eocd + 22 > z.length)
    throw const FormatException('missing EOCD');
  if (_hasSignature(z, 0x06064b50) || _hasSignature(z, 0x07064b50))
    throw const FormatException('Zip64 forbidden');
  final comment = _u16(z, eocd + 20),
      count = _u16(z, eocd + 10),
      cdSize = _u32(z, eocd + 12),
      cd = _u32(z, eocd + 16);
  if (comment != 0 ||
      eocd + 22 != z.length ||
      count > elebMaxEntries ||
      _u16(z, eocd + 8) != count ||
      cd + cdSize != eocd) {
    throw const FormatException('invalid central directory');
  }
  var p = cd, total = 0, packedTotal = 0;
  final names = <String>{}, ranges = <({int start, int end})>[];
  final out = <ElebEntry>[];
  for (var i = 0; i < count; i++) {
    if (p + 46 > eocd || _u32(z, p) != 0x02014b50)
      throw const FormatException('invalid central entry');
    final flags = _u16(z, p + 8),
        method = _u16(z, p + 10),
        crc = _u32(z, p + 16),
        ps = _u32(z, p + 20),
        us = _u32(z, p + 24);
    final nl = _u16(z, p + 28),
        el = _u16(z, p + 30),
        cl = _u16(z, p + 32),
        lo = _u32(z, p + 42);
    if (flags & 9 != 0 ||
        flags & 8 != 0 ||
        flags & 0x800 == 0 ||
        (method != 0 && method != 8) ||
        el != 0 ||
        cl != 0 ||
        us > elebMaxEntryBytes ||
        lo + 30 > cd ||
        lo + 30 + nl + ps > cd ||
        lo + 30 + nl > z.length ||
        !_regularFile(z, p))
      throw const FormatException('forbidden ZIP fields');
    final name = _decodeUtf8(z.sublist(p + 46, p + 46 + nl));
    if (!_pathBytes(name).isNotEmpty || !names.add(name))
      throw const FormatException('duplicate path');
    if (_u32(z, lo) != 0x04034b50 ||
        _u16(z, lo + 6) != flags ||
        _u16(z, lo + 8) != method ||
        _u32(z, lo + 14) != crc ||
        _u32(z, lo + 18) != ps ||
        _u32(z, lo + 22) != us ||
        _u16(z, lo + 26) != nl ||
        _u16(z, lo + 28) != 0 ||
        _decodeUtf8(z.sublist(lo + 30, lo + 30 + nl)) != name)
      throw const FormatException('local-central mismatch or overlap');
    final start = lo, end = lo + 30 + nl + ps;
    if (ranges.any((r) => start < r.end && r.start < end))
      throw const FormatException('local-central mismatch or overlap');
    ranges.add((start: start, end: end));
    final raw = Uint8List.sublistView(z, lo + 30 + nl, end);
    Uint8List data;
    try {
      data = method == 0
          ? Uint8List.fromList(raw)
          : Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
    } catch (_) {
      throw const FormatException('invalid compressed data');
    }
    if (data.length != us || _crc32(data) != crc)
      throw const FormatException('CRC mismatch');
    total += us;
    packedTotal += ps;
    if (total > elebMaxUnpackedBytes ||
        total > elebMaxCompressionRatio * (packedTotal == 0 ? 1 : packedTotal))
      throw const FormatException('ZIP unpacked/ratio limit');
    out.add(ElebEntry(path: name, data: data, method: method, packedSize: ps));
    p += 46 + nl + el + cl;
  }
  if (p != eocd) throw const FormatException('central directory size mismatch');
  return out;
}

int _u16(Uint8List b, int p) => b[p] | b[p + 1] << 8;
int _u32(Uint8List b, int p) =>
    b[p] | b[p + 1] << 8 | b[p + 2] << 16 | b[p + 3] << 24;
int _lastSignature(Uint8List b, int n) {
  for (var i = b.length - 22; i >= 0; i--) if (_u32(b, i) == n) return i;
  return -1;
}

bool _hasSignature(Uint8List b, int n) {
  for (var i = 0; i + 4 <= b.length; i++) if (_u32(b, i) == n) return true;
  return false;
}

bool _regularFile(Uint8List b, int p) {
  final madeBy = _u16(b, p + 4) >> 8;
  final attrs = _u32(b, p + 38);
  if (madeBy == 3) {
    final type = (attrs >> 16) & 0xf000;
    return type == 0 || type == 0x8000;
  }
  // DOS directory and volume-label bits are not regular files.
  return attrs & 0x10 == 0 && attrs & 0x08 == 0;
}

Uint8List _pathBytes(String path) {
  final b = Uint8List.fromList(utf8.encode(path));
  if (b.length > 256 ||
      path.isEmpty ||
      path.contains('\\') ||
      path.contains('\u0000') ||
      path.startsWith('/') ||
      path.split('/').any((x) => x.isEmpty || x == '.' || x == '..'))
    throw const FormatException('invalid ELeB path');
  if (_decodeUtf8(b) != path) throw const FormatException('invalid UTF-8 path');
  return b;
}

String _decodeUtf8(List<int> b) =>
    const Utf8Decoder(allowMalformed: false).convert(b);

int _crc32(List<int> data) {
  var c = 0xffffffff;
  for (final x in data) {
    c ^= x;
    for (var i = 0; i < 8; i++) c = (c >> 1) ^ ((c & 1) == 1 ? 0xedb88320 : 0);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

Object? _parseJson(Uint8List bytes, {bool manifest = false}) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf)
    throw const FormatException('JSON BOM');
  final s = _decodeUtf8(bytes);
  return _JsonReader(s, manifest).parse();
}

class _JsonReader {
  _JsonReader(this.s, this.manifest);
  final String s;
  final bool manifest;
  var i = 0;
  Object? parse() {
    final v = _value();
    _ws();
    if (i != s.length) throw const FormatException('trailing JSON');
    return v;
  }

  void _ws() {
    while (i < s.length && ' \t\r\n'.contains(s[i])) i++;
  }

  Object? _value() {
    _ws();
    if (i >= s.length) throw const FormatException('invalid JSON');
    final c = s[i];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == '"') return _string();
    for (final x in ['true', 'false', 'null']) {
      if (s.startsWith(x, i)) {
        i += x.length;
        return x == 'null' ? null : x == 'true';
      }
    }
    final m = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+|[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(s, i);
    if (m == null) throw const FormatException('invalid JSON');
    final text = m.group(0)!;
    i += text.length;
    if (manifest &&
        (text.contains('.') || text.contains('e') || text.contains('E')))
      throw const FormatException('manifest floating point forbidden');
    final n = int.tryParse(text);
    if (n == null || n.abs() > 9007199254740991) {
      throw const FormatException('unsafe JSON number');
    }
    return n;
  }

  String _string() {
    final start = i++;
    while (i < s.length) {
      final c = s[i++];
      if (c == '\\') {
        if (i >= s.length) throw const FormatException('unterminated string');
        i++;
      } else if (c == '"') {
        final value = jsonDecode(s.substring(start, i)) as String;
        for (var j = 0; j < value.length; j++) {
          final u = value.codeUnitAt(j);
          if (u >= 0xd800 &&
              u <= 0xdfff &&
              !(u <= 0xdbff &&
                  j + 1 < value.length &&
                  value.codeUnitAt(j + 1) >= 0xdc00 &&
                  value.codeUnitAt(j + 1) <= 0xdfff))
            throw const FormatException('lone surrogate');
        }
        return value;
      } else if (c.codeUnitAt(0) < 0x20)
        throw const FormatException('invalid JSON string');
    }
    throw const FormatException('unterminated string');
  }

  List<Object?> _array() {
    i++;
    final a = <Object?>[];
    _ws();
    if (i < s.length && s[i] == ']') {
      i++;
      return a;
    }
    while (true) {
      a.add(_value());
      _ws();
      if (i < s.length && s[i] == ']') {
        i++;
        return a;
      }
      if (i >= s.length || s[i++] != ',')
        throw const FormatException('invalid array');
    }
  }

  Map<String, Object?> _object() {
    i++;
    final o = <String, Object?>{};
    final keys = <String>{};
    _ws();
    if (i < s.length && s[i] == '}') {
      i++;
      return o;
    }
    while (true) {
      _ws();
      if (i >= s.length || s[i] != '"')
        throw const FormatException('invalid key');
      final k = _string();
      if (!keys.add(k)) throw const FormatException('duplicate JSON key');
      _ws();
      if (i >= s.length || s[i++] != ':')
        throw const FormatException('invalid object');
      o[k] = _value();
      _ws();
      if (i < s.length && s[i] == '}') {
        i++;
        return o;
      }
      if (i >= s.length || s[i++] != ',')
        throw const FormatException('invalid object');
    }
  }
}

String _canon(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) return v.toString();
  if (v is String) return jsonEncode(v);
  if (v is List) return '[${v.map(_canon).join(',')}]';
  final m = v as Map<String, Object?>;
  final keys = m.keys.toList()..sort();
  return '{${keys.map((k) => '${jsonEncode(k)}:${_canon(m[k])}').join(',')}}';
}

Uint8List _canonicalBytes(Object? v) =>
    Uint8List.fromList(utf8.encode(_canon(v)));

Map<String, Object?> _asManifest(Object? v) {
  if (v is! Map<String, Object?> ||
      v['manifestVersion'] != '2.0' ||
      v['adapterId'] is! String ||
      !RegExp(
        r'^[a-z0-9]+(?:[.-][a-z0-9]+)*(?:\.[a-z0-9]+(?:[.-][a-z0-9]+)*)+$',
      ).hasMatch(v['adapterId']! as String) ||
      v['adapterVersion'] is! String ||
      v['minimumAppVersion'] is! String ||
      v['capabilities'] is! List ||
      v['files'] is! List ||
      v['payload'] is! Map<String, Object?>)
    throw const FormatException('invalid manifest');
  final p = v['payload']! as Map<String, Object?>;
  if (p['kind'] == 'source' && p['entry'] is String) return v;
  if (p['kind'] == 'bytecode-only' &&
      p['variants'] is Map<String, Object?> &&
      (p['variants']! as Map<String, Object?>).values.every((x) => x is String))
    return v;
  throw const FormatException('invalid payload');
}

String _role(String path) {
  if (path == 'manifest.json') return 'manifest';
  if (path == 'META-INF/signature.json') return 'signature';
  if (path.startsWith('payload/source/')) return 'source';
  if (path.startsWith('payload/bytecode/') && path.endsWith('.qbc'))
    return 'bytecode';
  if (path.startsWith('resources/')) return 'resource';
  throw const FormatException('unknown ELeB path');
}

String _contentDigest(List<ElebEntry> entries, Map<String, Object?> manifest) {
  final xs = entries.where((e) => e.path != 'META-INF/signature.json').map((e) {
    final role = _role(e.path);
    return (
      path: _pathBytes(e.path),
      role: role,
      data: e.path == 'manifest.json' ? _canonicalBytes(manifest) : e.data,
    );
  }).toList()..sort((a, b) => _compareBytes(a.path, b.path));
  final input = BytesBuilder()
    ..add(utf8.encode('elecon-eleb-content\u0000v1\u0000'));
  for (final x in xs) {
    final n = ByteData(4)..setUint32(0, x.path.length, Endian.big);
    input.add(n.buffer.asUint8List());
    input.add(x.path);
    input.add([
      {'manifest': 1, 'source': 2, 'bytecode': 3, 'resource': 4}[x.role]!,
    ]);
    input.add([
      x.role == 'manifest'
          ? 1
          : x.role == 'source'
          ? 2
          : 3,
    ]);
    final l = ByteData(8)..setUint64(0, x.data.length, Endian.big);
    input.add(l.buffer.asUint8List());
    input.add(x.data);
  }
  return _hex(const DartSha256().hashSync(input.takeBytes()).bytes);
}

int _compareBytes(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

ElebSignature _asSignature(Object? v) {
  if (v is! Map<String, Object?> ||
      v['signatureFormat'] != 'elecon-eleb-signature/1' ||
      v['algorithm'] != 'ed25519' ||
      v['digestAlgorithm'] != 'sha256-v1' ||
      v['contentDigest'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(v['contentDigest']! as String) ||
      v['publicKey'] is! String ||
      v['signerFingerprint'] is! String ||
      v['signature'] is! String)
    throw const FormatException('invalid signature');
  final pk = base64Decode(v['publicKey']! as String),
      sig = base64Decode(v['signature']! as String);
  if (pk.length != 32 ||
      sig.length != 64 ||
      _hex(const DartSha256().hashSync(pk).bytes) != v['signerFingerprint'])
    throw const FormatException('invalid signature');
  return ElebSignature(
    signatureFormat: v['signatureFormat']! as String,
    algorithm: v['algorithm']! as String,
    digestAlgorithm: v['digestAlgorithm']! as String,
    contentDigest: v['contentDigest']! as String,
    publicKey: v['publicKey']! as String,
    signerFingerprint: v['signerFingerprint']! as String,
    signature: v['signature']! as String,
    keyId: v['keyId'] as String?,
  );
}
