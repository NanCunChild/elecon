import 'dart:convert';

import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/data_cache.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage schedulePackage({
  String schema = '1.2',
  String version = '1.0.0',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': 'synthetic-schedule',
      'schoolId': 'synthetic',
      'version': version,
      'name': 'Synthetic',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'schedule.week',
          'schema': 'elecon.schedule.week',
          'schemaVersion': schema,
        },
      ],
      'home': [
        {'capability': 'schedule.week', 'ttlSeconds': 30},
      ],
    },
    'source': 'export const capabilities={};',
  }),
);

Map<String, dynamic> termSnapshot() => {
  'term': 'synthetic-term',
  'week': 1,
  'days': [],
  'weekType': 'teaching',
  'termWeeks': [
    for (var week = 1; week <= 3; week++)
      {
        'week': week,
        'teachingWeekStart':
            '2026-11-${(2 + (week - 1) * 7).toString().padLeft(2, '0')}',
        'teachingWeekEnd':
            '2026-11-${(8 + (week - 1) * 7).toString().padLeft(2, '0')}',
        'days': [],
        if (week == 2) 'weekType': 'holiday',
      },
  ],
};

void main() {
  test(
    '1.3 term projection keeps rest hints, school zone and original age',
    () {
      var now = 1000000;
      final cache = ScriptDataCache(CredentialStore(), now: () => now);
      final package = schedulePackage(schema: '1.3');
      final data = {
        ...termSnapshot(),
        'timeZone': 'Asia/Shanghai',
        'timeSegments': [
          {'label': 'Morning', 'timeStart': '10:00', 'timeEnd': '12:00'},
          {'label': 'Afternoon', 'timeStart': '14:00', 'timeEnd': '16:00'},
        ],
        'breakSegments': [
          {'label': 'Lunch break', 'timeStart': '12:00', 'timeEnd': '14:00'},
        ],
      };
      expect(cache.write(package, 'schedule.week', {}, data), isTrue);
      final home = cache.read(package, 'schedule.week')!;
      now += 31000;
      final week = cache.read(package, 'schedule.week', params: {'week': 2})!;
      expect((week.data as Map)['week'], 2);
      expect((week.data as Map)['breakSegments'], data['breakSegments']);
      expect((week.data as Map)['timeZone'], 'Asia/Shanghai');
      expect(week.fetchedAt, home.fetchedAt);
      expect(week.freshUntil, home.freshUntil);
      expect(week.isStale, isTrue);
    },
  );

  test(
    'term projections preserve source time, TTL, empty weeks and default home query',
    () {
      var now = 1000000;
      final cache = ScriptDataCache(CredentialStore(), now: () => now);
      final package = schedulePackage();
      final data = termSnapshot();
      expect(cache.write(package, 'schedule.week', {}, data), isTrue);
      final home = cache.read(package, 'schedule.week')!;
      final week = cache.read(
        package,
        'schedule.week',
        params: {'week': 2, 'term': 'synthetic-term'},
      )!;
      expect((week.data as Map)['week'], 2);
      expect((week.data as Map)['weekType'], 'holiday');
      expect(week.fetchedAt, home.fetchedAt);
      expect(week.freshUntil, home.freshUntil);
      expect(week.isStale, isFalse);
      expect((cache.read(package, 'schedule.week')!.data as Map)['week'], 1);
      now += 30000;
      final stale = cache.read(package, 'schedule.week', params: {'week': 3})!;
      expect(stale.isStale, isTrue);
      expect(stale.fetchedAt, home.fetchedAt);
      expect((stale.data as Map).containsKey('weekType'), isFalse);
      now += ScriptDataCache.retentionMs;
      expect(
        cache.read(package, 'schedule.week', params: {'week': 2})!.isStale,
        isTrue,
      );
      now += 180 * 24 * 60 * 60 * 1000;
      expect(cache.read(package, 'schedule.week', params: {'week': 2}), isNull);
    },
  );

  test(
    'projection refuses unknown weeks, terms, filters, old schemas and other digests',
    () {
      final cache = ScriptDataCache(CredentialStore());
      final package = schedulePackage();
      cache.write(package, 'schedule.week', {}, termSnapshot());
      for (final params in [
        {'week': 4},
        {'week': 2, 'term': 'other'},
        {'week': 2, 'filter': 'other'},
      ]) {
        expect(cache.read(package, 'schedule.week', params: params), isNull);
      }
      expect(
        cache.read(
          schedulePackage(version: '2.0.0'),
          'schedule.week',
          params: {'week': 2},
        ),
        isNull,
      );
      final old = schedulePackage(schema: '1.1');
      cache.write(old, 'schedule.week', {}, termSnapshot());
      expect(cache.read(old, 'schedule.week', params: {'week': 2}), isNull);
      final filtered = schedulePackage(version: '3.0.0');
      cache.write(filtered, 'schedule.week', {
        'filter': 'mine',
      }, termSnapshot());
      expect(
        cache.read(filtered, 'schedule.week', params: {'week': 2}),
        isNull,
      );
    },
  );

  test(
    'a fresh term snapshot supersedes an older exact week without changing its timestamp',
    () {
      var now = 1000000;
      final cache = ScriptDataCache(CredentialStore(), now: () => now);
      final package = schedulePackage();
      cache.write(
        package,
        'schedule.week',
        {'week': 2},
        {'term': 'synthetic-term', 'week': 2, 'days': []},
      );
      now += 30000;
      cache.write(package, 'schedule.week', {}, termSnapshot());
      final week = cache.read(package, 'schedule.week', params: {'week': 2})!;
      expect(week.isStale, isFalse);
      expect(week.fetchedAt.millisecondsSinceEpoch, now);
      expect((week.data as Map)['weekType'], 'holiday');
    },
  );
}
