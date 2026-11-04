import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/web_content_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage fixture(String id, String status) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 14,
      'id': id,
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': id,
      'browser': true,
      'accounts': [],
      'network': {'origins': []},
      'capabilities': [
        {
          'id': 'web.content',
          'schema': 'elecon.web.content',
          'schemaVersion': '1.0',
        },
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
      'webContent': [
        {'id': 'form', 'title': 'Pinned synthetic form', 'html': '<p>Form</p>'},
      ],
    },
    'source':
        """export const capabilities={
    'web.content':async(ctx,{pageId})=>{ const count=Number((await ctx.credentials.get('counter'))?.value||0)+1;
      await ctx.credentials.set('counter',String(count));return {pageId,status:'$status'};},
    'notice.list':async ctx=>({items:[],sourceSystem:String((await ctx.credentials.get('counter'))?.value||0)})
  };""",
  }),
);

void main() {
  testWidgets(
    'web template starts only on press, pins package, never refreshes/caches/replays unknown',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final original = fixture('original.form', 'unknown');
      final other = fixture('other.form', 'completed');
      await tester.runAsync(() async {
        for (final p in [original, other]) {
          await session.installTrustedScript(p, approvedDigest: p.digest);
        }
        await session.selectTrustedScriptSchool(original.manifest.id);
        await session.selectTrustedScriptProvider(
          'synthetic',
          'web.content',
          other.manifest.id,
        );
      });
      Future<String> count() => tester
          .runAsync(() async {
            final result = await session.runTrustedScript(
              original.manifest.id,
              'notice.list',
            );
            expect(result.ok, true);
            return (result.data as Map)['sourceSystem'] as String;
          })
          .then((value) => value!);
      Widget app({required bool page}) => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: HomeCardPresentation(
              size: HomeCardSize.expanded,
              isPage: page,
              child: WebContentSection(
                session: session,
                package: original,
                page: original.manifest.webContent.single,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(page: false));
      await tester.pumpAndSettle();
      expect(find.byType(OutlinedButton), findsNothing);
      expect(await count(), '0');
      await tester.pumpWidget(app(page: true));
      await tester.pumpAndSettle();
      expect(await count(), '0');
      final blocked = await tester.runAsync(
        () => session.runTrustedScript(
          original.manifest.id,
          'web.content',
          params: {'pageId': 'form'},
          interactive: false,
        ),
      );
      expect(blocked?.reason, 'foreground_required');
      expect(await count(), '0');
      await tester.runAsync(() => session.refreshHomeData(force: true));
      expect(await count(), '0');
      await tester.tap(find.text('Open page'));
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (find
            .text(
              'The outcome is unknown. Check the service before trying again.',
            )
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(
        find.text(
          'The outcome is unknown. Check the service before trying again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Operation completed'), findsNothing);
      expect(await count(), '1');
      await tester.runAsync(() => session.refreshHomeData(force: true));
      expect(await count(), '1');
      expect(
        await tester.runAsync(
          () => session.latestCachedCapability('web.content'),
        ),
        isNull,
      );
      session.logout();
      await tester.pumpAndSettle();
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
