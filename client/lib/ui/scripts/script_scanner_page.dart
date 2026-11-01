/// ADR-045: host camera route, bound to one foreground invocation lease.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/scripts/manifest.dart';
import '../../core/scripts/runtime.dart';
import '../../core/scripts/scanner.dart';
import '../../l10n/gen/app_localizations.dart';

Future<Object?> presentScriptScanner(
  BuildContext context,
  ScriptPackage package,
  bool Function() isActive,
) async {
  if (!context.mounted || !isActive()) {
    throw const ScriptRunException('invocation_cancelled');
  }
  if (kIsWeb ||
      !{
        TargetPlatform.android,
        TargetPlatform.iOS,
      }.contains(defaultTargetPlatform)) {
    throw const ScriptRunException('scanner_unavailable');
  }
  if (WidgetsBinding.instance.lifecycleState != null &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
    throw const ScriptRunException('scanner_unavailable');
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = MaterialPageRoute<Object?>(
    builder: (_) => ScriptScannerPage(
      package: package,
      isActive: () => context.mounted && isActive(),
    ),
  );
  final result = await navigator.push(route);
  if (!context.mounted || !isActive()) {
    throw const ScriptRunException('invocation_cancelled');
  }
  if (result is ScriptScannerException) throw ScriptRunException(result.code);
  return result;
}

class ScriptScannerPage extends StatefulWidget {
  const ScriptScannerPage({
    super.key,
    required this.package,
    required this.isActive,
  });
  final ScriptPackage package;
  final bool Function() isActive;
  @override
  State<ScriptScannerPage> createState() => _ScriptScannerPageState();
}

class _ScriptScannerPageState extends State<ScriptScannerPage>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    returnImage: false,
  );
  Timer? _monitor;
  Future<void>? _starting;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_observeCamera);
    _monitor = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!widget.isActive()) {
        _close(const ScriptScannerException('invocation_cancelled'));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _starting = _start());
  }

  Future<void> _start() async {
    if (!mounted || _closed || !widget.isActive()) return;
    try {
      await _controller.start();
      if (_closed) await _controller.stop();
    } on MobileScannerException catch (error) {
      if (!mounted || _closed) return;
      if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
        _close(const ScriptScannerException('scanner_permission_denied'));
      } else {
        _close(const ScriptScannerException('scanner_unavailable'));
      }
    } catch (_) {
      if (mounted && !_closed) {
        _close(const ScriptScannerException('scanner_unavailable'));
      }
    }
  }

  void _observeCamera() {
    final error = _controller.value.error;
    if (error != null && !_closed) {
      _close(
        ScriptScannerException(
          error.errorCode == MobileScannerErrorCode.permissionDenied
              ? 'scanner_permission_denied'
              : 'scanner_unavailable',
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS permission prompt can briefly make the app inactive; no frames
    // are returned then. A background/hidden app revokes the scan immediately.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _close();
    }
  }

  Future<void> _close([Object? result]) async {
    if (!mounted || _closed) return;
    setState(() => _closed = true);
    try {
      await _starting;
      await _controller.stop();
    } catch (_) {}
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      if (route?.isActive == true) {
        Navigator.of(context).removeRoute(route!, result);
      }
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (route?.isCurrent == true) {
      Navigator.of(context).pop(result);
    } else if (route?.isActive == true) {
      Navigator.of(context).removeRoute(route!, result);
    }
  }

  void _detect(BarcodeCapture capture) {
    if (_closed ||
        !widget.isActive() ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode || barcode.rawValue == null) {
        continue;
      }
      try {
        final result = validateScanResult({
          'text': barcode.rawValue,
          'format': 'qrCode',
        });
        _close(result);
      } on ScriptScannerException {
        _close(const ScriptScannerException('scanner_invalid_result'));
      }
      return;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _monitor?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_observeCamera);
    // Native permission/start can finish after this route is removed. Keep
    // ownership until startup settles, then release the camera and controller.
    unawaited(
      () async {
        try {
          await _starting;
        } finally {
          await _controller.dispose();
        }
      }().catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope<Object?>(
      canPop: _closed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.scannerTitle)),
        body: Column(
          children: [
            ListTile(
              title: Text(widget.package.manifest.name),
              subtitle: Text(l10n.scannerHint),
            ),
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: _detect,
                errorBuilder: (_, _) => Center(child: Text(l10n.scannerFailed)),
              ),
            ),
            SafeArea(
              top: false,
              child: TextButton(
                onPressed: () => _close(),
                child: Text(l10n.commonCancel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
