import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingSession extends SessionController {
  final calls = <String>[];

  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) async {
    calls.add(capability);
    return const CapabilityRun.ok({'items': []});
  }
}

void main() {
  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'reserved community tabs remain local at 320px / 2x text in $language / $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = _RecordingSession();
          addTearDown(session.dispose);
          final theme = ThemeController();
          addTearDown(theme.dispose);
          var snapshotLoads = 0;
          await tester.pumpWidget(
            ThemeScope(
              controller: theme,
              child: SessionScope(
                controller: session,
                child: MaterialApp(
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  theme: ThemeData(brightness: brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(2)),
                    child: child!,
                  ),
                  home: MainShell(
                    loadHomeSnapshot: () async {
                      snapshotLoads++;
                      return CampusSnapshot(
                        schoolName: 'Synthetic school',
                        updatedAt: null,
                        notices: const NoticeList(items: []),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = AppLocalizations.of(
            tester.element(find.byType(MainShell)),
          );
          expect(find.text(l10n.navHome), findsOneWidget);
          expect(find.text(l10n.navForum), findsOneWidget);
          expect(find.text(l10n.navMessages), findsOneWidget);
          expect(find.text(l10n.navSettings), findsOneWidget);

          await tester.tap(find.byIcon(Icons.forum_outlined));
          await tester.pumpAndSettle();
          expect(find.text(l10n.forumPlannedTitle), findsOneWidget);
          expect(find.text(l10n.forumPlannedAccount), findsOneWidget);
          expect(find.text(l10n.communityPlannedAvailability), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(find.byType(FilledButton), findsNothing);
          expect(tester.takeException(), isNull);

          await tester.tap(find.byIcon(Icons.chat_bubble_outline));
          await tester.pumpAndSettle();
          expect(find.text(l10n.messagesPlannedTitle), findsOneWidget);
          expect(find.text(l10n.messagesPlannedAccount), findsOneWidget);
          expect(find.text(l10n.forumPlannedTitle), findsNothing);
          expect(find.byType(Badge), findsNothing);
          expect(tester.takeException(), isNull);

          await tester.tap(find.byIcon(Icons.settings_outlined));
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(AppBar, l10n.settingsTitle),
            findsOneWidget,
          );
          await tester.tap(find.byIcon(Icons.home_outlined));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('home-title')), findsOneWidget);
          expect(snapshotLoads, 1);
          expect(session.calls, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
