import 'package:elecon/main.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/profile_fixture.dart';

void main() {
  testWidgets(
    'settings shows every Profile; adding reselects script and can return to an existing account',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final profiles = ProfileController(
        createSession: (_) => SessionController(),
      );
      await tester.runAsync(() async {
        await profiles.bootstrap();
        final s = profiles.active.session;
        final p = school();
        await s.installTrustedScript(p, approvedDigest: p.digest);
        await s.selectTrustedScriptSchool(p.manifest.id);
        expect(
          (await s.runCapability(
            'notice.list',
            params: {'value': 'SYNTHETIC_USER'},
          )).ok,
          isTrue,
        );
      });
      await tester.pumpWidget(
        EleconApp(
          profileController: profiles,
          loadHomeSnapshot: () async => CampusSnapshot(
            schoolName: 'Synthetic login',
            updatedAt: DateTime(2026),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      // Default locale in the test environment is English.
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Profile 1'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
      expect(find.textContaining('SYNTHETIC_USER'), findsNothing);
      await tester.tap(find.text('Profile 1'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Add Profile'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(profiles.profiles, hasLength(2));
      expect(profiles.active.session.isConfigured, isFalse);
      expect(find.text('Profile 2'), findsOneWidget);
      await tester.tap(find.text('Profile 2'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Profile 1'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(profiles.active.id, 'default');
      expect(profiles.active.session.isLoggedIn, isTrue);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Profile 1'), findsOneWidget);
      expect(find.text('Profile 2'), findsOneWidget);
      await tester.tap(find.text('Profile 2'));
      await tester.pumpAndSettle();
      expect(find.text('Switch to this Profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
