import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/scripts/device_input.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/scripts/script_device_input_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

ScriptPackage package() => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 10,
      'id': 'synthetic',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic input',
      'browser': false,
      'network': {'origins': []},
      'deviceInputs': ['camera', 'image', 'location'],
      'capabilities': [
        {
          'id': 'attendance.checkin',
          'schema': 'elecon.attendance.checkin',
          'schemaVersion': '1.1',
        },
      ],
    },
    'source': 'export const capabilities={};',
  }),
);

void main() {
  for (final kind in ['camera', 'image']) {
    testWidgets(
      '$kind waits for explicit input; picker suspension retains lease and strips metadata',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'elecon-input-test-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => directory.path,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final source = File('${directory.path}/synthetic.png');
        source.writeAsBytesSync([
          ...base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
          ...utf8.encode('PRIVATE_METADATA'),
        ]);
        final pending = Completer<XFile?>();
        final lease = ScriptSystemInputLease();
        var calls = 0;
        Object? result;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<Object?>(
                      MaterialPageRoute(
                        builder: (_) => ScriptDeviceInputPage(
                          package: package(),
                          kind: kind,
                          isActive: () => true,
                          lease: lease,
                          imagePicker: (requested) {
                            expect(requested, kind);
                            calls++;
                            return pending.future;
                          },
                        ),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(calls, 0);
        await tester.runAsync(() => tester.tap(find.byType(FilledButton)));
        await tester.pump();
        expect(calls, 1);
        expect(lease.active, isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(find.byType(ScriptDeviceInputPage), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        pending.complete(XFile(source.path));
        for (var i = 0; i < 100 && result == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        expect(result, isA<Map>());
        final image = result as Map;
        expect(image['mimeType'], 'image/png');
        expect(image['width'], 1);
        expect(
          utf8.decode(
            (image['bytes'] as List).cast<int>(),
            allowMalformed: true,
          ),
          isNot(contains('PRIVATE_METADATA')),
        );
        expect(source.existsSync(), isFalse);
        expect(lease.active, isFalse);
      },
    );
  }
  testWidgets('cancel input page does not invoke native picker', (
    tester,
  ) async {
    var calls = 0;
    final lease = ScriptSystemInputLease();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ScriptDeviceInputPage(
          package: package(),
          kind: 'image',
          isActive: () => true,
          lease: lease,
          imagePicker: (_) async {
            calls++;
            return null;
          },
        ),
      ),
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ScriptDeviceInputPage)),
    );
    await tester.tap(find.text(l10n.commonCancel));
    await tester.pump();
    expect(calls, 0);
    expect(lease.active, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
