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
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
