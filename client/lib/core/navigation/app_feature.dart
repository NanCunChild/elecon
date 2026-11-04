/// Host-owned navigation targets. These identifiers never name script handlers
/// or carry query, identity or command parameters (ADR-085).
enum AppFeature {
  schedule,
  grades,
  exam,
  classroom,
  card,
  library,
  energy,
  climate,
  notice,
  faculty,
  directory;

  static AppFeature? fromId(Object? value) {
    for (final feature in values) {
      if (feature.name == value) return feature;
    }
    return null;
  }

  static AppFeature? fromUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'elecon' ||
        uri.host != 'feature' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 1) {
      return null;
    }
    final feature = fromId(uri.pathSegments.single);
    // Canonical form only: no encoded slashes, alternate casing or suffixes.
    return feature != null && value == feature.uri ? feature : null;
  }

  String get uri => 'elecon://feature/$name';

  List<List<String>> get capabilityOptions => switch (this) {
    schedule => const [
      ['schedule.week'],
    ],
    grades => const [
      ['grades.list'],
    ],
    exam => const [
      ['exam.list'],
    ],
    classroom => const [
      ['classroom.buildings', 'classroom.available'],
    ],
    card => const [
      ['card.balance'],
      ['card.transactions'],
      ['card.qr'],
    ],
    library => const [
      ['library.loans'],
    ],
    energy => const [
      ['energy.meters', 'energy.usage'],
    ],
    climate => const [
      ['climate.devices', 'climate.status'],
    ],
    notice => const [
      ['notice.list'],
    ],
    faculty => const [
      ['faculty.search'],
    ],
    directory => const [
      ['directory.phones'],
    ],
  };
}
