import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';

import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/card_spending.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/card_spending_view.dart';
import 'package:elecon_contract/card_transactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SpendingSession extends SessionController {
  final requests = <Map<String, dynamic>>[];
  final responses = <Future<CapabilityRun> Function(Map<String, dynamic>)>[];
  void changeIdentity() {
    cancelTrustedScriptRuns();
    notifyListeners();
  }

  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) async {
    expect(capability, 'card.transactions');
    requests.add(Map.of(params!));
    return responses.removeAt(0)(params);
  }
}

Map<String, dynamic> transaction(
  String id,
  int amount, {
  String direction = 'debit',
}) => {
  'transactionId': id,
  'time': DateTime.now().toUtc().toIso8601String(),
  'amountMinor': amount,
  'currency': 'CNY',
  'direction': direction,
  'merchant': 'Synthetic shop $id',
};

Widget app(Widget child, {SpendingSession? session, double scale = 1}) {
  Widget result = MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  );
  if (session != null) {
    result = SessionScope(controller: session, child: result);
  }
  return result;
}

void main() {
  testWidgets(
    'reopening restores cached transaction pages and failed refresh keeps them',
    (tester) async {
      final session = SpendingSession();
      addTearDown(session.dispose);
      final now = DateTime.now();
      String date(DateTime value) => value.toIso8601String().substring(0, 10);
      final params = {
        'from': date(DateTime(now.year, now.month, now.day - 29)),
        'to': date(now),
        'page': 1,
        'size': 100,
      };
      final pages = {
        '1': {
          'page': 1,
          'hasNext': true,
          'total': 2,
          'items': [transaction('cached-one', 125)],
        },
        '2': {
          'page': 2,
          'hasNext': false,
          'total': 2,
          'items': [transaction('cached-two', 275)],
        },
      };
      final package = ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': {
            'sdkVersion': 4,
            'id': 'synthetic-card-cache',
            'schoolId': 'synthetic',
            'version': '1.0.0',
            'name': 'Synthetic',
            'network': {'origins': []},
            'browser': false,
            'capabilities': [
              {
                'id': 'card.transactions',
                'schema': 'elecon.card.transactions',
                'schemaVersion': '1.0',
              },
            ],
            'home': [
              {
                'capability': 'card.transactions',
                'ttlSeconds': 300,
                'preload': false,
              },
            ],
          },
          'source':
              'export const capabilities={"card.transactions":async(_,params)=>(${jsonEncode(pages)})[params.page]};',
        }),
      );
      await tester.runAsync(() async {
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.id);
        for (final page in [1, 2]) {
          expect(
            (await session.runTrustedScript(
              package.manifest.id,
              'card.transactions',
              params: {...params, 'page': page},
              interactive: false,
            )).ok,
            isTrue,
          );
        }
      });
      for (var reopening = 0; reopening < 2; reopening++) {
        await tester.pumpWidget(
          app(const CardTransactionsPage(), session: session),
        );
        await tester.runAsync(() async {});
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('card-spending-chart')),
          findsOneWidget,
        );
        expect(find.textContaining('Not all records are loaded'), findsNothing);
        expect(session.requests, isEmpty);
        if (reopening == 0) await tester.pumpWidget(const SizedBox());
      }
      session.responses.add(
        (_) async => const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'synthetic_offline',
        ),
      );
      await tester.tap(find.byTooltip('Refresh').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('card-spending-chart')), findsOneWidget);
      expect(find.textContaining('synthetic_offline'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('inconsistent totals remain partial and repeated pages stop', (
    tester,
  ) async {
    final session = SpendingSession();
    addTearDown(session.dispose);
    session.responses.addAll([
      (_) async => CapabilityRun.ok({
        'page': 1,
        'hasNext': false,
        'total': 2,
        'items': [transaction('one', 125)],
      }),
      (_) async => CapabilityRun.ok({
        'page': 2,
        'hasNext': true,
        'total': 2,
        'items': [transaction('one', 125)],
      }),
    ]);
    await tester.pumpWidget(
      app(const CardTransactionsPage(), session: session),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Not all records are loaded'), findsWidgets);
    final more = find.text('Load more transactions');
    await tester.scrollUntilVisible(more, 300);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.textContaining('Not all records are loaded'), findsWidgets);
    expect(find.text('Load more transactions'), findsNothing);
    expect(session.requests, hasLength(2));
  });

  testWidgets(
    'date ranges request source window, load more and show partial spending',
    (tester) async {
      final session = SpendingSession();
      addTearDown(session.dispose);
      session.responses.addAll([
        (params) async => CapabilityRun.ok({
          'page': 1,
          'hasNext': true,
          'total': 3,
          'items': [
            transaction('one', 125),
            transaction('topup', 50000, direction: 'credit'),
          ],
        }),
        (params) async => CapabilityRun.ok({
          'page': 2,
          'hasNext': false,
          'total': 3,
          'items': [transaction('two', 275)],
        }),
        (params) async =>
            const CapabilityRun.ok({'page': 1, 'hasNext': false, 'items': []}),
      ]);
      await tester.pumpWidget(
        app(const CardTransactionsPage(), session: session),
      );
      await tester.pumpAndSettle();
      expect(session.requests.single['size'], 100);
      expect(
        DateTime.parse(session.requests.single['to'] as String)
            .difference(
              DateTime.parse(session.requests.single['from'] as String),
            )
            .inDays,
        29,
      );
      expect(find.byKey(const ValueKey('card-spending-chart')), findsOneWidget);
      expect(find.textContaining('Not all records are loaded'), findsWidgets);
      final more = find.text('Load more transactions');
      await tester.scrollUntilVisible(more, 300);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(session.requests.last['page'], 2);
      expect(find.textContaining('Not all records are loaded'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 1800));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 7 days'));
      await tester.pumpAndSettle();
      expect(session.requests.last['page'], 1);
      expect(
        DateTime.parse(session.requests.last['to'] as String)
            .difference(DateTime.parse(session.requests.last['from'] as String))
            .inDays,
        6,
      );
      expect(find.byKey(const ValueKey('card-spending-chart')), findsNothing);
      expect(find.text('No transactions in this period'), findsOneWidget);
    },
  );

  testWidgets(
    'late range result cannot overwrite current range or changed identity',
    (tester) async {
      final session = SpendingSession();
      addTearDown(session.dispose);
      final old = Completer<CapabilityRun>();
      session.responses.addAll([
        (_) => old.future,
        (_) async => CapabilityRun.ok({
          'page': 1,
          'hasNext': false,
          'items': [transaction('current', 100)],
        }),
      ]);
      await tester.pumpWidget(
        app(const CardTransactionsPage(), session: session),
      );
      await tester.pump();
      await tester.tap(find.text('Last 7 days'));
      await tester.pumpAndSettle();
      old.complete(
        CapabilityRun.ok({
          'page': 1,
          'hasNext': false,
          'items': [transaction('old', 9000)],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic shop old'), findsNothing);
      expect(find.text('Synthetic shop current'), findsWidgets);
      session.changeIdentity();
      await tester.pumpAndSettle();
      expect(find.text('Synthetic shop current'), findsNothing);
      expect(find.byKey(const ValueKey('card-spending-chart')), findsNothing);
      expect(session.requests, hasLength(2));
    },
  );

  testWidgets(
    'chart switches view and currency without overflow at narrow large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = DateTime(2026, 11, 1);
      final summary = CardSpendingSummary.fromTransactions(
        [
          for (final currency in ['CNY', 'JPY'])
            CardTransactionsItems(
              time: today.toUtc().toIso8601String(),
              amountMinor: 1234,
              currency: currency,
              direction: 'debit',
              merchant: 'Synthetic long merchant name',
            ),
        ],
        from: DateTime(2026, 8, 4),
        to: today,
      );
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: CardSpendingView(summary: summary, partial: false),
            ),
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Daily trend'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('card-spending-daily')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('JPY').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('1,234'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
