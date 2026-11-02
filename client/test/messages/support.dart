import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';

ScriptPackage chatPackage({
  String version = '1.0.0',
  String sendStatus = 'sent',
  bool offlineAfterSend = false,
  List<Map<String, dynamic>>? conversationRows,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 9,
      'id': 'synthetic-chat',
      'schoolId': 'synthetic-school',
      'version': version,
      'name': 'Synthetic source',
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        for (final cap in [
          'messages.session',
          'messages.conversations',
          'messages.history',
          'messages.send',
        ])
          {
            'id': cap,
            'schema': 'elecon.$cap',
            'schemaVersion': cap == 'messages.conversations' ? '1.1' : '1.0',
          },
      ],
    },
    'source':
        '''
    const who = ctx => ({serviceId:'synthetic',accountId:'synthetic-account',accountLabel:'Synthetic account',fetchedAt:new Date(ctx.now()).toISOString()});
    export const capabilities = {
      'messages.session': async (ctx,p) => {
        if((await ctx.credentials.get('offline'))?.value === 'yes') throw new Error('synthetic_offline');
        if(p.operation === 'logout') await ctx.credentials.set('session','out');
        if(p.operation === 'login') await ctx.credentials.set('session','in');
        return (await ctx.credentials.get('session'))?.value === 'out'
          ? {serviceId:'synthetic',serviceName:'Synthetic service',status:'signedOut'}
          : {...who(ctx),serviceName:'Synthetic service',status:'authenticated'};
      },
      'messages.conversations': async ctx => ({...who(ctx),coverage:'complete',items:${conversationRows == null ? '''[
        {conversationId:'group-1',conversationKind:'group',title:'Synthetic group'},
        {conversationId:'group-1',conversationKind:'direct',title:'Synthetic peer'}
      ]''' : jsonEncode(conversationRows)}}),
      'messages.history': async (ctx,p) => {
        if((await ctx.credentials.get('offline'))?.value === 'yes') throw new Error('synthetic_offline');
        if(p.cursor === 'wait') {ctx.log('info','synthetic_waiting');await new Promise(resolve=>setTimeout(resolve,10000));}
        if(p.cursor === 'expired') {const e=new Error('authentication_required');e.code='authentication_required';throw e;}
        return {...who(ctx),conversationId:p.conversationId,conversationKind:p.conversationKind,
          hasMore:!p.cursor,...(!p.cursor?{nextCursor:'older'}:{}),recalledIds:[],items:[
          {id:p.cursor?'100':'200',kind:'homework',text:p.cursor?'Synthetic older message':'Synthetic homework summary',
            direction:'incoming',senderLabel:'Synthetic sender',sentAt:p.cursor?'2026-10-31T08:00:00Z':'2026-11-01T08:00:00Z'}
        ]};
      },
      'messages.send': async (ctx,p) => {ctx.log('info','synthetic_send_once');
        if($offlineAfterSend) await ctx.credentials.set('offline','yes');return {
        ...who(ctx),conversationId:p.conversationId,conversationKind:p.conversationKind,
        clientId:p.clientId,status:'$sendStatus',...('$sendStatus'==='sent'?{messageId:'999',sentAt:new Date(ctx.now()).toISOString()}:{}),
      };}
    };
  ''',
  }),
);

const chatTarget = {
  'accountId': 'synthetic-account',
  'conversationId': 'group-1',
  'conversationKind': 'group',
};
Future<void> prepareChat(
  SessionController session,
  ScriptPackage package,
) async {
  await session.installTrustedScript(package, approvedDigest: package.digest);
  await session.selectTrustedScriptSchool(package.manifest.id);
  final result = await session.runTrustedScript(
    package.manifest.id,
    'messages.session',
    params: {'operation': 'status'},
  );
  if (!result.ok) throw StateError('synthetic_login_failed');
}
