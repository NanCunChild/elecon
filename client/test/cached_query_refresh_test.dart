import 'dart:async';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/query_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class CachedSession extends SessionController {
  CachedSession({required this.stale});
  final bool stale;
  int attempts = 0;
  ScriptRunCancellation? token;
  final pending = Completer<void>();
  Future<ScriptCachedData?> latestCachedCapability(
    String capability, {
    String? packageId,
    String? expectedDigest,
  }) async => ScriptCachedData(
    data: 'Offline content',
    fetchedAt: DateTime.utc(2026, 1, 1),
    isStale: stale,
    params: const {'term': 'synthetic'},
    freshUntil: DateTime.now().add(Duration(seconds: stale ? -1 : 60)),
  );
  Future<void> refreshCachedQuery(
    String capability, {
    required Map<String, dynamic> params,
    String? packageId,
    String? expectedDigest,
    ScriptRunCancellation? cancellation,
  }) async {
    attempts++;
    token = cancellation;
    expect(params, {'term': 'synthetic'});
    await pending.future;
  }
}

class CacheView extends StatefulWidget {
  const CacheView({super.key});
  @override
  State<CacheView> createState() => _CacheViewState();
}

class _CacheViewState extends State<CacheView>
    with CachedQuerySection<CacheView, String> {
  @override
  Future<ScriptCachedData?> readCache() =>
      (cacheSession! as CachedSession).latestCachedCapability(cacheCapability);
  @override
  Future<void> refreshCache(
    ScriptCachedData cached,
    ScriptRunCancellation token,
  ) => (cacheSession! as CachedSession).refreshCachedQuery(
    cacheCapability,
    params: cached.params,
    cancellation: token,
  );
  String? data;
  @override
  String get cacheCapability => 'notice.list';
  @override
  String? decodeCache(Object? raw) => raw as String?;
  @override
  void applyCache(String value) => data = value;
  @override
  void clearCache() => data = null;
  @override
  Widget build(BuildContext context) => Text(data ?? 'Loading');
}

void main() {
  for (final stale in [true, false]) {
    testWidgets('restores content and refreshes only stale=$stale', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final session = CachedSession(stale: stale);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionScope(controller: session, child: const CacheView()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Offline content'), findsOneWidget);
      expect(session.attempts, stale ? 1 : 0);
      session.pending.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(session.attempts, stale ? 1 : 0);
      expect(find.text('Offline content'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('leaving cancels only this cache consumer', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final session = CachedSession(stale: true);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionScope(controller: session, child: const CacheView()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final token = session.token!;
    await tester.pumpWidget(const SizedBox());
    expect(token.isCancelled, isTrue);
    session.pending.complete();
    await tester.pump();
  });
}
