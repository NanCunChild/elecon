import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/community/community_pages.dart';
import 'package:elecon/ui/settings/app_tunnel_page.dart';
import 'package:elecon/ui/settings/script_accounts_page.dart';
import 'package:elecon/ui/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripts/credential_reuse_test.dart' show ReuseNative;

ScriptPackage _package({
  String version = '1.0.0',
  String school = 'synthetic',
  bool requiresTunnel = true,
  String delay = '',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 16,
      'id': 'forum-$school',
      'version': version,
      'schoolId': school,
      'name': 'Synthetic forum',
      'network': {
        'origins': ['https://gateway.example.invalid'],
      },
      'browser': false,
      'appTunnels': ['hermes-atrust'],
      'accounts': [
        {
          'id': 'vpn',
          'name': 'Synthetic VPN',
          'instructions': 'Use synthetic VPN credentials',
          'capabilities': ['account.session'],
          'login': {
            'capability': 'account.session',
            'params': {'account': 'vpn', 'operation': 'login'},
          },
          'status': {
            'capability': 'account.session',
            'params': {'account': 'vpn', 'operation': 'status'},
          },
          'appTunnel': {
            'service': 'hermes-atrust',
            'gatewayUrl': 'https://gateway.example.invalid',
            'loginDomain': '',
            'loginMode': 'password',
          },
        },
      ],
      'capabilities': [
        {
          'id': 'account.session',
          'schema': 'elecon.account.session',
          'schemaVersion': '1.0',
        },
        {
          'id': 'forum.session',
          'schema': 'elecon.forum.session',
          'schemaVersion': '1.0',
          if (requiresTunnel) 'appTunnelAccountId': 'vpn',
        },
      ],
    },
    'source':
        '''export const capabilities={
      'account.session':async(c,p)=>p.operation==='status'
        ?c.appTunnel.status('hermes-atrust')
        :c.appTunnel.login('hermes-atrust',{accountId:'vpn'}),
      'forum.session':async(c,p)=>{
        await c.credentials.set('forum-'+p.operation,'SYNTHETIC');
        $delay
        return {serviceId:'synthetic',serviceName:'Synthetic $version',
          status:p.operation==='login'?'authenticated':'signedOut',
          ...(p.operation==='login'?{accountId:'synthetic',accountLabel:'Synthetic user'}:{})};
      }
    };''',
  }),
);

Widget _app(SessionController session, ScriptPackage package) => SessionScope(
  controller: session,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ForumPage(session: session, package: package),
  ),
);

Future<void> _until(WidgetTester tester, bool Function() completed) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (completed()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('The expected community state did not arrive');
}

