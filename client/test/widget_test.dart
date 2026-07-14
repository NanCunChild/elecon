// 占位 smoke：默认 counter 模板已不适用（入口为 EleconApp，非 MyApp）。
// 全量 UI 需平台通道 / path_provider，见 session 与 core 单测；此处只保 flutter test 可跑。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MaterialApp smoke', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('elecon'))),
    );
    expect(find.text('elecon'), findsOneWidget);
  });
}
