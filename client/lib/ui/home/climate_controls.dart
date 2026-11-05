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

/// Availability follows the requested operation, never unrelated device fields.
/// Missing metadata disables that operation; it cannot expand the command set.
bool climateCommandReady(
  Map<String, dynamic> device,
  Map<String, dynamic>? state,
  String command,
) {
  if (state == null || state['deviceId'] != device['deviceId']) return false;
  final key = command == 'temperature' ? 'targetTemperature' : command;
  final value = state[key];
  if (value == null) return false;
  try {
    climateTarget(device, command, value);
    return true;
  } on ClimateControlException {
    return false;
  }
}

bool _contains(Object? values, Object? value) =>
    values is List && values.contains(value);

bool _temperatureInRange(Map<String, dynamic> device, Object? value) {
  final low = device['minTemperature'], high = device['maxTemperature'];
  return value is int &&
      low is int &&
      high is int &&
      low >= 16 &&
      high <= 32 &&
      low <= high &&
      value >= low &&
      value <= high;
}

/// Produces only the complete finite target settings shown by the native UI.
/// Discovery describes optional coupled settings; no school JSON enters here.
Map<String, dynamic> climateTarget(
  Map<String, dynamic> device,
  String command,
  Object value,
) {
  if (!_contains(device['commands'], command)) {
    throw const ClimateControlException('climate_invalid_command');
  }
  final settings = <String, dynamic>{};
  switch (command) {
    case 'temperature':
      if (!_temperatureInRange(device, value)) {
        throw const ClimateControlException('climate_invalid_temperature');
      }
      settings['targetTemperature'] = value;
    case 'mode':
      if (!_contains(device['modes'], value) ||
          device['modeDefaults'] is! List) {
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
      if (!_temperatureInRange(device, temperature) ||
          !_contains(device['fanSpeeds'], settings['fanSpeed']) ||
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
      if (!_contains(device['fanSpeeds'], value)) {
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
        if (!_contains(device['fanSpeeds'], 'auto')) {
          throw const ClimateControlException('climate_invalid_fan');
        }
        settings['fanSpeed'] = 'auto';
      }
    default:
      throw const ClimateControlException('climate_invalid_command');
  }
  return Map.unmodifiable(settings);
}
