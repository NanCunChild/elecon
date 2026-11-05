import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/community/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<void> finishRequests(WidgetTester tester) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('synthetic chat request did not complete');
}

void main() {
  testWidgets(
    'message time uses local calendar days and full accessible time',
    (tester) async {
      final now = DateTime(2026, 11, 5, 14);
      final sameDay = DateTime(2026, 11, 5, 13, 5).toUtc().toIso8601String();
      final previousDay = DateTime(
        2026,
        11,
        4,
        23,
        55,
      ).toUtc().toIso8601String();
      final previousYear = DateTime(
        2025,
        11,
        4,
        23,
        55,
      ).toUtc().toIso8601String();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                ConversationTimestamp(value: sameDay, now: now),
                ConversationTimestamp(value: previousDay, now: now),
                ConversationTimestamp(value: previousYear, now: now),
                ConversationTimestamp(value: 'unknown', now: now),
              ],
            ),
          ),
        ),
      );
      expect(find.text('1:05 PM'), findsOneWidget);
      expect(find.text('11/4'), findsOneWidget);
      expect(find.text('11/4/2025'), findsOneWidget);
      expect(find.text('unknown'), findsNothing);
      expect(find.byTooltip('Latest message: 11/5/2026 13:05'), findsOneWidget);
    },
  );

  for (final language in ['en', 'fa']) {
    testWidgets('long inbox names and dates fit 320px / 2x / $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController();
      addTearDown(session.dispose);
      final package = chatPackage(
        conversationRows: [
          {
            'conversationId': 'synthetic-long-group-identity-1234567890',
            'conversationKind': 'group',
            'title': 'A long synthetic group title that needs multiple lines',
            'hasContent': true,
            'lastMessageAt': '2025-11-05T08:00:00Z',
          },
          {
            'conversationId': 'unknown',
            'conversationKind': 'group',
            'title': 'Synthetic unknown time',
          },
        ],
      );
      await tester.runAsync(() => prepareChat(session, package));
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(brightness: Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ChatPage(session: session, package: package),
        ),
      );
      await finishRequests(tester);
      expect(find.byType(ConversationTimestamp), findsOneWidget);
      expect(
        find.text('synthetic-long-group-identity-1234567890'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'chat history, local pages and unknown sending at 320px / 2x / $language / $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = SessionController();
          addTearDown(session.dispose);
          final package = chatPackage(sendStatus: 'unknown');
          await tester.runAsync(() => prepareChat(session, package));
          await tester.pumpWidget(
            MaterialApp(
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
              home: ChatPage(session: session, package: package),
            ),
          );
          await finishRequests(tester);
          expect(find.text('Synthetic group'), findsOneWidget);
          expect(find.text('Synthetic peer'), findsOneWidget);
          await tester.tap(find.text('Synthetic group'));
          await tester.pump();
          await finishRequests(tester);
          expect(
            find.widgetWithText(SelectableText, 'Synthetic homework summary'),
            findsOneWidget,
          );
          final l10n = AppLocalizations.of(
            tester.element(find.byType(ChatPage)),
          );
          await tester.ensureVisible(find.text(l10n.messagesMoreHistory));
          await tester.tap(find.text(l10n.messagesMoreHistory));
          await tester.pump();
          await finishRequests(tester);
          expect(
            find.widgetWithText(SelectableText, 'Synthetic older message'),
            findsOneWidget,
          );
          // Business content has no InkWell/button/navigation action.
          final body = find.widgetWithText(
            SelectableText,
            'Synthetic homework summary',
          );
          expect(
            find.ancestor(of: body, matching: find.byType(InkWell)),
            findsNothing,
          );
          await tester.enterText(find.byType(TextField), 'Synthetic outgoing');
          await tester.pump();
          await tester.tap(find.byTooltip(l10n.messagesSend));
          await tester.pump();
          await finishRequests(tester);
          expect(find.text(l10n.messagesSendUnknown), findsOneWidget);
          expect(
            find.widgetWithText(SelectableText, 'Synthetic outgoing'),
            findsOneWidget,
          );
          if (language == 'zh' && brightness == Brightness.light) {
            await tester.enterText(
              find.byType(TextField),
              'Synthetic second outgoing',
            );
            await tester.pump();
            await tester.tap(find.byTooltip(l10n.messagesSend));
            await tester.pump();
            await finishRequests(tester);
            expect(find.text(l10n.messagesSendUnknown), findsNWidgets(2));
            expect(
              find.widgetWithText(SelectableText, 'Synthetic outgoing'),
              findsOneWidget,
            );
            expect(
              find.widgetWithText(SelectableText, 'Synthetic second outgoing'),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
          final generation = session.trustedScriptViewGeneration;
          await tester.pumpWidget(const SizedBox.shrink());
          expect(session.trustedScriptViewGeneration, generation);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'inbox prefers confirmed content, merges saved messages and keeps the same order offline',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = chatPackage(
        offlineAfterSend: true,
        sendStatus: 'unknown',
        conversationRows: [
          {
            'conversationId': 'unknown',
            'conversationKind': 'group',
            'title': 'Unknown group',
          },
          {
            'conversationId': 'older',
            'conversationKind': 'group',
            'title': 'Older group',
            'hasContent': true,
            'lastMessageAt': '2026-10-30T08:00:00Z',
          },
          {
            'conversationId': 'group-1',
            'conversationKind': 'group',
            'title': 'Local content group',
          },
          {
            'conversationId': 'recent',
            'conversationKind': 'group',
            'title': 'Recent group',
            'hasContent': true,
            'lastMessageAt': '2026-11-02T08:00:00Z',
          },
        ],
      );
      await tester.runAsync(() async {
        await prepareChat(session, package);
        await session.runTrustedScript(
          package.manifest.id,
          'messages.conversations',
          params: {'accountId': 'synthetic-account'},
        );
        await session.runTrustedScript(
          package.manifest.id,
          'messages.history',
          params: chatTarget,
        );
        await session.runTrustedScript(
          package.manifest.id,
          'messages.send',
          params: {
            ...chatTarget,
            'clientId': '123',
            'text': 'Synthetic outgoing',
          },
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatPage(session: session, package: package),
        ),
      );
      await finishRequests(tester);
      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data)
          .toList();
      expect(titles, [
        'Recent group',
        'Local content group',
        'Older group',
        'Unknown group',
      ]);
      final timestamps = tester
          .widgetList<ConversationTimestamp>(find.byType(ConversationTimestamp))
          .map((time) => time.value)
          .toList();
      expect(timestamps, [
        '2026-11-02T08:00:00Z',
        '2026-11-01T08:00:00.000Z',
        '2026-10-30T08:00:00Z',
      ]);
      final unknown = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Unknown group'),
      );
      expect(unknown.trailing, isNull);
      expect(find.textContaining(' · unknown'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'offline reopening keeps the saved source/account and historical text',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = chatPackage(
        sendStatus: 'unknown',
        offlineAfterSend: true,
      );
      await tester.runAsync(() async {
        await prepareChat(session, package);
        await session.runTrustedScript(
          package.manifest.id,
          'messages.conversations',
          params: {'accountId': 'synthetic-account'},
        );
        await session.runTrustedScript(
          package.manifest.id,
          'messages.history',
          params: chatTarget,
        );
        await session.runTrustedScript(
          package.manifest.id,
          'messages.send',
          params: {
            ...chatTarget,
            'clientId': '123',
            'text': 'Synthetic outgoing',
          },
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatPage(session: session, package: package),
        ),
      );
      await finishRequests(tester);
      final l10n = AppLocalizations.of(tester.element(find.byType(ChatPage)));
      expect(find.text('Synthetic group'), findsOneWidget);
      expect(find.text(l10n.messagesRefreshFailed), findsOneWidget);
      await tester.tap(find.text('Synthetic group'));
      await tester.pump();
      await finishRequests(tester);
      expect(
        find.widgetWithText(SelectableText, 'Synthetic homework summary'),
        findsOneWidget,
      );
      expect(find.text(l10n.messagesRefreshFailed), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text(l10n.messagesPermissionUnknown), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final permission in ['muted', 'unknown']) {
    testWidgets(
      'native composer blocks $permission and labels inert commands',
      (tester) async {
        final session = SessionController();
        addTearDown(session.dispose);
        final package = chatPackage(
          sendPermission: permission,
          messageKind: 'command',
        );
        await tester.runAsync(() => prepareChat(session, package));
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatPage(session: session, package: package),
          ),
        );
        await finishRequests(tester);
        await tester.tap(find.text('Synthetic group'));
        await tester.pump();
        await finishRequests(tester);
        final l10n = AppLocalizations.of(tester.element(find.byType(ChatPage)));
        expect(find.text(l10n.messagesKindCommand), findsOneWidget);
        expect(
          find.text(
            permission == 'muted'
                ? l10n.messagesCannotSendMuted
                : l10n.messagesPermissionUnknown,
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton &&
                      widget.tooltip == l10n.messagesSend,
                ),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
