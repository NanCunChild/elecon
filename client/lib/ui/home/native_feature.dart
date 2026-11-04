import 'package:flutter/material.dart';

import '../../core/navigation/app_feature.dart';
import '../../core/scripts/manifest.dart';
import '../../core/scripts/registry.dart';
import '../../l10n/gen/app_localizations.dart';
import 'capability_sections.dart';
import 'energy_climate_sections.dart';
import 'faculty_search_section.dart';
import 'phone_directory_section.dart';

String nativeFeatureTitle(AppFeature feature, AppLocalizations l10n) =>
    switch (feature) {
      AppFeature.schedule => l10n.homeScheduleTitle,
      AppFeature.grades => l10n.homeGradesTitle,
      AppFeature.exam => l10n.homeExamTitle,
      AppFeature.classroom => l10n.homeClassroomTitle,
      AppFeature.card => l10n.homeCardTitle,
      AppFeature.library => l10n.homeLibraryLoansTitle,
      AppFeature.energy => l10n.energyTitle,
      AppFeature.climate => l10n.climateTitle,
      AppFeature.notice => l10n.homeNoticeTitle,
      AppFeature.faculty => l10n.facultyTitle,
      AppFeature.directory => l10n.phoneDirectoryTitle,
    };

Widget nativeFeatureContent(AppFeature feature, ScriptPackage package) =>
    switch (feature) {
      AppFeature.schedule => ScheduleSection(
        calendarEnabled:
            package.manifest.capability('calendar.academic') != null,
      ),
      AppFeature.grades => const GradesSection(),
      AppFeature.exam => const ExamSection(),
      AppFeature.classroom => const ClassroomSection(),
      AppFeature.card => CardSection(
        balanceEnabled: package.manifest.capability('card.balance') != null,
        qrEnabled: package.manifest.capability('card.qr') != null,
        transactionsEnabled:
            package.manifest.capability('card.transactions') != null,
      ),
      AppFeature.library => const LibraryLoansSection(),
      AppFeature.energy => const EnergySection(),
      AppFeature.climate => const ClimateSection(),
      AppFeature.notice => const NoticeSection(),
      AppFeature.faculty => const FacultySearchSection(),
      AppFeature.directory => const PhoneDirectorySection(),
    };

/// Resolve the user's default provider, never an arbitrary same-type card.
ScriptPackage? nativeFeatureProvider(
  ScriptRegistry registry,
  String school,
  AppFeature feature,
) {
  for (final required in feature.capabilityOptions) {
    final package = registry.provider(school, required.first);
    if (package != null &&
        !package.requiresUpdate &&
        required.every((id) => package.manifest.capability(id) != null)) {
      return package;
    }
  }
  return null;
}
