// Grouping metadata is never a credential-scope migration.
import 'dart:convert';

import 'package:elecon/catalog/schools.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/campus_snapshot_loader.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage school(
  String type, {
  String? id,
  String name = 'Synthetic University',
  String version = '1.0.0',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'id': id ?? 'synthetic-$type',
      'schoolId': 'synthetic_$type',
      'sdkVersion': 16,
      'version': version,
      'name': 'Package $type',
      'homeTitle': 'Legacy combined name ($type)',
      'school': {
        'id': 'synthetic',
        'name': name,
        'type': {'id': type, 'name': type},
      },
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        {
          'id': 'generic.section',
          'schema': 'elecon.generic.section',
          'schemaVersion': '1.0',
        },
      ],
      'accounts': [],
    },
    'source': '''export const capabilities={'generic.section':async(ctx,p)=>{
    if(p.save) await ctx.credentials.set('identity',p.save,{namespace:'school.auth'});
    const record=await ctx.credentials.get('identity',{namespace:'school.auth'});
    return {sectionId:'identity',title:record?.value ?? 'empty'};
  }};''',
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SDK15 rejects new school metadata while legacy title semantics remain',
    () async {
      final raw =
          jsonDecode(school('undergraduate').encode()) as Map<String, dynamic>;
      (raw['manifest'] as Map)['sdkVersion'] = 15;
      expect(() => ScriptPackage.parse(jsonEncode(raw)), throwsFormatException);
      (raw['manifest'] as Map).remove('school');
      final legacy = ScriptPackage.parse(jsonEncode(raw));
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(legacy, approvedDigest: legacy.digest);
      await session.selectTrustedScriptSchool(legacy.manifest.id);
      expect(session.selectedSchool!.institutionId, isNull);
      expect(session.selectedSchool!.displayName, 'Package undergraduate');
      final snapshot = await loadCampusSnapshot(session, preferCacheOnly: true);
      expect(snapshot.homeTitle, 'Legacy combined name (undergraduate)');
      expect(snapshot.schoolType, isNull);
    },
  );
  test(
    'one institution groups types while selection and credential scopes remain separate',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final undergraduate = school('undergraduate');
      final postgraduate = school('postgraduate');
      for (final p in [undergraduate, postgraduate]) {
        await session.installTrustedScript(p, approvedDigest: p.digest);
      }
      final groups = groupSchoolChoices(session.availableSchools);
      expect(groups, hasLength(1));
      expect(
        groups.single.map((s) => s.typeId),
        containsAll(['undergraduate', 'postgraduate']),
      );
      expect(groups.single.map((s) => s.id).toSet(), {
        'synthetic_undergraduate',
        'synthetic_postgraduate',
      });
      await session.selectTrustedScriptSchool(undergraduate.manifest.id);
      final saved = await session.runTrustedScript(
        undergraduate.manifest.id,
        'generic.section',
        params: {'save': 'SYNTHETIC_UNDERGRADUATE'},
        interactive: false,
      );
      expect(saved.ok, isTrue);
      await session.selectTrustedScriptSchool(postgraduate.manifest.id);
      final empty = await session.runTrustedScript(
        postgraduate.manifest.id,
        'generic.section',
        interactive: false,
      );
      expect(empty.data, containsPair('title', 'empty'));
      await session.selectTrustedScriptSchool(undergraduate.manifest.id);
      final retained = await session.runTrustedScript(
        undergraduate.manifest.id,
        'generic.section',
        interactive: false,
      );
      expect(retained.data, containsPair('title', 'SYNTHETIC_UNDERGRADUATE'));
    },
  );

  test(
    'base source owns name/type and enhancement cannot override the home header',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final base = school('undergraduate');
      await session.installTrustedScript(base, approvedDigest: base.digest);
      await session.selectTrustedScriptSchool(base.manifest.id);
      final enhancement = school(
        'undergraduate',
        id: 'synthetic-enhancement',
        name: 'Wrong university',
      );
      await session.installTrustedScript(
        enhancement,
        approvedDigest: enhancement.digest,
      );
      expect(session.selectedSchool!.adapterId, 'script:${base.manifest.id}');
      final snapshot = await loadCampusSnapshot(session, preferCacheOnly: true);
      expect(snapshot.schoolName, 'Synthetic University');
      expect(snapshot.homeTitle, 'Synthetic University');
      expect(snapshot.schoolType, 'undergraduate');
      final update = school(
        'undergraduate',
        name: 'Renamed University',
        version: '1.1.0',
      );
      await session.installTrustedScript(update, approvedDigest: update.digest);
      expect(session.selectedSchool!.displayName, 'Renamed University');
      expect(session.selectedSchool!.id, 'synthetic_undergraduate');
    },
  );
}
