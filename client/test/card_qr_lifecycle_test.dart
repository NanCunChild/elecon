import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/models.dart';
import 'package:elecon/ui/home/script_feature_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'feature_pages_test.dart' as fixture;
import 'energy_climate_sections_test.dart' as ui;

void main() {
  testWidgets(
    'SDK19 script schedules QR renewal through the real page and shell',
    (tester) async {
      final package = ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': {
            'sdkVersion': 19,
            'id': 'synthetic.qr',
            'schoolId': 'synthetic',
            'version': '1.0.0',
            'name': 'Synthetic',
            'accounts': [],
            'network': {'origins': []},
            'browser': false,
            'capabilities': [
              {
                'id': 'card.qr',
                'schema': 'elecon.card.qr',
                'schemaVersion': '1.0',
              },
            ],
            'pages': [
              {'id': 'card', 'title': 'Synthetic card', 'template': 'card'},
            ],
          },
          'source':
              '''
        function image(purpose) {
          const now = Date.now();
          return {imageBase64:${jsonEncode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNgYGD4D8b/oQAAO9YJ94Wj2vcAAAAASUVORK5CYII=')}, issuedAt:new Date(now).toISOString(),
            expiresAt:new Date(now+30000).toISOString(),purpose};
        }
        export const capabilities = {'card.qr':async ctx=>{
          if(ctx.execution){
            await ctx.execution.state.set('qr',{count:0});
            await ctx.execution.register({id:'qr',handler:'renew',stateKey:'qr'});
            await ctx.execution.schedule('qr',Date.now()+1500);
          }
          return image('initial');
        }};
        export const handlers = {renew:async ctx=>{
          const e=ctx.execution, state=await e.state.get(e.stateKey);
          await e.state.set(e.stateKey,{count:state.count+1});
          await ctx.credentials.set('syntheticRenewed','yes');
          await e.schedule('qr',Date.now()+1500);
          return image('renewed-'+(state.count+1));
        }};
      ''',
        }),
      );
      final session = SessionController();
      final theme = ThemeController();
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(session.dispose);
      addTearDown(theme.dispose);
      await tester.runAsync(() async {
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.id);
        expect(
          (await session.runCapability('card.qr', interactive: false)).ok,
          isTrue,
        );
      });
      await tester.pumpWidget(
        ThemeScope(
          controller: theme,
          child: SessionScope(
            controller: session,
            child: MaterialApp(
              navigatorKey: navigator,
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MainShell(
                loadHomeSnapshot: () async => const CampusSnapshot(
                  schoolName: 'Synthetic',
                  updatedAt: null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => ScriptFeaturePage(
            package: package,
            page: package.manifest.pages.single,
          ),
        ),
      );
      final credentialsBefore = session.credentialCount;
      await ui.until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await ui.until(
        tester,
        () =>
            session.credentialCount > credentialsBefore &&
            find.byType(Image).evaluate().isNotEmpty,
      );
      expect(find.byType(Image), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await ui.until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );
  testWidgets('QR renews after real shell background cancellation', (
    tester,
  ) async {
    final session = fixture.FeatureSession();
    final theme = ThemeController();
    final navigator = GlobalKey<NavigatorState>();
    addTearDown(session.dispose);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ThemeScope(
        controller: theme,
        child: SessionScope(
          controller: session,
          child: MaterialApp(
            navigatorKey: navigator,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MainShell(
              loadHomeSnapshot: () async => const CampusSnapshot(
                schoolName: 'Synthetic',
                updatedAt: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const CardQrPage()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(session.calls, ['card.qr']);
    final generation = session.trustedScriptViewGeneration;
    final changed = AppLocalizations.of(
      tester.element(find.byType(CardQrPage)),
    ).homeCardDataChanged;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();
    expect(session.trustedScriptViewGeneration, greaterThan(generation));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(session.calls, ['card.qr', 'card.qr']);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text(changed), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
