import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/scripts/script_install_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'declared_tunnel_test.dart' show declaredPackage;

void main() {
  testWidgets('installation review exposes the fixed tunnel and dependencies', (
    tester,
  ) async {
    final package = declaredPackage();
    bool? approved;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                approved = await confirmScriptInstall(context, [package]);
              },
              child: const Text('Review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('https://gateway.example.invalid'), findsWidgets);
    expect(
      find.textContaining('Requires connection account:'),
      findsNWidgets(2),
    );
    expect(approved, isNull);
    final details = find.byKey(const ValueKey('tunnel-review-vpn'));
    await tester.ensureVisible(details);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.text('ab' * 32), findsOneWidget);
    expect(
      find.text('Determined by the school sign-in page or gateway'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(approved, isFalse);
  });
}
