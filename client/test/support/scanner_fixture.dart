import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';

ScriptPackage scannerPackage(
  String body, {
  int sdk = 8,
  bool? scanner = true,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': sdk,
      'id': 'scanner.synthetic',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic scanner',
      'network': {'origins': []},
      'browser': false,
      'scanner': ?scanner,
      'capabilities': [
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
    },
    'source': 'export const capabilities={"notice.list":async(ctx)=>{$body}};',
  }),
);
