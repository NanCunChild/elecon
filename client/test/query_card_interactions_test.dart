import 'package:elecon/catalog/schools.dart';
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/community/community_pages.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/home/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'community_reservation_test.dart' as community;
import 'support/school_fixture.dart';

class QuerySession extends SessionController {
  final calls = <String>[];
  final interactiveCalls = <bool>[];
  final parameters = <Map<String, dynamic>?>[];
  bool needsConfiguration = false;

  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    ScriptRunCancellation? cancellation,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) async {
    calls.add(capability);
    interactiveCalls.add(interactive);
    parameters.add(params);
    if (needsConfiguration && params?['configure'] != true) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.configuration,
        'configuration_required',
      );
    }
    needsConfiguration = false;
    return CapabilityRun.ok(switch (capability) {
      'grades.list' => {'term': 'synthetic', 'items': <Object>[]},
      'gpa.summary' => {'gpa': 3.5, 'gradePointScale': '4.0'},
      'card.balance' => {
        'balance': {'amountMinor': 1234, 'currency': 'CNY'},
      },
      _ => {'items': <Object>[]},
    });
  }
}

class LegacyNoticeSession extends QuerySession {
  @override
  SchoolDescriptor get selectedSchool => testSchool();
}

Widget app(SessionController session, Widget child) => SessionScope(
  controller: session,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child is MessagesPage || child is EleconHomePage
        ? child
        : Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  testWidgets(
    'legacy notice reads after the first frame without interaction and retains manual refresh',
    (tester) async {
      final session = LegacyNoticeSession();
      addTearDown(session.dispose);
      await tester.runAsync(() => session.scriptRegistry);
      await tester.pumpWidget(app(session, const NoticeSection()));
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(session.calls, ['notice.list']);
      expect(session.interactiveCalls, [false]);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(session.interactiveCalls, [false, true]);
    },
  );

  testWidgets(
    'script notice without home preload loads once and refreshes the same section',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = community.package(
        'notice-no-home',
        ['notice.list'],
        source: """
      export const capabilities={'notice.list':async(ctx)=>{
        const previous=await ctx.credentials.get('counter');
        const count=Number(previous?.value ?? 0)+1;
        await ctx.credentials.set('counter',String(count));
        return {items:[{id:'synthetic',title:'Synthetic notice '+count,category:'academic',source:'Synthetic'}]};
      }};
    """,
      );
      await tester.runAsync(() async {
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.id);
        expect((await session.runCapability('notice.list')).ok, isTrue);
      });
      await tester.pumpWidget(app(session, const NoticeSection()));
      Future<void> waitFor(String title) async {
        for (var count = 0; count < 100; count++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (find.text(title).evaluate().isNotEmpty) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        fail('Expected notice result: $title');
      }

      await waitFor('Synthetic notice 2');
      expect(
        await tester.runAsync(
          () => session.latestCachedCapability('notice.list'),
        ),
        isNull,
      );
      await tester.tap(find.byTooltip('Refresh'));
      await waitFor('Synthetic notice 3');
      expect(find.text('Synthetic notice 2'), findsNothing);
      await tester.pumpWidget(app(session, const EleconHomePage()));
      await waitFor('Synthetic notice 4');
      // The first refresh belongs to the desktop header; the second belongs
      // to the notice card. A package without preload must still be updated.
      await tester.tap(find.byTooltip('Refresh').first);
      await waitFor('Synthetic notice 5');
      expect(find.text('Synthetic notice 4'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (capability, section) in <(String, Widget)>[
    ('notice.list', const NoticeSection()),
    ('grades.list', const GradesSection()),
    ('card.balance', const CardSection()),
    ('exam.list', const ExamSection()),
    ('library.loans', const LibraryLoansSection()),
  ]) {
    testWidgets(
      '$capability refresh stays in the header before and after loading; card opens details',
      (tester) async {
        final session = QuerySession();
        addTearDown(session.dispose);
        var opened = 0;
        await tester.pumpWidget(
          app(
            session,
            HomeCardPresentation(
              size: HomeCardSize.expanded,
              onOpen: () => opened++,
              child: section,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SectionRefreshButton), findsOneWidget);
        expect(
          find.widgetWithIcon(FilledButton, Icons.download_outlined),
          findsNothing,
        );
        expect(find.text('View'), findsNothing);
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pumpAndSettle();
        expect(session.calls.where((call) => call == capability), hasLength(1));
        expect(opened, 0);
        expect(find.byType(SectionRefreshButton), findsOneWidget);
        expect(find.text('重新查询'), findsNothing);
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pumpAndSettle();
        expect(session.calls.where((call) => call == capability), hasLength(2));
        final card = tester.widget<SectionCard>(find.byType(SectionCard).first);
        await tester.tap(find.text(card.title).first);
        expect(opened, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'missing configuration is distinct and only its explicit button sends configure',
    (tester) async {
      final session = QuerySession()..needsConfiguration = true;
      addTearDown(session.dispose);
      await tester.pumpWidget(
        app(session, const CardSection(transactionsEnabled: false)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(CardSection)),
      );
      expect(find.text(l10n.capabilityConfigurationRequired), findsOneWidget);
      expect(find.text(l10n.campusLoadFailed), findsNothing);
      expect(session.parameters, [<String, dynamic>{}]);
      await tester.tap(find.text(l10n.capabilityCompleteConfiguration));
      await tester.pumpAndSettle();
      expect(session.parameters.last, {'configure': true});
      expect(find.textContaining('12.34'), findsOneWidget);
      expect(find.text(l10n.capabilityConfigurationRequired), findsNothing);
    },
  );

  testWidgets(
    'messages page offers message refresh without attendance or location controls',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = community.package('messages-with-checkin', [
        'messages.list',
        'attendance.checkin',
      ]);
      await tester.pumpWidget(
        app(session, MessagesPage(session: session, package: package)),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
      expect(find.textContaining('Scan'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
