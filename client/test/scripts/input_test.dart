// Synthetic SDK 3 forms through the actual background QuickJS; no school IO.
import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/input.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

const form = <String, Object?>{
  'title': 'Synthetic form',
  'fields': [
    {'id': 'account', 'label': 'Account'},
    {'id': 'password', 'label': 'Password', 'type': 'password'},
    {
      'id': 'campus',
      'label': 'Campus',
      'type': 'select',
      'options': [
        {'label': 'North', 'value': 'north'},
      ],
    },
    {'id': 'note', 'label': 'Optional', 'required': false},
  ],
};

ScriptPackage package(String body, {int sdk = 3}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': sdk,
      'id': 'input.synthetic',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic school',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
    },
    'source': 'export const capabilities={"notice.list":async(ctx)=>{$body}};',
  }),
);
const output = 'return {items:[],sourceSystem:"done"};';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bounded forms validate text, secret, choices and optional empty fields',
    () {
      final request = ScriptInputRequest.fromJson(form);
      expect(request.fields, hasLength(4));
      expect(
        request.validateResult({
          'account': 'SYNTHETIC',
          'password': ' secret ',
          'campus': 'north',
          'note': '',
        }),
        isNotNull,
      );
      expect(request.validateResult(null), isNull);
      for (final invalid in [
        {
          'account': 'SYNTHETIC',
          'password': 'secret',
          'campus': 'south',
          'note': '',
        },
        {'account': '', 'password': 'secret', 'campus': 'north', 'note': ''},
        {'account': 'SYNTHETIC', 'password': 'secret', 'campus': 'north'},
        {
          'account': 'SYNTHETIC',
          'password': 'secret',
          'campus': 'north',
          'note': '',
          'extra': '',
        },
        {'account': 42, 'password': 'secret', 'campus': 'north', 'note': ''},
        {
          'account': 'SYNTHETIC\n',
          'password': 'secret',
          'campus': 'north',
          'note': '',
        },
      ]) {
        expect(
          () => request.validateResult(invalid),
          throwsA(isA<ScriptInputException>()),
        );
      }
    },
  );
  test('malformed and oversized requests fail before presentation', () {
    for (final invalid in [
      {},
      {'title': 'T', 'fields': []},
      {
        'title': 'T',
        'fields': List.filled(9, {'id': 'x', 'label': 'X'}),
      },
      {
        'title': 'T',
        'fields': [
          {'id': 'x', 'label': 'X'},
          {'id': 'x', 'label': 'Y'},
        ],
      },
      {
        'title': 'T',
        'fields': [
          {
            'id': 'x',
            'label': 'X',
            'type': 'password',
            'initialValue': 'secret',
          },
        ],
      },
      {
        'title': 'T',
        'fields': [
          {
            'id': 'x',
            'label': 'X',
            'type': 'select',
            'options': [
              {'label': 'A', 'value': 'a'},
              {'label': 'B', 'value': 'a'},
            ],
          },
        ],
      },
      {
        'title': 'T',
        'fields': [
          {'id': 'x', 'label': 'X', 'type': 'html'},
        ],
      },
      {
        'title': 'T',
        'fields': [
          {'id': 'x', 'label': 'X', 'maxLength': 4097},
        ],
      },
      {
        'title': 'T',
        'fields': [
          {'id': 'x', 'label': 'X', 'options': []},
        ],
      },
      {
        'title': 'T',
        'fields': [
          {'id': 'x', 'label': 'X', 'required': 'true'},
        ],
      },
      {
        'title': 'T',
        'fields': [
          {'id': 'x', 'label': 'X'},
        ],
        'onSubmit': 'code',
      },
      {
        'title': 'T',
        'message': 'x' * 33000,
        'fields': [
          {'id': 'x', 'label': 'X'},
        ],
      },
    ]) {
      expect(
        () => ScriptInputRequest.fromJson(invalid),
        throwsA(isA<ScriptInputException>()),
      );
    }
    expect(
      () => ScriptInputRequest.decode('[]'),
      throwsA(isA<ScriptInputException>()),
    );
  });

  late CredentialStore store;
  late ScriptCredentials credentials;
  setUp(() {
    store = CredentialStore(store: InMemorySecureStore(releaseMode: false));
    credentials = ScriptCredentials(
      store: store,
      schoolId: 'synthetic',
      scriptId: 'input.synthetic',
      sdkVersion: 3,
    );
  });
  Future<Object?> run(
    ScriptPackage p, {
    ScriptInputCall? input,
    Duration timeout = const Duration(seconds: 5),
    bool Function()? active,
  }) => const TrustedScriptRuntime().run(
    package: p,
    capability: 'notice.list',
    credentials: credentials,
    fetch: (_, _) async => throw StateError('input has no network'),
    inputCall: input,
    wallTimeout: timeout,
    isActive: active,
  );

  test(
    'real QuickJS submits once, protects input logs and leaves persistence to script',
    () async {
      final logs = <String>[];
      final p = package(
        'const r=await ctx.ui.requestInput(${jsonEncode(form)});ctx.log("info",r.account+" "+r.password);await ctx.credentials.set("answer",r.account);$output',
      );
      var calls = 0;
      final result = await const TrustedScriptRuntime().run(
        package: p,
        capability: 'notice.list',
        credentials: credentials,
        fetch: (_, _) async => throw StateError('no network'),
        inputCall: (request) async {
          calls++;
          expect(request.fields[1].type, ScriptInputType.password);
          return {
            'account': 'SYNTHETIC-INPUT',
            'password': 'SYNTHETIC-SECRET',
            'campus': 'north',
            'note': '',
          };
        },
        onLog: (_, m) => logs.add(m),
      );
      expect(result, {'items': [], 'sourceSystem': 'done'});
      expect(calls, 1);
      expect(credentials.get('answer')!['value'], 'SYNTHETIC-INPUT');
      expect(credentials.get('answer')!['namespace'], 'input.synthetic');
      expect(logs.join(), isNot(contains('SYNTHETIC-INPUT')));
      expect(logs.join(), isNot(contains('SYNTHETIC-SECRET')));
    },
  );
  test('cancel returns null without automatically writing credentials', () async {
    final p = package(
      'const r=await ctx.ui.requestInput(${jsonEncode(form)});if(r!==null)throw new Error("expected cancellation");$output',
    );
    await run(p, input: (_) async => null);
    expect(store.list(), isEmpty);
  });
  test(
    'SDK 3 linearizes long concatenated request values at the real QuickJS boundary',
    () async {
      final p = package(
        'let text="";for(let i=0;i<1024;i++)text+="x";const r=await ctx.ui.requestInput({title:"T",fields:[{id:"answer",label:"Answer",maxLength:2048,initialValue:text}]});await ctx.credentials.set("answer",r.answer);$output',
      );
      await run(
        p,
        input: (request) async {
          expect(request.fields.single.initialValue, 'x' * 1024);
          return {'answer': request.fields.single.initialValue!};
        },
      );
      expect(credentials.get('answer')!['value'], 'x' * 1024);
    },
  );
  test(
    'invalid presenter response is rejected and its values never reach logs',
    () async {
      final p = package(
        'await ctx.ui.requestInput(${jsonEncode(form)});$output',
      );
      await expectLater(
        run(p, input: (_) async => {'wrong': 'SYNTHETIC-SECRET'}),
        throwsA(
          isA<ScriptRunException>().having(
            (e) => e.code,
            'code',
            'input_invalid_result',
          ),
        ),
      );
      expect(store.list(), isEmpty);
    },
  );
  test('missing presenter is reported only when requested', () async {
    await run(package(output));
    await expectLater(
      run(package('await ctx.ui.requestInput(${jsonEncode(form)});$output')),
      throwsA(
        isA<ScriptRunException>().having(
          (e) => e.code,
          'code',
          'input_unavailable',
        ),
      ),
    );
  });
  test('parallel prompts are rejected without creating a second form', () async {
    var calls = 0;
    await expectLater(
      run(
        package(
          'await Promise.all([ctx.ui.requestInput(${jsonEncode(form)}),ctx.ui.requestInput(${jsonEncode(form)})]);$output',
        ),
        input: (_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return null;
        },
      ),
      throwsA(
        isA<ScriptRunException>().having((e) => e.code, 'code', 'input_busy'),
      ),
    );
    expect(calls, 1);
  });
  test(
    'caught prompt limits still stop the invocation after eight forms',
    () async {
      var calls = 0;
      await expectLater(
        run(
          package(
            'for(let i=0;i<10;i++){try{await ctx.ui.requestInput(${jsonEncode(form)})}catch(_){}}$output',
          ),
          input: (_) async {
            calls++;
            return null;
          },
        ),
        throwsA(
          isA<ScriptRunException>().having(
            (e) => e.code,
            'code',
            'input_limit',
          ),
        ),
      );
      expect(calls, 8);
    },
  );
  test(
    'cancellation and timeout reject late form submissions before writes',
    () async {
      for (final cancel in [false, true]) {
        var active = true;
        final entered = Completer<void>(), value = Completer<Object?>();
        final p = package(
          'await ctx.ui.requestInput(${jsonEncode(form)});await ctx.credentials.set("late","SYNTHETIC");$output',
        );
        final pending = run(
          p,
          input: (_) {
            entered.complete();
            return value.future;
          },
          timeout: const Duration(milliseconds: 200),
          active: () => active,
        );
        final checked = expectLater(
          pending,
          throwsA(isA<ScriptRunException>()),
        );
        await entered.future;
        if (cancel) active = false;
        await checked;
        value.complete({
          'account': 'SYNTHETIC',
          'password': 'SYNTHETIC',
          'campus': 'north',
          'note': '',
        });
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(store.list(), isEmpty);
      }
    },
  );
  test(
    'SDK 1/2 do not expose ui and SDK 3 preserves qualified credential addresses',
    () async {
      for (final sdk in [1, 2]) {
        final facade = ScriptCredentials(
          store: store,
          schoolId: 'synthetic',
          scriptId: 'input.synthetic',
          sdkVersion: sdk,
        );
        final result = await const TrustedScriptRuntime().run(
          package: package(
            'return {items:[],sourceSystem:typeof ctx.ui};',
            sdk: sdk,
          ),
          capability: 'notice.list',
          credentials: facade,
          fetch: (_, _) async => throw StateError('no IO'),
        );
        expect((result as Map)['sourceSystem'], 'undefined');
      }
    },
  );
}
