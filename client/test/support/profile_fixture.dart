import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';

ScriptPackage school() => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': 'profile.synthetic',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic login',
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
      'home': [
        {'capability': 'notice.list', 'ttlSeconds': 300},
      ],
    },
    'source': '''export const capabilities={'notice.list':async(ctx,params)=>{
    if(params.value) await ctx.credentials.set('session',params.value);
    const saved=await ctx.credentials.get('session');
    return {items:[],sourceSystem:saved?saved.value:'EMPTY'};
  }};''',
  }),
);
