/// DevLog UI/clipboard credential boundary regression.
library;

import 'package:elecon/core/debug/dev_log.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/settings/dev_log_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('UI and clipboard only receive sanitized entries', (
    tester,
  ) async {
    const secret = 'SECRET_MATERIAL_123456789';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final log = DevLog();
    log.log(
      DevLogCategory.network,
      'failed https://u:p@example.edu/x;jsessionid=$secret?ticket=$secret '
      'Cookie: sid=$secret',
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DevLogPage(log: log),
      ),
    );
    await tester.pump();

    expect(find.textContaining(secret), findsNothing);
    expect(find.textContaining('u:p'), findsNothing);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.devLogCopyVisible));
    await tester.pump();
    expect(copied, isNotNull);
    expect(copied, isNot(contains(secret)));
    expect(copied, isNot(contains('u:p')));
  });
}
