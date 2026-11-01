import 'dart:convert';

import 'package:elecon/core/attendance_places.dart';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage placesPackage({
  String id = 'synthetic',
  String school = 'synthetic',
  String schema = '1.1',
  String version = '1.0.0',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 9,
      'id': id,
      'schoolId': school,
      'version': version,
      'name': 'Synthetic',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'attendance.checkin',
          'schema': 'elecon.attendance.checkin',
          'schemaVersion': schema,
        },
      ],
    },
    'source': 'export const capabilities={};',
  }),
);
AttendancePlace place({String id = 'synthetic', double latitude = 12.3456}) =>
    AttendancePlace(
      id: id,
      name: 'Synthetic classroom',
      latitude: latitude,
      longitude: 45.6789,
      address: 'Synthetic address',
    );
Future<void> install(SessionController session, ScriptPackage p) =>
    session.installTrustedScript(p, approvedDigest: p.digest);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'saved locations are unavailable to script credential access and validate size and coordinates',
    () {
      final store = CredentialStore();
      final locations = AttendancePlacesStore(store);
      locations.write('synthetic', 'synthetic', [place()]);
      final credentials = ScriptCredentials(
        store: store,
        schoolId: 'synthetic',
        scriptId: 'synthetic',
        sdkVersion: 9,
      );
      expect(credentials.list(), isEmpty);
      expect(
        () => credentials.get(store.list().single.ref, namespace: '@legacy'),
        throwsA(isA<ScriptCredentialException>()),
      );
      expect(() => place(latitude: double.nan), throwsArgumentError);
      expect(() => place(latitude: 91), throwsArgumentError);
      expect(
        () => locations.write('synthetic', 'synthetic', [place(), place()]),
        throwsArgumentError,
      );
      expect(
        () => locations.write('synthetic', 'synthetic', [
          for (var i = 0; i < 17; i++) place(id: '$i'),
        ]),
        throwsArgumentError,
      );
      expect(
        locations.read('synthetic', 'synthetic').single.name,
        'Synthetic classroom',
      );
      expect(locations.read('other', 'synthetic'), isEmpty);
      expect(locations.read('synthetic', 'other'), isEmpty);
    },
  );
  test(
    'places survive encrypted backend restart without implying school login',
    () async {
      final blobs = InMemoryBlobStore();
      final first = SessionController(blobStoreProvider: () async => blobs);
      final p = placesPackage();
      await first.bootstrap();
      await install(first, p);
      await first.selectTrustedScriptSchool(p.manifest.id);
      first.scriptStorageConsent = () async => true;
      await first.saveAttendancePlaces(p, [place()]);
      expect(first.isLoggedIn, isFalse);
      expect(first.credentialMetadata, isEmpty);
      await first.flush();
      first.dispose();
      final second = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(second.dispose);
      await second.bootstrap();
      expect(
        (await second.attendancePlaces(p)).single.location,
        place().location,
      );
      expect(second.isLoggedIn, isFalse);
      final anotherProfile = SessionController();
      addTearDown(anotherProfile.dispose);
      await install(anotherProfile, p);
      await anotherProfile.selectTrustedScriptSchool(p.manifest.id);
      expect(await anotherProfile.attendancePlaces(p), isEmpty);
    },
  );
  test(
    'source changes, disable and old schemas cannot access places; approved update preserves them',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final p = placesPackage();
      final other = placesPackage(id: 'other');
      final old = placesPackage(id: 'legacy', schema: '1.0');
      final school = placesPackage(id: 'second', school: 'second');
      for (final value in [p, other, old, school]) {
        await install(session, value);
      }
      await session.selectTrustedScriptSchool(p.manifest.id);
      await session.saveAttendancePlaces(p, [place()]);
      expect(await session.attendancePlaces(other), isEmpty);
      await expectLater(
        session.saveAttendancePlaces(old, [place()]),
        throwsStateError,
      );
      final update = placesPackage(version: '1.1.0');
      await install(session, update);
      expect(await session.attendancePlaces(p), isEmpty);
      await expectLater(
        session.saveAttendancePlaces(p, [place()]),
        throwsStateError,
      );
      expect((await session.attendancePlaces(update)).single.id, 'synthetic');
      await session.selectTrustedScriptSchool(school.manifest.id);
      expect(await session.attendancePlaces(update), isEmpty);
      await expectLater(
        session.saveAttendancePlaces(update, [place()]),
        throwsStateError,
      );
      await session.selectTrustedScriptSchool(update.manifest.id);
      await session.enableTrustedScript(update.manifest.id, false);
      expect(await session.attendancePlaces(update), isEmpty);
      await expectLater(
        session.saveAttendancePlaces(update, [place()]),
        throwsStateError,
      );
    },
  );
}
