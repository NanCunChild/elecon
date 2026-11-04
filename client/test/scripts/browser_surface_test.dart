import 'dart:async';

import 'package:elecon/core/scripts/browser.dart';
import 'package:elecon/core/scripts/network_policy.dart';
import 'package:elecon/ui/scripts/script_browser_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const labels = ScriptBrowserPageLabels(
  title: 'School form',
  close: 'Close school form',
  loading: 'Loading',
  signingIn: 'Working',
  blocked: 'Blocked',
  failed: 'Failed',
  unavailable: 'Unavailable',
);

class _Driver implements ScriptBrowserDriver {
  _Driver(this.bridge);
  final ScriptBrowserBridge bridge;
  Completer<void>? cleanup;
  int closes = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> loadUrl(String url) async {
    bridge.navigationStarted(url);
    bridge.navigationFinished(url);
  }

  @override
  Future<void> evaluate(String source) async {}
  @override
  Future<void> clearFocus() async {}
  @override
  Future<List<Map<String, Object?>>> cookies(Uri url) async => [];
  @override
  Future<void> setCookies(
    String url,
    List<Map<String, Object?>> cookies,
  ) async {}
  @override
  Future<void> stopLoading() async {}
  @override
  Future<void> close() async {
    closes++;
    await cleanup?.future;
  }
}

ScriptBrowserBridge bridge({bool available = true}) => ScriptBrowserBridge(
  policy: ScriptNetworkPolicy.fromJson({
    'origins': ['https://school.example'],
  }),
  available: available,
);

class _MountProbe extends StatefulWidget {
  const _MountProbe({required this.onMount, required this.onDispose});
  final VoidCallback onMount;
  final VoidCallback onDispose;
  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  testWidgets(
    'loading, origin and failure rows preserve the native document instance',
    (tester) async {
      final browser = bridge();
      var mounts = 0;
      var disposals = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScriptBrowserSurface(
              bridge: browser,
              labels: labels,
              platformViewBuilder: (_, _) => _MountProbe(
                onMount: () => mounts++,
                onDispose: () => disposals++,
              ),
            ),
          ),
        ),
      );
      expect(mounts, 1);
      browser.navigationStarted('https://school.example/form');
      await tester.pump();
      expect(mounts, 1);
      browser.navigationFinished('https://school.example/form');
      await tester.pump();
      expect(mounts, 1);
      browser.reportError();
      await tester.pump();
      expect(mounts, 1);
      expect(disposals, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(disposals, 1);
      expect(ScriptBrowserLease.busy, false);
    },
  );
  testWidgets(
    'embedded content keeps native controls outside its busy mask and closes without popping',
    (tester) async {
      final browser = bridge();
      final native = _Driver(browser);
      browser.attach(native);
      var closed = 0;
      var surroundingTaps = 0;
      var schoolTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => surroundingTaps++,
                  child: const Text('Native action'),
                ),
                Expanded(
                  child: ScriptBrowserSurface(
                    bridge: browser,
                    labels: labels,
                    onClosed: () => closed++,
                    platformViewBuilder: (_, _) => Center(
                      child: TextButton(
                        onPressed: () => schoolTaps++,
                        child: const Text('School input'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await browser.open(
        'https://school.example/form?ticket=SYNTHETIC_PRIVATE',
      );
      await tester.pump();
      expect(find.text('https://school.example'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC_PRIVATE'), findsNothing);
      await browser.call('setBusy', {'busy': true});
      await tester.pump();
      await tester.tap(find.text('School input'), warnIfMissed: false);
      await tester.tap(find.text('Native action'));
      expect(schoolTaps, 0);
      expect(surroundingTaps, 1);
      await tester.tap(find.byTooltip(labels.close));
      await tester.pump();
      expect(closed, 1);
      expect(native.closes, 1);
      expect(ScriptBrowserLease.busy, isFalse);
      expect(find.text('Native action'), findsOneWidget);
      expect(find.text('School input'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(native.closes, 1);
    },
  );

  testWidgets(
    'replacement waits for old cleanup before constructing the next native view',
    (tester) async {
      final first = bridge();
      final firstDriver = _Driver(first)..cleanup = Completer<void>();
      final second = bridge();
      final secondDriver = _Driver(second);
      first.attach(firstDriver);
      var selected = first;
      var secondViews = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return ScriptBrowserSurface(
                  bridge: selected,
                  labels: labels,
                  platformViewBuilder: (_, current) {
                    if (identical(current, second)) {
                      secondViews++;
                      if (secondViews == 1) second.attach(secondDriver);
                    }
                    return const SizedBox();
                  },
                );
              },
            ),
          ),
        ),
      );
      await first.open('https://school.example/form');
      rebuild(() => selected = second);
      await tester.pump();
      expect(secondViews, 0);
      expect(ScriptBrowserLease.busy, isTrue);
      firstDriver.cleanup!.complete();
      await tester.pump();
      await tester.pump();
      expect(secondViews, 1);
      expect(firstDriver.closes, 1);
      expect(first.navigationStarted('https://school.example/late'), isFalse);
      expect(second.state.value.phase, ScriptBrowserPhase.waiting);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(secondDriver.closes, 1);
      expect(ScriptBrowserLease.busy, isFalse);
    },
  );

  testWidgets(
    'unavailable and conflicting leases never construct a native view',
    (tester) async {
      for (final available in [false, true]) {
        final lease = available
            ? ScriptBrowserLease.tryAcquire('other-owner')
            : null;
        final browser = bridge(available: available);
        var created = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ScriptBrowserSurface(
                bridge: browser,
                labels: labels,
                platformViewBuilder: (_, _) {
                  created = true;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        expect(created, isFalse);
        expect(find.text(labels.unavailable), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(ScriptBrowserLease.busy, available);
        lease?.release();
      }
    },
  );
}
