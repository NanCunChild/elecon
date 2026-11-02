import 'package:elecon/core/transport/app_tunnel.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/settings/app_tunnel_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/profile_fixture.dart';

class UnavailableHermes implements AppTunnelProvider {
  @override
  String get id => 'hermes-atrust';
  @override
  String get name => 'Hermes / aTrust';
  @override
  bool get isAvailable => false;
  @override
  Future<AppTunnelConnection> open({required String schoolId}) =>
      throw StateError('synthetic native unavailable');
}

void main() {
  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'APPTunnel explicit choice and unavailable state at 320px / 2x / $language / $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = SessionController(
            appTunnelProviders: [UnavailableHermes()],
          );
          addTearDown(session.dispose);
          final package = school();
          await session.installTrustedScript(
            package,
            approvedDigest: package.digest,
          );
          await session.selectTrustedScriptSchool(package.manifest.id);
          await tester.pumpWidget(
            SessionScope(
              controller: session,
              child: MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: ThemeData(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const AppTunnelPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = AppLocalizations.of(
            tester.element(find.byType(AppTunnelPage)),
          );
          expect(find.text(l10n.appTunnelDirect), findsOneWidget);
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Hermes / aTrust').last);
          await tester.pumpAndSettle();
          expect(await session.appTunnelChoice(), 'hermes-atrust');
          expect(find.text(l10n.appTunnelUnavailable), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text(l10n.appTunnelLogin),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          final button = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, l10n.appTunnelLogin),
          );
          expect(button.onPressed, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
