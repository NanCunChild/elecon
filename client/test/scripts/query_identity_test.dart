import 'dart:async';

import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/query_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PendingQuery extends StatefulWidget {
  const _PendingQuery({super.key});
  @override
  State<_PendingQuery> createState() => _PendingQueryState();
}

class _PendingQueryState extends State<_PendingQuery> {
  String result = 'empty';
  Future<void> load(Future<String> pending) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final value = await pending;
    if (isCurrentQuery(this, session, generation, source)) {
      setState(() => result = value);
    }
  }

  @override
  Widget build(BuildContext context) => Text(result);
}

void main() {
  testWidgets(
    'reusing a widget under another source rejects the old pending result',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final key = GlobalKey<_PendingQueryState>();
      Widget app(String id) => SessionScope(
        controller: session,
        child: MaterialApp(
          home: CapabilitySourceScope(
            source: CapabilitySource(packageId: id, digest: id),
            child: _PendingQuery(key: key),
          ),
        ),
      );
      await tester.pumpWidget(app('source-a'));
      final generation = session.trustedScriptViewGeneration;
      final oldResult = Completer<String>();
      final oldQuery = key.currentState!.load(oldResult.future);
      await tester.pumpWidget(app('source-b'));
      expect(session.trustedScriptViewGeneration, generation);
      await key.currentState!.load(Future.value('source-b result'));
      oldResult.complete('source-a stale result');
      await oldQuery;
      await tester.pump();
      expect(find.text('source-b result'), findsOneWidget);
      expect(find.textContaining('stale'), findsNothing);
      final state = key.currentState!;
      final disposedResult = Completer<String>();
      final disposedQuery = state.load(disposedResult.future);
      await tester.pumpWidget(const SizedBox.shrink());
      disposedResult.complete('disposed');
      await disposedQuery;
      expect(tester.takeException(), isNull);
    },
  );
}
