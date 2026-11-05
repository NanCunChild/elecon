import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/community/community_pages.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package(
  String id,
  List<String> capabilities, {
  String school = 'synthetic',
  String? source,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 9,
      'id': id,
      'version': '1.0.0',
      'schoolId': school,
      'name': 'Synthetic service',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        for (final cap in capabilities)
          {
            'id': cap,
            'schema': 'elecon.$cap',
            'schemaVersion': cap == 'notice.list' ? '1.1' : '1.0',
          },
      ],
    },
    'source':
        source ??
        "export const capabilities={'forum.session':async()=>({serviceId:'synthetic',serviceName:'Synthetic',status:'signedOut'}),'messages.list':async()=>{throw new Error('should be manually invoked')}};",
  }),
);
Future<void> install(SessionController session, ScriptPackage p) =>
    session.installTrustedScript(p, approvedDigest: p.digest);

Future<void> pumpSources(WidgetTester tester) async {
  await tester.pumpAndSettle();
  // Installed registry futures are created in runAsync; flush their real-zone
  // completion before asserting the next FutureBuilder frame.
  await tester.runAsync(() async {});
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'leaving a busy forum preserves the school execution generation',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final service = package(
        'forum',
        ['forum.session'],
        source: '''export const capabilities={'forum.session':async()=>{
        await new Promise(resolve=>setTimeout(resolve,10000));
        return {serviceId:'synthetic',serviceName:'Synthetic',status:'signedOut'};
      }};''',
      );
      await tester.runAsync(() async {
        await install(session, service);
        await session.selectTrustedScriptSchool('forum');
      });
      final generation = session.trustedScriptViewGeneration;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ForumPage(session: session, package: service),
        ),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(session.trustedScriptViewGeneration, generation);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'no packages means only home/settings at 320px, 2x text, $language $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = SessionController();
          addTearDown(session.dispose);
          final theme = ThemeController();
          addTearDown(theme.dispose);
          var loads = 0;
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
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(2),
                      // Title scrolling has dedicated tests; keep navigation
                      // assertions independent of its repeating animation.
                      disableAnimations: true,
                    ),
                    child: child!,
                  ),
                  home: MainShell(
                    loadHomeSnapshot: () async {
                      loads++;
                      return CampusSnapshot(
                        schoolName: 'Synthetic',
                        updatedAt: null,
                        notices: const NoticeList(items: []),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await pumpSources(tester);
          expect(find.byIcon(Icons.forum_outlined), findsNothing);
          expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
          await tester.tap(find.byIcon(Icons.settings_outlined));
          await pumpSources(tester);
          final l10n = AppLocalizations.of(
            tester.element(find.byType(MainShell)),
          );
          expect(
            find.widgetWithText(AppBar, l10n.settingsTitle),
            findsOneWidget,
          );
          await tester.tap(find.byIcon(Icons.home_outlined));
          await pumpSources(tester);
          expect(loads, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'tabs follow enabled providers of current school and preserve Settings identity',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController();
      addTearDown(session.dispose);
      final theme = ThemeController();
      addTearDown(theme.dispose);
      await tester.runAsync(() async {
        await session.bootstrap();
        await install(session, package('base', ['notice.list']));
        await session.selectTrustedScriptSchool('base');
        await install(
          session,
          package('other-forum', ['forum.session'], school: 'other'),
        );
      });
      await tester.pumpWidget(
        ThemeScope(
          controller: theme,
          child: SessionScope(
            controller: session,
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: MainShell(
                loadHomeSnapshot: () async => CampusSnapshot(
                  schoolName: 'Synthetic',
                  updatedAt: null,
                  notices: const NoticeList(items: []),
                ),
              ),
            ),
          ),
        ),
      );
      await pumpSources(tester);
      expect(find.byIcon(Icons.forum_outlined), findsNothing);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await pumpSources(tester);
      await tester.runAsync(() async {
        await install(session, package('forum', ['forum.session']));
        await install(session, package('messages', ['messages.list']));
      });
      await pumpSources(tester);
      expect(session.selectedSchool?.id, 'synthetic');
      final registry = await tester.runAsync(() => session.scriptRegistry);
      expect(registry!.provider('synthetic', 'forum.session'), isNotNull);
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await pumpSources(tester);
      // Script pages use the template icon in both states. The selected
      // semantics and opened page establish which tab is active.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Messages' &&
              widget.properties.selected == true,
        ),
        findsOneWidget,
      );
      // No account handler in this provider: do not borrow one from another package.
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(MessagesPage), findsOneWidget);
      final pageElement = tester.element(find.byType(MessagesPage));
      final generation = session.trustedScriptViewGeneration;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Paused Flutter does not render frames. Cancellation is immediate; the
      // first resumed frame must create a fresh page, not reuse private data.
      expect(session.trustedScriptViewGeneration, greaterThan(generation));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpSources(tester);
      expect(find.byType(MessagesPage), findsOneWidget);
      expect(pageElement.mounted, isFalse);
      expect(
        tester.element(find.byType(MessagesPage)),
        isNot(same(pageElement)),
      );
      await tester.runAsync(
        () => session.enableTrustedScript('messages', false),
      );
      await pumpSources(tester);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      expect(find.byIcon(Icons.home), findsOneWidget);
      await tester.runAsync(() => session.enableTrustedScript('forum', false));
      await pumpSources(tester);
      expect(find.byIcon(Icons.forum_outlined), findsNothing);
      await tester.runAsync(
        () => session.selectTrustedScriptSchool('other-forum'),
      );
      await pumpSources(tester);
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
