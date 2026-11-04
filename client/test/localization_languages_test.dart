import 'dart:convert';
import 'dart:io';

import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/home/classroom_timeline.dart';
import 'package:elecon/ui/i18n/locale_options.dart';
import 'package:elecon_contract/classroom_available.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'new languages cover the complete core catalog and preserve placeholders',
    () {
      final source =
          jsonDecode(File('lib/l10n/app_zh.arb').readAsStringSync()) as Map;
      final keys = source.keys.where((key) => !key.startsWith('@')).toSet();
      for (final language in ['uz', 'ru', 'fa']) {
        final target =
            jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
                as Map;
        expect(target['@@locale'], language);
        expect(target.keys.where((key) => !key.startsWith('@')).toSet(), keys);
        for (final key in keys) {
          expect(target[key], isA<String>(), reason: '$language/$key');
          expect(
            (target[key] as String).trim(),
            isNotEmpty,
            reason: '$language/$key',
          );
          final metadata = source['@$key'];
          if (metadata is! Map || metadata['placeholders'] is! Map) continue;
          for (final name in (metadata['placeholders'] as Map).keys) {
            expect(
              RegExp('\\{$name(?:\\}|,)').hasMatch(target[key]),
              isTrue,
              reason: '$language/$key must retain $name',
            );
          }
        }
      }
    },
  );

  for (final language in ['uz', 'ru', 'fa']) {
    testWidgets(
      '$language resolves native labels, direction and a consistent time axis',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        expect(resolveAppLocale(language), Locale(language));
        final l10n = await AppLocalizations.delegate.load(Locale(language));
        expect(appLocaleLabel(l10n, 'uz'), 'Oʻzbekcha');
        expect(appLocaleLabel(l10n, 'ru'), 'Русский');
        expect(appLocaleLabel(l10n, 'fa'), 'فارسی');
        final room = ClassroomAvailableItems(
          building: 'Synthetic',
          room: 'A1',
          intervals: [
            ClassroomAvailableItemsIntervals(
              startAt: '2026-11-03T08:00:00Z',
              endAt: '2026-11-03T10:00:00Z',
              status: 'available',
            ),
          ],
        );
        late TextDirection pageDirection;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                pageDirection = Directionality.of(context);
                return Scaffold(
                  body: SingleChildScrollView(
                    child: MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(1.3)),
                      child: ClassroomTimeline(
                        rooms: [room],
                        now: DateTime.parse('2026-11-03T09:00:00Z'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          pageDirection,
          language == 'fa' ? TextDirection.rtl : TextDirection.ltr,
        );
        final line = find.byKey(const ValueKey('classroom-current-time-line'));
        expect(line, findsOneWidget);
        // Narrow layouts reserve 128 for room attributes; the midpoint stays
        // on the bar even when the surrounding page uses RTL.
        expect(tester.getTopLeft(line).dx, closeTo((390 + 128) / 2, 1));
        expect(find.text(l10n.classroomOnlyFree), findsNothing);
        expect(find.text(l10n.classroomLocalTimeHint), findsOneWidget);
        expect(find.text(l10n.classroomAvailableStatus), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
