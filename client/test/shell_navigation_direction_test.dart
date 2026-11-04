import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('shell tabs follow locale direction in ${brightness.name}', (
      tester,
    ) async {
      final session = SessionController();
      final theme = ThemeController();
      addTearDown(session.dispose);
      addTearDown(theme.dispose);

      Future<void> showLocale(String language) async {
        await tester.pumpWidget(
          ThemeScope(
            controller: theme,
            child: SessionScope(
              controller: session,
              child: MaterialApp(
                locale: Locale(language),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                theme: ThemeData(brightness: brightness),
                home: MainShell(
                  loadHomeSnapshot: () async => throw StateError('synthetic'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      void expectIndicatorAt(IconData icon) {
        final indicator = find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is ShapeDecoration &&
              (widget.decoration as ShapeDecoration).color ==
                  Theme.of(
                    tester.element(find.byType(MainShell)),
                  ).colorScheme.secondaryContainer,
        );
        expect(indicator, findsOneWidget);
        expect(
          tester.getCenter(indicator).dx,
          closeTo(tester.getCenter(find.byIcon(icon)).dx, 0.1),
        );
      }

      await showLocale('en');
      expectIndicatorAt(Icons.home);
      expect(
        tester.getCenter(find.byIcon(Icons.home)).dx,
        lessThan(tester.getCenter(find.byIcon(Icons.settings_outlined)).dx),
      );

      // Keep the same shell mounted while switching from LTR to RTL.
      await showLocale('fa');
      expectIndicatorAt(Icons.home);
      expect(
        tester.getCenter(find.byIcon(Icons.home)).dx,
        greaterThan(tester.getCenter(find.byIcon(Icons.settings_outlined)).dx),
      );
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expectIndicatorAt(Icons.settings);
      final l10n = AppLocalizations.of(tester.element(find.byType(MainShell)));
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text(l10n.settingsTitle),
        ),
        findsOneWidget,
      );

      // Selection also survives switching the layout back to LTR.
      await showLocale('en');
      expectIndicatorAt(Icons.settings);
      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expectIndicatorAt(Icons.home);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
