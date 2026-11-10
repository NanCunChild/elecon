import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/debug/dev_log.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/community/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _FailingArchiveBlobs extends InMemoryBlobStore {
  bool fail = false;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (fail && name == 'store.enc') {
      throw StateError('synthetic_storage_failure');
    }
    await super.write(name, bytes);
  }
}

ScriptPackage enrichedPackage(String handler) {
  final raw = jsonDecode(chatPackage().encode()) as Map<String, dynamic>;
  raw['manifest']['sdkVersion'] = 20;
  raw['manifest']['accounts'] = [];
  (raw['manifest']['capabilities'] as List).add({
    'id': 'messages.enrich',
    'schema': 'elecon.messages.enrich',
    'schemaVersion': '1.0',
  });
  raw['source'] = (raw['source'] as String).replaceFirst(
    'export const capabilities = {',
    "export const capabilities = {'messages.enrich': $handler,",
  );
  return ScriptPackage.parse(jsonEncode(raw));
}

Future<void> openInbox(
  WidgetTester tester,
  SessionController session,
  ScriptPackage package,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatPage(session: session, package: package),
    ),
  );
  // Optional work does not own the page's progress indicator. Wait for its
  // actual session completion while allowing native QuickJS and UI timers.
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (DevLog.instance.entries.any(
      (e) =>
          e.message.startsWith('script end:') &&
          e.message.contains('capability=messages.enrich '),
    )) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('synthetic enrichment did not finish');
}

void main() {
  setUp(() => DevLog.instance.clear());

  for (final code in [
    'process_request_limit',
    'credential_scope_mismatch',
    'source_response_invalid',
    'account_storage_failed',
    'authentication_required',
    'fetch_failed',
  ]) {
    testWidgets(
      'enrichment classifies $code without retrying or hiding the directory',
      (tester) async {
        final package = enrichedPackage('''async ctx => {
        ctx.log('info','synthetic_enrich_attempt');
        throw Object.assign(new Error('synthetic failure'), {code:'$code'});
      }''');
        final session = SessionController();
        addTearDown(session.dispose);
        await tester.runAsync(() => prepareChat(session, package));
        var attempts = 0;
        void countAttempts() {
          if (DevLog.instance.entries.first.message ==
              '[info] synthetic_enrich_attempt') {
            attempts++;
          }
        }

        DevLog.instance.addListener(countAttempts);
        addTearDown(() => DevLog.instance.removeListener(countAttempts));
        await openInbox(tester, session, package);
        final l10n = AppLocalizations.of(tester.element(find.byType(ChatPage)));
        expect(attempts, 1);
        expect(
          find.text('Synthetic group'),
          code == 'authentication_required' ? findsNothing : findsOneWidget,
        );
        expect(
          find.text(l10n.messagesRefreshFailed),
          const {
                'process_request_limit',
                'credential_scope_mismatch',
                'source_response_invalid',
              }.contains(code)
              ? findsOneWidget
              : findsNothing,
        );
        expect(
          find.text(l10n.messagesStorageFailed),
          code == 'account_storage_failed' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(l10n.communityLoginRequired),
          code == 'authentication_required' ? findsOneWidget : findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'optional enrichment reports a real persistence failure and keeps the directory',
    (tester) async {
      final blobs = _FailingArchiveBlobs();
      final session = SessionController(blobStoreProvider: () async => blobs)
        ..scriptStorageConsent = () async => true;
      addTearDown(session.dispose);
      final package = enrichedPackage('''async ctx => {
      ctx.log('info','synthetic_enrich_attempt');
      return {serviceId:'synthetic',accountId:'synthetic-account',
        fetchedAt:new Date(ctx.now()).toISOString(),items:[]};
    }''');
      await tester.runAsync(() => prepareChat(session, package));
      var attempts = 0;
      void failStorage() {
        if (DevLog.instance.entries.first.message ==
            '[info] synthetic_enrich_attempt') {
          attempts++;
          blobs.fail = true;
        }
      }

      DevLog.instance.addListener(failStorage);
      addTearDown(() {
        blobs.fail = false;
        DevLog.instance.removeListener(failStorage);
      });
      await openInbox(tester, session, package);
      final l10n = AppLocalizations.of(tester.element(find.byType(ChatPage)));
      expect(find.text('Synthetic group'), findsOneWidget);
      expect(find.text(l10n.messagesStorageFailed), findsOneWidget);
      expect(attempts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
