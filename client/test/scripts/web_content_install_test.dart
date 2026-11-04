import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/scripts/script_install_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'web_content_test.dart' as fixture;

void main() {
  testWidgets(
    'package review includes the exact authorized HTML without running it',
    (tester) async {
      final package = fixture.package("throw new Error('must not execute');");
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
      expect(find.text('Form · form'), findsOneWidget);
      expect(find.text('Other · other'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(find.text('Form · form'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        package.manifest.webContent.first.html,
      );
      expect(approved, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(approved, false);
    },
  );
}
