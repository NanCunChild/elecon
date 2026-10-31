// Synthetic device capabilities; no network, account or real hardware.
import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';

const syntheticDeviceId = 'SYNTHETIC-DEVICE';
Map<String, dynamic> syntheticClimateDevice() => {
  'deviceId': syntheticDeviceId,
  'label': 'Synthetic room',
  'minTemperature': 18,
  'maxTemperature': 32,
  'modes': ['fan', 'heat', 'cool', 'dry', 'auto'],
  'fanSpeeds': ['auto', 'silent', 'low', 'medium', 'high'],
  'commands': [
    'power',
    'temperature',
    'mode',
    'fanSpeed',
    'verticalSwing',
    'turbo',
    'auxiliaryHeat',
  ],
  'modeDefaults': [
    for (final mode in ['fan', 'heat', 'cool', 'dry', 'auto'])
      {
        'mode': mode,
        'targetTemperature': mode == 'heat'
            ? 23
            : mode == 'cool'
            ? 26
            : 25,
        'fanSpeed': mode == 'fan' ? 'medium' : 'auto',
        'turbo': false,
        'auxiliaryHeat': false,
        'indoorClean': false,
        'outdoorClean': false,
      },
  ],
  'powerOffClearsAuxiliaryHeat': true,
  'powerOffClearsCleaning': true,
  'fanSpeedClearsTurbo': true,
  'turboUsesAutoFan': true,
};
ScriptPackage syntheticClimatePackage({
  String id = 'climate-synthetic',
  String version = '1.0.0',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 5,
      'id': id,
      'schoolId': id,
      'version': version,
      'name': 'Synthetic school',
      'network': {
        'origins': ['https://device.example.invalid'],
      },
      'browser': false,
      'capabilities': [
        for (final capability in [
          'profile.me',
          'climate.devices',
          'climate.status',
          'climate.command',
        ])
          {
            'id': capability,
            'schema': 'elecon.$capability',
            'schemaVersion': '1.0',
          },
      ],
      'actions': [
        {
          'capability': 'climate.command',
          'method': 'POST',
          'url': 'https://device.example.invalid/command',
        },
      ],
    },
    'source':
        '''export const capabilities={
 'profile.me':async ctx=>{await ctx.credentials.set('binding','synthetic');return {}},
 'climate.devices':async ctx=>(await ctx.credentials.get('binding'))?(${jsonEncode({
          'items': [syntheticClimateDevice()],
        })}):{items:[]},
 'climate.status':async(ctx,p)=>({deviceId:p.deviceId,power:false,mode:'cool',fanSpeed:'auto',targetTemperature:26,verticalSwing:false,turbo:false,auxiliaryHeat:false}),
 // A no-op script must never be reported as having physically sent a command.
 'climate.command':async()=>({status:'accepted'})
 };''',
  }),
);
