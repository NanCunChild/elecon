/// ADR-058: host-owned foreground device inputs. No source paths cross SDK.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/scripts/device_input.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';

Future<Object?> presentScriptDeviceInput(
  BuildContext context,
  ScriptPackage package,
  String kind,
  bool Function() isActive,
  ScriptSystemInputLease lease,
) async {
  if (!context.mounted || !isActive()) {
    throw const ScriptDeviceInputException('invocation_cancelled');
  }
  if (kIsWeb ||
      !{
        TargetPlatform.android,
        TargetPlatform.iOS,
      }.contains(defaultTargetPlatform) ||
      (WidgetsBinding.instance.lifecycleState != null &&
          WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed)) {
    throw const ScriptDeviceInputException('device_input_unavailable');
  }
  final result = await Navigator.of(context, rootNavigator: true).push<Object?>(
    MaterialPageRoute(
      builder: (_) => ScriptDeviceInputPage(
        package: package,
        kind: kind,
        isActive: isActive,
        lease: lease,
      ),
    ),
  );
  if (!context.mounted || !isActive()) {
    throw const ScriptDeviceInputException('invocation_cancelled');
  }
  if (result is ScriptDeviceInputException) throw result;
  return result;
}

/// Re-encode decoded pixels, never forward original metadata/EXIF or paths.
Future<Map<String, Object?>> normalizeScriptImage(Uint8List original) async {
  if (original.isEmpty || original.length > 16 * 1024 * 1024) {
    throw const ScriptDeviceInputException('device_input_invalid_result');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(original);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width * descriptor.height > 32 * 1024 * 1024) {
      throw const ScriptDeviceInputException('device_input_invalid_result');
    }
    var longest = math.min(1280, math.max(descriptor.width, descriptor.height));
    while (true) {
      final factor = longest / math.max(descriptor.width, descriptor.height);
      final width = math.max(1, (descriptor.width * factor).round());
      final height = math.max(1, (descriptor.height * factor).round());
      final codec = await descriptor.instantiateCodec(
        targetWidth: width,
        targetHeight: height,
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final encoded = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (encoded != null && encoded.lengthInBytes <= maxScriptImageBytes) {
            return {
              'bytes': encoded.buffer.asUint8List(),
              'mimeType': 'image/png',
              'width': image.width,
              'height': image.height,
            };
          }
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
      if (longest <= 160) {
        throw const ScriptDeviceInputException('device_input_invalid_result');
      }
      longest = math.max(160, (longest * .7).floor());
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<void> _deletePickerCopy(XFile file) async {
  try {
    final temp = await getTemporaryDirectory();
    final path = File(file.path).absolute.uri.normalizePath().toFilePath();
    final allowedRoots = {
      temp.absolute.path,
      Directory.systemTemp.absolute.path,
    };
    // Only remove picker-owned copies inside this application's temporary root.
    if (allowedRoots.any(
      (root) => path.startsWith('$root${Platform.pathSeparator}'),
    )) {
      await File(path).delete();
    }
  } catch (_) {
    /* Never log user paths or image content. */
  }
}

/// Android may save an interrupted picker result; it belongs to a dead lease.
/// Discard it rather than attaching it to the next identity or script execution.
Future<void> discardAbandonedScriptImages() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final lost = await ImagePicker().retrieveLostData();
    for (final file in lost.files ?? <XFile>[]) {
      await _deletePickerCopy(file);
    }
  } catch (_) {
    /* Unsupported platforms and empty recovery are harmless. */
  }
}

class ScriptDeviceInputPage extends StatefulWidget {
  const ScriptDeviceInputPage({
    super.key,
    required this.package,
    required this.kind,
    required this.isActive,
    required this.lease,
    this.imagePicker,
  });
  final ScriptPackage package;
  final String kind;
  final bool Function() isActive;
  final ScriptSystemInputLease lease;
  @visibleForTesting
  final Future<XFile?> Function(String kind)? imagePicker;
  @override
  State<ScriptDeviceInputPage> createState() => _ScriptDeviceInputPageState();
}

class _ScriptDeviceInputPageState extends State<ScriptDeviceInputPage>
    with WidgetsBindingObserver {
  Timer? _monitor;
  bool _busy = false, _closed = false;
  StreamSubscription<Position>? _position;
  Completer<Position>? _positionResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _monitor = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!widget.isActive()) {
        _close(const ScriptDeviceInputException('invocation_cancelled'));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.lease.foreground = true;
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.lease.foreground = false;
    }
    if ((state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        !widget.lease.active) {
      _close(const ScriptDeviceInputException('invocation_cancelled'));
    }
  }

  Future<void> _close([Object? result]) async {
    if (!mounted || _closed) return;
    _closed = true;
    await _position?.cancel();
    final pending = _positionResult;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const ScriptDeviceInputException('invocation_cancelled'),
      );
    }
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent == true) {
      Navigator.of(context).pop(result);
    } else if (route?.isActive == true) {
      Navigator.of(context).removeRoute(route!, result);
    }
  }

  Future<Map<String, Object?>> _location() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const ScriptDeviceInputException('device_input_unavailable');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (![
      LocationPermission.whileInUse,
      LocationPermission.always,
    ].contains(permission)) {
      throw const ScriptDeviceInputException('device_input_permission_denied');
    }
    if (_closed || !widget.isActive()) {
      throw const ScriptDeviceInputException('invocation_cancelled');
    }
    final started = DateTime.now().toUtc();
    final result = Completer<Position>();
    _positionResult = result;
    _position =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            timeLimit: Duration(seconds: 20),
          ),
        ).listen(
          (position) {
            if (!result.isCompleted &&
                !position.timestamp.isBefore(
                  started.subtract(const Duration(seconds: 5)),
                )) {
              result.complete(position);
            }
          },
          onError: (Object _) {
            if (!result.isCompleted) {
              result.completeError(
                const ScriptDeviceInputException('device_input_unavailable'),
              );
            }
          },
        );
    try {
      final value = await result.future.timeout(const Duration(seconds: 20));
      if (value.isMocked) {
        throw const ScriptDeviceInputException('device_input_invalid_result');
      }
      return {
        'latitude': value.latitude,
        'longitude': value.longitude,
        'accuracyMeters': value.accuracy,
        'capturedAt': value.timestamp.toUtc().toIso8601String(),
        'coordinateSystem': 'wgs84',
      };
    } on TimeoutException {
      throw const ScriptDeviceInputException('device_input_timeout');
    } finally {
      await _position?.cancel();
      _position = null;
      _positionResult = null;
    }
  }

  Future<void> _choose() async {
    if (_busy || _closed || !widget.isActive()) return;
    setState(() => _busy = true);
    try {
      final Object? result;
      if (widget.kind == 'location') {
        result = await _location();
      } else {
        if (widget.imagePicker == null) await discardAbandonedScriptImages();
        if (_closed || !widget.isActive()) return;
        result = await widget.lease.run(() async {
          final file = widget.imagePicker != null
              ? await widget.imagePicker!(widget.kind)
              : await ImagePicker().pickImage(
                  source: widget.kind == 'camera'
                      ? ImageSource.camera
                      : ImageSource.gallery,
                  requestFullMetadata: false,
                );
          if (file == null) return null;
          try {
            if (await file.length() > 16 * 1024 * 1024) {
              throw const ScriptDeviceInputException(
                'device_input_invalid_result',
              );
            }
            if (_closed || !widget.isActive()) {
              throw const ScriptDeviceInputException('invocation_cancelled');
            }
            final normalized = await normalizeScriptImage(
              await file.readAsBytes(),
            );
            // OS pickers may resolve just before Flutter receives resumed.
            for (
              var i = 0;
              i < 20 &&
                  WidgetsBinding.instance.lifecycleState !=
                      AppLifecycleState.resumed;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            if (WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
              throw const ScriptDeviceInputException('invocation_cancelled');
            }
            return normalized;
          } finally {
            await _deletePickerCopy(file);
          }
        });
      }
      if (_closed || !widget.isActive()) return;
      await _close(validateDeviceInput(widget.kind, result));
    } on ScriptDeviceInputException catch (error) {
      await _close(error);
    } on PlatformException catch (error) {
      await _close(
        ScriptDeviceInputException(
          error.code.contains('denied')
              ? 'device_input_permission_denied'
              : 'device_input_unavailable',
        ),
      );
    } catch (_) {
      await _close(
        const ScriptDeviceInputException('device_input_unavailable'),
      );
    }
  }

  @override
  void dispose() {
    _closed = true;
    _monitor?.cancel();
    unawaited(_position?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = switch (widget.kind) {
      'camera' => l10n.deviceInputCamera,
      'image' => l10n.deviceInputImage,
      _ => l10n.deviceInputLocation,
    };
    return PopScope<Object?>(
      canPop: !_busy,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _close();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.package.manifest.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Text(
                  widget.kind == 'location'
                      ? l10n.deviceInputLocationHelp
                      : l10n.deviceInputImageHelp,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _choose,
                  child: Text(title),
                ),
                TextButton(
                  onPressed: () => _close(),
                  child: Text(l10n.commonCancel),
                ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
