import 'dart:async';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/scripts/script_scanner_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../support/scanner_fixture.dart';

class FakeScanner extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  int starts = 0, stops = 0, disposals = 0;
  bool denied = false;
  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    expect(options.formats, [BarcodeFormat.qrCode]);
    expect(options.returnImage, isFalse);
    if (denied) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  Future<void> updateScanWindow(Rect? window) async {}
}

void main() {
  late FakeScanner fake;
  late MobileScannerPlatform original;
  setUp(() {
    original = MobileScannerPlatform.instance;
    fake = FakeScanner();
    MobileScannerPlatform.instance = fake;
  });
  tearDown(() async {
    MobileScannerPlatform.instance = original;
    await fake.captures.close();
  });

  Future<void> open(
    WidgetTester tester,
    bool Function() valid,
    void Function(Object?) done,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                try {
                  done(
                    await presentScriptScanner(
                      context,
                      scannerPackage(''),
                      valid,
                    ),
                  );
                } catch (e) {
                  done(e);
                }
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('QR page returns text once and stops camera before completing', (
    tester,
  ) async {
    Object? result;
    var completed = 0;
    await open(tester, () => true, (r) {
      result = r;
      completed++;
      expect(fake.stops, greaterThanOrEqualTo(1));
    });
    expect(find.text('Scan QR code'), findsOneWidget);
    expect(fake.starts, 1);
    fake.captures.add(
      const BarcodeCapture(
        barcodes: [
          Barcode(format: BarcodeFormat.qrCode, rawValue: 'SYNTHETIC_QR'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(result, {'text': 'SYNTHETIC_QR', 'format': 'qrCode'});
    expect(completed, 1);
    expect(find.text('Scan QR code'), findsNothing);
  });
  testWidgets('back navigation cancels and releases camera', (tester) async {
    var completed = false;
    Object? result = 'unset';
    await open(tester, () => true, (r) {
      result = r;
      completed = true;
    });
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
    expect(fake.stops, 1);
  });
  testWidgets('revoked invocation closes scan and rejects late frames', (
    tester,
  ) async {
    var valid = true;
    Object? result;
    await open(tester, () => valid, (r) => result = r);
    valid = false;
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(result, isA<ScriptRunException>());
    expect(fake.stops, 1);
    expect(find.text('Scan QR code'), findsNothing);
  });
  testWidgets(
    'backgrounding cancels scan and permission denial is a fixed code',
    (tester) async {
      Object? result = 'unset';
      await open(tester, () => true, (r) => result = r);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(fake.stops, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      fake.denied = true;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        result,
        isA<ScriptRunException>().having(
          (e) => e.code,
          'code',
          'scanner_permission_denied',
        ),
      );
    },
  );
}
