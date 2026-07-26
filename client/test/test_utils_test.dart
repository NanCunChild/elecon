import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  test('外部 adapter 可选缺失时返回 null，CI 必需模式 fail-closed', () {
    const missing = 'school-definitely-missing';
    expect(schoolAdapterDir(missing, requireAdapters: false), isNull);
    expect(
      () => schoolAdapterDir(missing, requireAdapters: true),
      throwsA(isA<FileSystemException>()),
    );
  });
}
