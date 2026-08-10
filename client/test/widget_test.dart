import 'dart:async';

import 'package:elecon/core/trust/trust_profile.dart' show kSideloadEnabled;
import 'package:elecon/main.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/login/webview_login_page.dart';
import 'package:elecon/ui/security/dev_sideload_banner.dart'
    show DevSideloadStartupWarning, kDevSideloadWatermarkText;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/school_fixture.dart';

void main() {
  testWidgets(
    'startup waits for session bootstrap before showing school picker',
    (tester) async {
      final storageReady = Completer<void>();
      final session = SessionController(
        blobStoreProvider: () async {
          await storageReady.future;
          return null;
        },
        initialSchools: [testSchool()],
      );

      await tester.pumpWidget(EleconApp(sessionController: session));

      // ADR-024 §5.4：DEV 侧载产物的启动页就是不可关闭的水印页；DEPLOY 是普通 spinner。
      // 两档都断言，避免「水印只在某一档被验过」。
      if (kSideloadEnabled) {
        expect(find.byType(DevSideloadStartupWarning), findsOneWidget);
        expect(find.text(kDevSideloadWatermarkText), findsOneWidget);
      } else {
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          find.byType(DevSideloadStartupWarning),
          findsNothing,
          reason: 'DEPLOY 产物不得出现侧载水印（该分支应已被 tree-shake 剔除）',
        );
      }
      expect(find.text('选择学校'), findsNothing);

      storageReady.complete();
      // DEV 轮次的启动页有最小停留（devSideloadStartupDwell），pumpAndSettle 会等它走完。
      await tester.pumpAndSettle();

      expect(find.text('选择学校'), findsOneWidget);
      expect(find.text('测试大学'), findsOneWidget);
    },
  );

  testWidgets(
    'school selection and login continue into the real home error state',
    (tester) async {
      final first = testSchool(
        adapterId: 'school-test-a',
        schoolId: 'test-a',
        displayName: '测试甲大学',
      );
      final second = testSchool(
        adapterId: 'school-test-b',
        schoolId: 'test-b',
        displayName: '测试乙大学',
      );
      final session = SessionController(initialSchools: [first, second]);
      String? loginSchoolId;
      final loginResult = Completer<WebViewLoginResult?>();

      await tester.pumpWidget(
        EleconApp(
          sessionController: session,
          loginRunner: (context, currentSession, school) async {
            loginSchoolId = school.id;
            return loginResult.future;
          },
          loadHomeSnapshot: () async => throw StateError('脱敏测试故障'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('测试乙大学'));
      await tester.tap(find.text('登录并进入'));
      await tester.pump();

      expect(loginSchoolId, 'test-b');
      expect(find.text('登录中…'), findsOneWidget);
      expect(session.selectedSchool, isNull);

      loginResult.complete(
        const WebViewLoginResult(status: WebViewLoginStatus.cancelled),
      );
      await tester.pumpAndSettle();

      expect(session.selectedSchool?.id, 'test-b');
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.textContaining('脱敏测试故障'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('已取消登录'), findsOneWidget);
    },
  );
}
