import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../session/profile_controller.dart';
import '../../session/session_controller.dart';
import 'app_feature.dart';

class FeatureOpenRequest {
  const FeatureOpenRequest(this.id, this.feature);
  final int id;
  final AppFeature feature;
}

/// Navigation requests contain no school data. One pending destination survives
/// startup/onboarding, and is discarded when a previously bound identity changes.
class AppShortcutsController extends ChangeNotifier {
  AppShortcutsController({required this.profiles, this.channel}) {
    profiles.addListener(_scopeChanged);
    _scopeChanged();
    channel?.setMethodCallHandler((call) async {
      if (call.method == 'openFeature') receive(call.arguments);
    });
    _initialize();
  }

  final ProfileController profiles;
  final MethodChannel? channel;
  FeatureOpenRequest? _pending;
  FeatureOpenRequest? get pending => _pending;
  bool get canOpen => !_disposed && profiles.isRestored && !profiles.busy;
  bool _supported = false;
  bool get supported => _supported;
  bool _disposed = false;
  int _serial = 0;
  SessionController? _session;
  String? _profile;
  String? _school;

  Future<void> _initialize() async {
    if (channel == null) return;
    try {
      final serial = _serial;
      final feature = await channel!.invokeMethod<String>('getInitialFeature');
      if (_disposed) return;
      if (feature != null && serial == _serial) receive(feature);
      _supported = await channel!.invokeMethod<bool>('canPin') ?? false;
      if (!_disposed) notifyListeners();
    } on PlatformException {
      // A launcher may not provide pinning; deep links and static entries work.
    } on MissingPluginException {
      // Other platforms do not expose Android shortcuts.
    }
  }

  void receive(Object? value) {
    final feature = value is String ? AppFeature.fromUri(value) : null;
    if (_disposed || feature == null) return;
    _pending = FeatureOpenRequest(++_serial, feature);
    _profile = profiles.isRestored ? profiles.active.id : null;
    _school = profiles.isRestored
        ? profiles.active.session.selectedSchool?.id
        : null;
    notifyListeners();
  }

  bool consume(FeatureOpenRequest request) {
    if (!canOpen || !identical(request, _pending)) return false;
    _pending = null;
    notifyListeners();
    return true;
  }

  void _scopeChanged() {
    if (_disposed) return;
    final next = profiles.active.session;
    if (!identical(next, _session)) {
      _session?.removeListener(_scopeChanged);
      _session = next;
      next.addListener(_scopeChanged);
    }
    if (_pending == null || !profiles.isRestored) return;
    if ((_profile != null && _profile != profiles.active.id) ||
        (_school != null && _school != next.selectedSchool?.id)) {
      _pending = null;
    } else {
      _profile = profiles.active.id;
      _school = next.selectedSchool?.id;
    }
    notifyListeners();
  }

  /// True only means that the system accepted the request to show a prompt.
  Future<bool> pin(AppFeature feature) async {
    if (_disposed || channel == null || !_supported) return false;
    try {
      return await channel!.invokeMethod<bool>('pinFeature', feature.name) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    profiles.removeListener(_scopeChanged);
    _session?.removeListener(_scopeChanged);
    channel?.setMethodCallHandler(null);
    super.dispose();
  }
}
