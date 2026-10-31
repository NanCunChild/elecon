/// 🔒 ADR-040 §4: native-only, one-use action admission; redlines #4/#5.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'manifest.dart';

bool get climateControlAvailable =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get climateActionForeground =>
    WidgetsBinding.instance.lifecycleState == null ||
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

/// ADR-030 §5 / ADR-040 §3: a completed JS call is not delivery evidence.
String climateCommandOutcome({
  required bool requestStarted,
  required bool ok,
  Object? output,
}) {
  if (!requestStarted) return 'rejected';
  if (!ok || output is! Map) return 'unknown';
  return switch (output['status']) {
    'accepted' || 'applied' => 'accepted',
    'rejected' => 'rejected',
    _ => 'unknown',
  };
}

class ScriptActionException implements Exception {
  const ScriptActionException(this.code);
  final String code;
}

/// Created by the session only after its fixed native confirmation completes.
/// JS never receives this object. The binding is checked again by the runtime.
class ScriptActionScope {
  ScriptActionScope({
    required this.package,
    required this.params,
    required this.isActive,
    Duration lifetime = const Duration(seconds: 30),
  }) : expiresAt = DateTime.now().add(lifetime),
       _paramsJson = jsonEncode(params);
  final ScriptPackage package;
  final Map<String, dynamic> params;
  final bool Function() isActive;
  final DateTime expiresAt;
  final String _paramsJson;
  bool _used = false;
  bool requestStarted = false;
  bool get active =>
      climateActionForeground &&
      isActive() &&
      DateTime.now().isBefore(expiresAt);

  void consume(
    ScriptPackage candidate,
    String capability,
    Map<String, dynamic> candidateParams,
  ) {
    if (!climateControlAvailable ||
        _used ||
        !active ||
        capability != 'climate.command' ||
        candidate.digest != package.digest ||
        jsonEncode(candidateParams) != _paramsJson ||
        package.manifest.action(capability) == null) {
      throw const ScriptActionException('action_not_authorized');
    }
    _used = true;
  }

  void reserve(String url, Map init) {
    final declaration = package.manifest.action('climate.command')!;
    if (!_used ||
        !active ||
        requestStarted ||
        url != declaration.url ||
        init['method'] != declaration.method ||
        init['redirect'] != 'error') {
      throw const ScriptActionException('action_request_denied');
    }
    // Reserve synchronously, including failed DNS/concurrent attempts.
    requestStarted = true;
  }
}

/// Produces only the complete finite target settings shown by the native UI.
/// Discovery describes optional coupled settings; no school JSON enters here.
Map<String, dynamic> climateTarget(
  Map<String, dynamic> device,
  String command,
  Object value,
) {
  if (!(device['commands'] as List).contains(command)) {
    throw const ScriptActionException('action_invalid_command');
  }
  final settings = <String, dynamic>{};
  switch (command) {
    case 'temperature':
      if (value is! int ||
          value < (device['minTemperature'] as num) ||
          value > (device['maxTemperature'] as num)) {
        throw const ScriptActionException('action_invalid_temperature');
      }
      settings['targetTemperature'] = value;
    case 'mode':
      if (!(device['modes'] as List).contains(value)) {
        throw const ScriptActionException('action_invalid_mode');
      }
      final defaults = (device['modeDefaults'] as List)
          .where((e) => e is Map && e['mode'] == value)
          .toList();
      if (defaults.length != 1) {
        throw const ScriptActionException('action_invalid_mode');
      }
      settings.addAll(Map<String, dynamic>.from(defaults.single as Map));
      final temperature = settings['targetTemperature'];
      if (temperature is! int ||
          temperature < (device['minTemperature'] as num) ||
          temperature > (device['maxTemperature'] as num) ||
          !(device['fanSpeeds'] as List).contains(settings['fanSpeed']) ||
          settings['turbo'] is! bool ||
          settings['auxiliaryHeat'] is! bool ||
          settings['indoorClean'] is! bool ||
          settings['outdoorClean'] is! bool ||
          settings.keys.any(
            (k) => !const {
              'mode',
              'targetTemperature',
              'fanSpeed',
              'turbo',
              'auxiliaryHeat',
              'indoorClean',
              'outdoorClean',
            }.contains(k),
          )) {
        throw const ScriptActionException('action_invalid_mode');
      }
    case 'fanSpeed':
      if (!(device['fanSpeeds'] as List).contains(value)) {
        throw const ScriptActionException('action_invalid_fan');
      }
      settings['fanSpeed'] = value;
      if (device['fanSpeedClearsTurbo'] == true) settings['turbo'] = false;
    case 'power':
    case 'verticalSwing':
    case 'turbo':
    case 'auxiliaryHeat':
      if (value is! bool) {
        throw const ScriptActionException('action_invalid_value');
      }
      settings[command] = value;
      if (command == 'power' &&
          !value &&
          device['powerOffClearsAuxiliaryHeat'] == true) {
        settings['auxiliaryHeat'] = false;
      }
      if (command == 'power' &&
          !value &&
          device['powerOffClearsCleaning'] == true) {
        settings['indoorClean'] = false;
        settings['outdoorClean'] = false;
      }
      if (command == 'turbo' && value && device['turboUsesAutoFan'] == true) {
        if (!(device['fanSpeeds'] as List).contains('auto')) {
          throw const ScriptActionException('action_invalid_fan');
        }
        settings['fanSpeed'] = 'auto';
      }
    default:
      throw const ScriptActionException('action_invalid_command');
  }
  return Map.unmodifiable(settings);
}
