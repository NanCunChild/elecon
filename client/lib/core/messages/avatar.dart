import 'dart:convert';
import 'dart:typed_data';

/// ADR-098: inline raster bytes only. Native UI never loads a remote URL.
Uint8List? conversationAvatarBytes(String value) {
  if (value.length > 21871) return null;
  final match = RegExp(
    r'^data:image/(png|jpeg);base64,([A-Za-z0-9+/]+={0,2})$',
  ).firstMatch(value);
  if (match == null) return null;
  try {
    final bytes = base64Decode(match[2]!);
    if (bytes.isEmpty || bytes.length > 16384) return null;
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    final png =
        bytes.length >= 8 &&
        List.generate(8, (i) => bytes[i] == signature[i]).every((v) => v);
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    return (match[1] == 'png' && png) || (match[1] == 'jpeg' && jpeg)
        ? bytes
        : null;
  } on FormatException {
    return null;
  }
}
