import 'dart:async';
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/main.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/login/login_flow.dart';
import 'package:elecon/ui/login/webview_login_page.dart';
import 'package:elecon/ui/security/protected_store_recovery_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/protected_store_fixture.dart';
import 'support/school_fixture.dart';

class _ProfileReadDelay implements BlobStore {
  _ProfileReadDelay(this.inner);
  final BlobStore inner;
  bool delay = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Uint8List?> read(String name) async {
    if (delay &&
        name.startsWith('profiles/') &&
        name.endsWith('/store.dek.wrapped')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return inner.read(name);
  }

  @override
  Future<void> write(String name, List<int> bytes) => inner.write(name, bytes);
  @override
  Future<void> delete(String name) => inner.delete(name);
}

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(() async {});
  }
  fail('Protected recovery UI did not finish');
}

void main() {
  for (final locale in ['zh', 'en', 'fa', 'ru', 'uz']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'recovery can retry at 320px and 2x text: $locale $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final hardware = RecoverableHardware();
          final blobs = (await tester.runAsync(
            () => seedProtectedStore(hardware),
          ))!;
          hardware.unavailable = true;
          final session = protectedSession(blobs, hardware);
          addTearDown(session.dispose);
          await tester.runAsync(session.bootstrap);
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: ProtectedStoreRecoveryPage(session: session),
            ),
          );
          final l10n = AppLocalizations.of(
            tester.element(find.byType(ProtectedStoreRecoveryPage)),
          );
          expect(find.text(l10n.protectedStoreRecoveryTitle), findsOneWidget);
          final retry = find.byKey(const ValueKey('protected-store-retry'));
          await tester.ensureVisible(retry);
          await tester.tap(retry);
          await until(
            tester,
            () => find
                .text(l10n.protectedStoreRecoveryFailed)
                .evaluate()
                .isNotEmpty,
          );
          expect(session.hardwareUnlockFailed, isTrue);
          hardware.unavailable = false;
          hardware.release = Completer<void>();
          await tester.ensureVisible(retry);
          await tester.tap(retry);
          await tester.pump();
          expect(tester.widget<FilledButton>(retry).onPressed, isNull);
          expect(
            find.text(l10n.protectedStoreRecoveryRetrying),
            findsOneWidget,
          );
          hardware.release!.complete();
          await until(tester, () => !session.hardwareUnlockFailed);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'app remains behind the recovery gate until the original store opens',
    (tester) async {
      final hardware = RecoverableHardware();
      final blobs = (await tester.runAsync(
        () => seedProtectedStore(hardware),
      ))!;
      hardware.unavailable = true;
      final session = protectedSession(blobs, hardware);
      await tester.runAsync(session.bootstrap);
      var loads = 0;
      await tester.pumpWidget(
        EleconApp(
          sessionController: session,
          loadHomeSnapshot: () async {
            loads++;
            return CampusSnapshot(
              schoolName: 'Synthetic',
              updatedAt: null,
              notices: const NoticeList(items: []),
            );
          },
        ),
      );
      await until(
        tester,
        () => find.byType(ProtectedStoreRecoveryPage).evaluate().isNotEmpty,
      );
      expect(find.byType(MainShell), findsNothing);
      expect(loads, 0);
      final login = await runSchoolLogin(
        tester.element(find.byType(ProtectedStoreRecoveryPage)),
        session,
        testSchool(),
      );
      expect(login!.status, WebViewLoginStatus.error);
      expect(find.byType(WebViewLoginPage), findsNothing);
      // The recovery gate consumes Back without revealing another page.
      expect(await tester.binding.handlePopRoute(), isTrue);
      expect(find.byType(ProtectedStoreRecoveryPage), findsOneWidget);
      hardware.unavailable = false;
      await tester.tap(find.byKey(const ValueKey('protected-store-retry')));
      await until(tester, () => find.byType(MainShell).evaluate().isNotEmpty);
      await until(tester, () => loads == 1);
      expect(find.byType(ProtectedStoreRecoveryPage), findsNothing);
      expect(session.credentialRefs, ['synthetic-session']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final retryBeforeSwitch in [true, false]) {
    testWidgets(
      'existing Profile switch revokes recovery; retry before switch: $retryBeforeSwitch',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final hardware = RecoverableHardware();
        final backing = (await tester.runAsync(
          () => seedProtectedStore(hardware),
        ))!;
        final blobs = _ProfileReadDelay(backing);
        ProfileController profiles() => ProfileController(
          blobStoreProvider: () async => blobs,
          createSession: (scope) => protectedSession(scope ?? blobs, hardware),
        );
        final setup = profiles();
        late String healthyId;
        await tester.runAsync(() async {
          await setup.bootstrap();
          await setup.add();
          healthyId = setup.active.id;
          hardware.unavailable = true;
          await setup.active.session.ensurePersistentStore(
            confirmSoftwareFallback: () async => true,
          );
          setup.active.session.selectSchool(testSchool());
          await setup.active.session.flush();
          await setup.activate('default');
          setup.dispose();
        });
        final controller = profiles();
        await tester.runAsync(controller.bootstrap);
        final locked = controller.active.session;
        await tester.pumpWidget(
          EleconApp(
            profileController: controller,
            loadHomeSnapshot: () async => CampusSnapshot(
              schoolName: 'Synthetic',
              updatedAt: null,
              notices: const NoticeList(items: []),
            ),
          ),
        );
        await until(
          tester,
          () => find.byType(ProtectedStoreRecoveryPage).evaluate().isNotEmpty,
        );
        hardware.unavailable = false;
        hardware.release = Completer<void>();
        hardware.entered = Completer<void>();
        final retry = find.byKey(const ValueKey('protected-store-retry'));
        final oldRetryCallback = tester.widget<FilledButton>(retry).onPressed!;
        if (retryBeforeSwitch) {
          await tester.ensureVisible(retry);
          await tester.tap(retry);
          await until(tester, () => hardware.entered!.isCompleted);
        } else {
          blobs.delay = true;
        }
        final switchProfile = find.byKey(
          ValueKey('protected-store-profile:$healthyId'),
        );
        await tester.ensureVisible(switchProfile);
        await tester.tap(switchProfile);
        Future<bool>? directRetry;
        if (!retryBeforeSwitch) {
          await until(tester, () => blobs.entered.isCompleted);
          expect(controller.busy, isTrue);
          expect(locked.isRetryingProtectedStore, isFalse);
          expect(tester.widget<FilledButton>(retry).onPressed, isNull);
          final unwraps = hardware.unwraps;
          // A callback from the previous rendered frame also checks Profile busy.
          oldRetryCallback();
          await tester.pump();
          expect(hardware.unwraps, unwraps);
          expect(locked.isRetryingProtectedStore, isFalse);
          // The controller's final cancellation also catches a core caller that
          // starts new work after activation's initial cancellation.
          directRetry = locked.retryProtectedStore();
          await until(tester, () => hardware.entered!.isCompleted);
          blobs.release.complete();
        }
        await until(tester, () => controller.active.id == healthyId);
        hardware.release!.complete();
        await until(tester, () => !locked.isRetryingProtectedStore);
        if (directRetry != null) expect(await directRetry, isFalse);
        await until(tester, () => find.byType(MainShell).evaluate().isNotEmpty);
        expect(locked.hardwareUnlockFailed, isTrue);
        expect(locked.credentialMetadata, isEmpty);
        expect(find.byType(ProtectedStoreRecoveryPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
