import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
enum ShortcutPinResult {
  requested,
  pinned,
  unsupported,
  restricted,
  unavailable,
  failed,
}

class AppShortcutsController extends ChangeNotifier
    with WidgetsBindingObserver {
  AppShortcutsController({required this.profiles, this.channel}) {
    profiles.addListener(_scopeChanged);
    WidgetsBinding.instance.addObserver(this);
    _scopeChanged();
    channel?.setMethodCallHandler((call) async {
      if (call.method == 'openFeature') receive(call.arguments);
      if (call.method == 'pinStateChanged') await refreshPinState();
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
  ShortcutPinResult? _availabilityFailure;
  ShortcutPinResult? get availabilityFailure => _availabilityFailure;
  Set<AppFeature> _pinned = {};
  Set<AppFeature> get pinned => Set.unmodifiable(_pinned);
  final Map<AppFeature, ShortcutPinResult> _pinResults = {};
  ShortcutPinResult? pinResult(AppFeature feature) => _pinned.contains(feature)
      ? ShortcutPinResult.pinned
      : _pinResults[feature] == ShortcutPinResult.pinned
      ? null
      : _pinResults[feature];
  int _pinStateRevision = 0;
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
      await refreshPinState();
    } on PlatformException {
      // A launcher may not provide pinning; deep links and static entries work.
    } on MissingPluginException {
      // Other platforms do not expose Android shortcuts.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshPinState();
  }

  Future<void> refreshPinState() async {
    if (_disposed || channel == null) return;
    final revision = ++_pinStateRevision;
    try {
      final state = await channel!.invokeMapMethod<String, dynamic>('pinState');
      if (_disposed || revision != _pinStateRevision) return;
      _supported = state?['supported'] == true;
      _availabilityFailure = switch (state?['error']) {
        'restricted' => ShortcutPinResult.restricted,
        'unavailable' => ShortcutPinResult.unavailable,
        _ => null,
      };
      _pinned = {
        for (final id in (state?['pinned'] as List? ?? const []))
          for (final feature in AppFeature.values)
            if (id == feature.name) feature,
      };
      for (final feature in _pinned) {
        _pinResults.remove(feature);
      }
      notifyListeners();
    } on PlatformException {
      if (!_disposed && revision == _pinStateRevision) {
        _supported = false;
        _pinned = {};
        _availabilityFailure = ShortcutPinResult.unavailable;
        notifyListeners();
      }
    } on MissingPluginException {
      if (!_disposed && revision == _pinStateRevision) {
        _supported = false;
        _pinned = {};
        _availabilityFailure = ShortcutPinResult.unsupported;
        notifyListeners();
      }
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
  Future<ShortcutPinResult> requestPin(AppFeature feature) async {
    if (_disposed || channel == null) return ShortcutPinResult.unsupported;
    await refreshPinState();
    if (_disposed || !_supported) {
      return _availabilityFailure ?? ShortcutPinResult.unsupported;
    }
    if (_pinned.contains(feature)) return ShortcutPinResult.pinned;
    ShortcutPinResult result;
    try {
      final value = await channel!.invokeMethod<String>(
        'pinFeature',
        feature.name,
      );
      result =
          ShortcutPinResult.values.where((r) => r.name == value).firstOrNull ??
          ShortcutPinResult.failed;
    } on PlatformException {
      result = ShortcutPinResult.failed;
    } on MissingPluginException {
      result = ShortcutPinResult.unsupported;
    }
    if (!_disposed) {
      _pinResults[feature] = result;
      await refreshPinState();
    }
    return _pinned.contains(feature) ? ShortcutPinResult.pinned : result;
  }

  /// Retained for callers that only need whether the system accepted a request.
  Future<bool> pin(AppFeature feature) async => const {
    ShortcutPinResult.requested,
    ShortcutPinResult.pinned,
  }.contains(await requestPin(feature));

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    profiles.removeListener(_scopeChanged);
    _session?.removeListener(_scopeChanged);
    channel?.setMethodCallHandler(null);
    super.dispose();
  }
}
