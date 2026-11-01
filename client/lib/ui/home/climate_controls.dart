/// ADR-046: native climate controls use ordinary capability requests.
library;

import 'package:flutter/foundation.dart';

bool get climateControlAvailable =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class ClimateControlException implements Exception {
  const ClimateControlException(this.code);
  final String code;
}

String climateCommandOutcome({required bool ok, Object? output}) {
  if (!ok || output is! Map) return 'unknown';
  return switch (output['status']) {
    'accepted' || 'applied' => 'accepted',
    'rejected' => 'rejected',
    _ => 'unknown',
  };
}

/// Produces only the complete finite target settings shown by the native UI.
/// Discovery describes optional coupled settings; no school JSON enters here.
Map<String, dynamic> climateTarget(
  Map<String, dynamic> device,
  String command,
  Object value,
) {
  if (!(device['commands'] as List).contains(command)) {
    throw const ClimateControlException('climate_invalid_command');
  }
  final settings = <String, dynamic>{};
  switch (command) {
    case 'temperature':
      if (value is! int ||
          value < (device['minTemperature'] as num) ||
          value > (device['maxTemperature'] as num)) {
        throw const ClimateControlException('climate_invalid_temperature');
      }
      settings['targetTemperature'] = value;
    case 'mode':
      if (!(device['modes'] as List).contains(value)) {
        throw const ClimateControlException('climate_invalid_mode');
      }
      final defaults = (device['modeDefaults'] as List)
          .where((e) => e is Map && e['mode'] == value)
          .toList();
      if (defaults.length != 1) {
        throw const ClimateControlException('climate_invalid_mode');
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
        throw const ClimateControlException('climate_invalid_mode');
      }
    case 'fanSpeed':
      if (!(device['fanSpeeds'] as List).contains(value)) {
        throw const ClimateControlException('climate_invalid_fan');
      }
      settings['fanSpeed'] = value;
      if (device['fanSpeedClearsTurbo'] == true) settings['turbo'] = false;
    case 'power':
    case 'verticalSwing':
    case 'turbo':
    case 'auxiliaryHeat':
      if (value is! bool) {
        throw const ClimateControlException('climate_invalid_value');
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
          throw const ClimateControlException('climate_invalid_fan');
        }
        settings['fanSpeed'] = 'auto';
      }
    default:
      throw const ClimateControlException('climate_invalid_command');
  }
  return Map.unmodifiable(settings);
}
