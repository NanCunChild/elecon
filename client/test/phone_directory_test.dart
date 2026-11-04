import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/phone_directory_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture([String name = '合成服务']) => {
  'items': [
    {
      'id': 'north',
      'name': name,
      'category': '合成后勤',
      'campus': '北校区',
      'phone': '10000',
      'sourceUrl': 'https://example.invalid/north',
    },
    {
      'id': 'south',
      'name': name,
      'category': '合成后勤',
      'campus': '南校区',
      'phone': '10001',
      'sourceUrl': 'https://example.invalid/south',
    },
    {
      'id': 'other',
      'name': '合成教务',
      'category': '合成教学',
      'phone': '+8610000000000',
      'sourceUrl': 'https://example.invalid/teaching',
    },
  ],
  'sourceUrl': 'https://example.invalid/',
  'verifiedDate': '2026-11-04',
};

Widget app(
  Widget child, {
  SessionController? session,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  theme: ThemeData(brightness: brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: session == null
        ? SingleChildScrollView(child: child)
        : SessionScope(
            controller: session,
            child: SingleChildScrollView(child: child),
          ),
  ),
);

ScriptPackage script(
  String id, {
  String version = '1.0.0',
  bool provide = true,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 16,
      'id': id,
      'schoolId': 'synthetic-phones',
      'version': version,
      'name': 'Synthetic directory',
      'browser': false,
      'network': {'origins': []},
      'accounts': [],
      'capabilities': [
        if (provide)
          {
            'id': 'directory.phones',
            'schema': 'elecon.directory.phones',
            'schemaVersion': '1.0',
          },
      ],
      'cards': [
        {'id': 'phones', 'type': 'directory', 'defaultVariant': 'regular'},
      ],
      'home': [
        if (provide)
          {
            'capability': 'directory.phones',
            'ttlSeconds': 86400,
            'preload': false,
          },
      ],
    },
    'source':
        'export const capabilities = {"directory.phones": async () => (${jsonEncode(fixture(id))})};',
  }),
);

void main() {
  test(
    'decoder rejects an entire malformed directory and duplicate identities',
    () {
      expect(phoneDirectoryFromDynamic(fixture()), isNotNull);
      final duplicate = fixture();
      (duplicate['items'] as List)[1]['id'] = 'north';
      expect(phoneDirectoryFromDynamic(duplicate), isNull);
      for (final phone in ['tel:10000', '*123#', '10000;1', '10000\n', '12']) {
        final invalid = fixture();
        (invalid['items'] as List)[0]['phone'] = phone;
        expect(phoneDirectoryFromDynamic(invalid), isNull, reason: phone);
      }
      expect(
        phoneDirectoryFromDynamic({...fixture(), 'verifiedDate': '2026-02-30'}),
        isNull,
      );
    },
  );

  test('directory card requires its own capability', () {
    expect(
      script('synthetic-directory').manifest.cards.single.type,
      'directory',
    );
    expect(
      () => script('synthetic-directory', provide: false),
      throwsFormatException,
    );
  });

  testWidgets(
    'search matches campus and formatted numbers without merging equal names',
    (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        app(
          PhoneDirectoryView(
            directory: phoneDirectoryFromDynamic(fixture())!,
            dial: (phone) async {
              calls.add(phone);
              return true;
            },
          ),
        ),
      );
      expect(find.text('合成服务'), findsNWidgets(2));
      expect(calls, isEmpty);
      await tester.enterText(find.byKey(const Key('phone-search')), '南校区');
      await tester.pumpAndSettle();
      expect(find.text('合成服务'), findsOneWidget);
      expect(find.byKey(const ValueKey('call-north')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('call-south')));
      await tester.pumpAndSettle();
      expect(calls, ['10001']);
      await tester.enterText(find.byKey(const Key('phone-search')), '100-00');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('call-north')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('phone-search')), '不存在');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的电话'), findsOneWidget);
      expect(calls, ['10001']);
    },
  );

  testWidgets('category filters and empty directory use distinct empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(PhoneDirectoryView(directory: phoneDirectoryFromDynamic(fixture())!)),
    );
    await tester.tap(find.byKey(const Key('phone-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成教学').last);
    await tester.pumpAndSettle();
    expect(find.text('合成服务'), findsNothing);
    expect(find.text('合成教务'), findsOneWidget);
    await tester.pumpWidget(
      app(
        PhoneDirectoryView(
          key: const Key('empty'),
          directory: phoneDirectoryFromDynamic({...fixture(), 'items': []})!,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('共 0 条电话'), findsOneWidget);
    expect(find.text('没有匹配的电话'), findsOneWidget);
  });

  testWidgets('dial failure is recoverable and phone can be copied', (
    tester,
  ) async {
    final clipboard = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          clipboard.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      app(
        PhoneDirectoryView(
          directory: phoneDirectoryFromDynamic(fixture())!,
          dial: (_) async => false,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('call-north')));
    await tester.pumpAndSettle();
    expect(find.text('无法打开电话应用，可复制号码后拨打'), findsOneWidget);
    await tester.tap(find.text('合成服务').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('复制号码').first);
    await tester.pumpAndSettle();
    expect(
      clipboard.any(
        (call) =>
            call.method == 'Clipboard.setData' &&
            (call.arguments as Map)['text'] == '10000',
      ),
      isTrue,
    );
  });

  testWidgets(
    'system launcher receives only an explicitly constructed tel URI',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final launched = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            launched.add((call.arguments as Map)['url'] as String);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(await openPhoneDialer('*123#'), isFalse);
      expect(await openPhoneDialer('https://example.invalid/'), isFalse);
      expect(launched, isEmpty);
      expect(await openPhoneDialer('+8610000000000'), isTrue);
      expect(launched, ['tel:+8610000000000']);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'no_handler'),
          );
      expect(await openPhoneDialer('10000'), isFalse);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('narrow directory supports large text in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          PhoneDirectoryView(directory: phoneDirectoryFromDynamic(fixture())!),
          scale: 2,
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'bound card reads its own cache and drops results after source update',
    (tester) async {
      final result = (await tester.runAsync(() async {
        final session = SessionController();
        await session.bootstrap();
        final base = script('synthetic-primary');
        final extra = script('synthetic-secondary');
        for (final package in [base, extra]) {
          await session.installTrustedScript(
            package,
            approvedDigest: package.digest,
          );
        }
        await session.selectTrustedScriptSchool(base.manifest.id);
        final source = CapabilitySource(
          packageId: extra.manifest.id,
          digest: extra.digest,
        );
        final run = await CapabilityQueries(session, source: source)
            .runCapability(
              'directory.phones',
              params: const {},
              interactive: false,
            );
        expect(run.ok, isTrue, reason: run.reason);
        return (session, extra, source);
      }))!;
      final (session, extra, source) = result;
      addTearDown(session.dispose);
      await tester.pumpWidget(
        app(
          CapabilitySourceScope(
            source: source,
            child: const PhoneDirectorySection(),
          ),
          session: session,
        ),
      );
      for (
        var i = 0;
        i < 100 && find.text('synthetic-secondary').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.text('synthetic-secondary'), findsNWidgets(2));
      expect(find.text('synthetic-primary'), findsNothing);
      await tester.runAsync(() async {
        final updated = script(extra.manifest.id, version: '1.0.1');
        await session.installTrustedScript(
          updated,
          approvedDigest: updated.digest,
        );
      });
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('synthetic-secondary'), findsNothing);
      expect(find.byKey(const ValueKey('call-north')), findsNothing);
    },
  );
}