Future<void> _idle(WidgetTester tester) => _until(
  tester,
  () =>
      find.byType(LinearProgressIndicator).evaluate().isEmpty &&
      find.byType(CircularProgressIndicator).evaluate().isEmpty,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // The QuickJS host ReceivePort is shared. Bind it outside a widget test's
    // fake event loop so callbacks remain live for each subsequent test.
    final session = SessionController()
      ..scriptStorageConsent = () async => true;
    try {
      final p = _package(requiresTunnel: false);
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
      final result = await session.runTrustedScript(
        p.manifest.id,
        'forum.session',
        params: {'operation': 'status'},
        htmlStdlib: '',
      );
      expect(result.ok, true, reason: result.reason);
      expect(session.credentialCount, 1);
    } finally {
      session.dispose();
    }
  });

  Future<SessionController> prepare(
    WidgetTester tester,
    ScriptPackage p,
  ) async {
    rootBundle.clear();
    final blobs = InMemoryBlobStore();
    final session = SessionController(
      hermesBinding: ReuseNative(),
      blobStoreProvider: () async => blobs,
    )..scriptStorageConsent = () async => true;
    addTearDown(session.dispose);
    await tester.runAsync(() async {
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
    });
    await tester.pumpWidget(_app(session, p));
    await _idle(tester);
    return session;
  }

  testWidgets(
    'missing tunnel executes no forum code and both entry points open script accounts',
    (tester) async {
      final p = _package();
      final session = await prepare(tester, p);
      final l10n = AppLocalizations.of(tester.element(find.byType(ForumPage)));
      expect(find.text(l10n.scriptTunnelRequired), findsOneWidget);
      expect(session.credentialCount, 0);
      for (final label in [l10n.communityConnect, l10n.scriptAccountsTitle]) {
        await tester.tap(find.text(label));
        await _until(
          tester,
          () => find.byType(ScriptAccountsPage).evaluate().isNotEmpty,
        );
        await _idle(tester);
        expect(find.text('Synthetic VPN'), findsOneWidget);
        expect(find.byType(SettingsPage), findsNothing);
        expect(find.byType(AppTunnelPage), findsNothing);
        expect(session.credentialCount, 0);
        Navigator.of(tester.element(find.byType(ScriptAccountsPage))).pop();
        await _until(
          tester,
          () => find.byType(ScriptAccountsPage).evaluate().isEmpty,
        );
        await _idle(tester);
        expect(find.text(l10n.scriptTunnelRequired), findsOneWidget);
        expect(session.credentialCount, 0);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning after tunnel login checks status without replaying login',
    (tester) async {
      final p = _package();
      final session = await prepare(tester, p);
      final l10n = AppLocalizations.of(tester.element(find.byType(ForumPage)));
      await tester.tap(find.text(l10n.communityConnect));
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isNotEmpty,
      );
      await _idle(tester);
      var completed = false;
      final loginFuture = session.runTrustedScript(
        p.manifest.id,
        'account.session',
        expectedDigest: p.digest,
        params: {'account': 'vpn', 'operation': 'login'},
        htmlStdlib: '',
        passwordCall: (_) async => const ScriptPasswordInput(
          username: 'SYNTHETIC',
          password: 'EXAMPLE_PASSWORD',
          remember: false,
        ),
      );
      loginFuture.then((_) => completed = true);
      await _until(tester, () => completed);
      final login = await loginFuture;
      expect(login.ok, true, reason: login.reason);
      expect((login.data as Map)['status'], 'authenticated');
      Navigator.of(tester.element(find.byType(ScriptAccountsPage))).pop();
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isEmpty,
      );
      await _idle(tester);
      expect(find.text(l10n.communitySignedOut), findsOneWidget);
      expect(
        session.credentialCount,
        1,
      ); // Only forum-status, never forum-login.
      expect(find.text(l10n.scriptTunnelRequired), findsNothing);
      await tester.tap(find.text(l10n.communityConnect));
      await _idle(tester);
      expect(session.credentialCount, 2);
      expect(
        find.text(l10n.communityConnected('Synthetic 1.0.0', 'Synthetic user')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'package replacement cannot resume the old account-page request',
    (tester) async {
      final p = _package();
      final session = await prepare(tester, p);
      final l10n = AppLocalizations.of(tester.element(find.byType(ForumPage)));
      await tester.tap(find.text(l10n.scriptAccountsTitle));
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isNotEmpty,
      );
      await _idle(tester);
      final replacement = _package(version: '2.0.0', requiresTunnel: false);
      await tester.runAsync(
        () => session.installTrustedScript(
          replacement,
          approvedDigest: replacement.digest,
        ),
      );
      Navigator.of(tester.element(find.byType(ScriptAccountsPage))).pop();
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isEmpty,
      );
      await _idle(tester);
      expect(session.credentialCount, 0);
      // A stale page cannot run newly approved bytes using its old declaration.
      await tester.tap(find.text(l10n.communityConnect));
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isNotEmpty,
      );
      await _idle(tester);
      expect(session.credentialCount, 0);
      Navigator.of(tester.element(find.byType(ScriptAccountsPage))).pop();
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isEmpty,
      );
      await tester.pumpWidget(_app(session, replacement));
      await _idle(tester);
      expect(session.credentialCount, 1);
      expect(find.text(l10n.communitySignedOut), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching schools while accounts are open does not resume forum',
    (tester) async {
      final p = _package();
      final session = await prepare(tester, p);
      final l10n = AppLocalizations.of(tester.element(find.byType(ForumPage)));
      await tester.tap(find.text(l10n.communityConnect));
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isNotEmpty,
      );
      await _idle(tester);
      final other = _package(school: 'other', requiresTunnel: false);
      await tester.runAsync(() async {
        await session.installTrustedScript(other, approvedDigest: other.digest);
        await session.selectTrustedScriptSchool(other.manifest.id);
      });
      await tester.pump();
      await _idle(tester);
      Navigator.of(tester.element(find.byType(ScriptAccountsPage))).pop();
      await _until(
        tester,
        () => find.byType(ScriptAccountsPage).evaluate().isEmpty,
      );
      expect(session.credentialCount, 0);
      expect(find.text(l10n.communitySignedOut), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a stale forum page cannot execute replacement package bytes', (
    tester,
  ) async {
    final p = _package(requiresTunnel: false);
    final session = await prepare(tester, p);
    final l10n = AppLocalizations.of(tester.element(find.byType(ForumPage)));
    expect(session.credentialCount, 1);
    final replacement = _package(version: '2.0.0', requiresTunnel: false);
    await tester.runAsync(
      () => session.installTrustedScript(
        replacement,
        approvedDigest: replacement.digest,
      ),
    );
    await tester.tap(find.text(l10n.communityConnect));
    await _idle(tester);
    expect(session.credentialCount, 1); // The replacement's login never ran.
    expect(find.text(l10n.communityRequestFailed), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing a busy page discards the previous forum result', (
    tester,
  ) async {
    rootBundle.clear();
    final session = SessionController()
      ..scriptStorageConsent = () async => true;
    addTearDown(session.dispose);
    final p = _package(
      requiresTunnel: false,
      delay: 'await new Promise(resolve=>setTimeout(resolve,200));',
    );
    await tester.runAsync(() async {
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
    });
    await tester.pumpWidget(_app(session, p));
    await _until(tester, () => session.credentialCount == 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final replacement = _package(version: '2.0.0');
    await tester.runAsync(
      () => session.installTrustedScript(
        replacement,
        approvedDigest: replacement.digest,
      ),
    );
    await tester.pumpWidget(_app(session, replacement));
    await _idle(tester);
    final l10n = AppLocalizations.of(tester.element(find.byType(ForumPage)));
    expect(find.text(l10n.scriptTunnelRequired), findsOneWidget);
    expect(find.text(l10n.communitySignedOut), findsNothing);
    expect(session.credentialCount, 1);
    expect(tester.takeException(), isNull);
  });
}
