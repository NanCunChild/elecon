import 'package:elecon/main.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/login/webview_login_page.dart';
import 'package:flutter/widgets.dart';

import '../test/support/school_fixture.dart';

void main() {
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
  runApp(
    EleconApp(
      sessionController: SessionController(initialSchools: [first, second]),
      loginRunner: (context, session, school) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        return const WebViewLoginResult(status: WebViewLoginStatus.cancelled);
      },
      loadHomeSnapshot: () async => throw StateError('脱敏测试故障'),
    ),
  );
}
