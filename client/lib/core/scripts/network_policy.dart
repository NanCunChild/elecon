/// 🔒 ADR-034 §4: exact origin admission and optional connection IP/CIDR bounds.
/// A permitted origin grants a destination, not a content non-disclosure promise.
library;

import 'dart:io';

class ScriptNetworkException implements Exception {
  const ScriptNetworkException(this.code);

  final String code;

  @override
  String toString() => 'ScriptNetworkException($code)';
}

class ScriptNetworkPolicy {
  ScriptNetworkPolicy._(this.origins, this.ipAllow, this._ranges);

  factory ScriptNetworkPolicy.fromJson(Map<String, dynamic> json) {
    if (json.keys.any((key) => key != 'origins' && key != 'ipAllow')) {
      throw const FormatException('Unknown script network field');
    }
    final rawOrigins = json['origins'];
    if (rawOrigins is! List || rawOrigins.length > 128) {
      throw const FormatException('network.origins must be a bounded array');
    }
    final origins = <Uri>[];
    final keys = <String>{};
    for (final raw in rawOrigins) {
      if (raw is! String || raw.length > 2048) {
        throw const FormatException('Invalid network origin');
      }
      final uri = Uri.tryParse(raw);
      if (uri == null ||
          !_validUrl(uri) ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('Expected an exact HTTP(S) origin');
      }
      final origin = canonicalOrigin(uri);
      if (!keys.add(origin.origin)) {
        throw const FormatException('Duplicate network origin');
      }
      origins.add(origin);
    }
    List<String>? ipAllow;
    List<_IpRange>? ranges;
    if (json.containsKey('ipAllow')) {
      final values = json['ipAllow'];
      if (values is! List || values.length > 256) {
        throw const FormatException('network.ipAllow must be a bounded array');
      }
      ipAllow = <String>[];
      ranges = <_IpRange>[];
      for (final value in values) {
        if (value is! String || value.length > 80) {
          throw const FormatException('Invalid IP/CIDR allow entry');
        }
        ranges.add(_IpRange.parse(value));
        ipAllow.add(value);
      }
    }
    return ScriptNetworkPolicy._(
      List.unmodifiable(origins),
      ipAllow == null ? null : List.unmodifiable(ipAllow),
      ranges == null ? null : List.unmodifiable(ranges),
    );
  }

  final List<Uri> origins;

  /// null permits the admitted origin's DNS results; [] denies every address.
  final List<String>? ipAllow;
  final List<_IpRange>? _ranges;

  Map<String, Object?> toJson() => {
    'origins': origins.map((uri) => uri.origin).toList(),
    if (ipAllow != null) 'ipAllow': ipAllow,
  };

  bool allowsUrl(Uri uri) =>
      _validUrl(uri) &&
      origins.any((origin) => origin.origin == canonicalOrigin(uri).origin);

  void checkUrl(Uri uri) {
    if (!allowsUrl(uri)) {
      throw const ScriptNetworkException('origin_not_allowed');
    }
  }

  bool allowsAddress(InternetAddress address) =>
      (address.type == InternetAddressType.IPv4 ||
          address.type == InternetAddressType.IPv6) &&
      (_ranges == null || _ranges.any((range) => range.contains(address)));

  /// Normalizes equivalent IPv6 spellings as well as default ports.
  static Uri canonicalOrigin(Uri uri) {
    final address = InternetAddress.tryParse(uri.host);
    final host = address == null
        ? uri.host
        : InternetAddress.fromRawAddress(address.rawAddress).address;
    return Uri(
      scheme: uri.scheme,
      host: host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  static bool _validUrl(Uri uri) {
    if (!uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.authority.contains('%')) {
      return false;
    }
    final host = uri.host;
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      return address.type != InternetAddressType.IPv4 ||
          address.address == host;
    }
    // Reject platform-specific numeric host interpretations (127.1, octal,
    // integer and hex forms) rather than treating them as DNS labels.
    if (RegExp(r'^[0-9.]+$').hasMatch(host) ||
        RegExp(
          r'(^|\.)0x[0-9a-f]+($|\.)',
          caseSensitive: false,
        ).hasMatch(host)) {
      return false;
    }
    if (host.length > 253 || host.endsWith('.')) return false;
    final label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    return host.split('.').every(label.hasMatch);
  }
}

class _IpRange {
  _IpRange(this.address, this.prefix);

  factory _IpRange.parse(String input) {
    final parts = input.split('/');
    if (parts.length > 2 || input.trim() != input || input.contains('%')) {
      throw const FormatException('Invalid IP/CIDR entry');
    }
    final address = InternetAddress.tryParse(parts.first);
    if (address == null ||
        (address.type != InternetAddressType.IPv4 &&
            address.type != InternetAddressType.IPv6) ||
        (address.type == InternetAddressType.IPv4 &&
            address.address != parts.first) ||
        parts.first.contains('[')) {
      throw const FormatException('IP/CIDR entries require canonical IPs');
    }
    final bits = address.rawAddress.length * 8;
    var prefix = bits;
    if (parts.length == 2) {
      if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(parts.last)) {
        throw const FormatException('Invalid CIDR prefix');
      }
      prefix = int.tryParse(parts.last) ?? -1;
      if (prefix < 0 || prefix > bits) {
        throw const FormatException('CIDR prefix outside address width');
      }
    }
    return _IpRange(address, prefix);
  }

  final InternetAddress address;
  final int prefix;

  bool contains(InternetAddress other) {
    final bytes = address.rawAddress;
    final candidate = other.rawAddress;
    if (candidate.length != bytes.length) return false;
    final full = prefix ~/ 8;
    for (var i = 0; i < full; i++) {
      if (bytes[i] != candidate[i]) return false;
    }
    final remainder = prefix % 8;
    if (remainder == 0) return true;
    final mask = (0xff << (8 - remainder)) & 0xff;
    return (bytes[full] & mask) == (candidate[full] & mask);
  }
}
