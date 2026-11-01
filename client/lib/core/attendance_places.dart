/// ADR-055: user-managed locations, separate from credentials and script data.
library;

import 'dart:convert';

import 'credential/store.dart';
import 'credential/types.dart';

class AttendancePlace {
  AttendancePlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.address,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ||
        name.trim().isEmpty ||
        name.length > 50 ||
        address.trim().isEmpty ||
        address.length > 200 ||
        !latitude.isFinite ||
        latitude.abs() > 90 ||
        !longitude.isFinite ||
        longitude.abs() > 180) {
      throw ArgumentError('invalid_attendance_place');
    }
  }

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String address;

  Map<String, Object> get location => {
    'latitude': latitude,
    'longitude': longitude,
    'address': address,
    'coordinateSystem': 'service',
  };

  Map<String, Object> toJson() => {'id': id, 'name': name, ...location};
  factory AttendancePlace.fromJson(Map<String, dynamic> data) {
    if (data['coordinateSystem'] != 'service') {
      throw const FormatException('unsupported_attendance_coordinates');
    }
    return AttendancePlace(
      id: data['id'] as String,
      name: data['name'] as String,
      latitude: (data['latitude'] as num).toDouble(),
      longitude: (data['longitude'] as num).toDouble(),
      address: data['address'] as String,
    );
  }
}

class AttendancePlacesStore {
  AttendancePlacesStore(this.store);
  final CredentialStore store;
  static const type = 'checkin-places';
  static const limit = 16;
  String _ref(String school, String provider) => '$type:$school:$provider';

  List<AttendancePlace> read(String school, String provider) {
    final ref = _ref(school, provider);
    final entry = store.list().where((e) => e.ref == ref).firstOrNull;
    if (entry == null ||
        entry.schoolId != school ||
        entry.type != type ||
        entry.status != CredentialStatus.active ||
        entry.value.length > 32768) {
      return const [];
    }
    try {
      final data = jsonDecode(entry.value) as Map<String, dynamic>;
      if (data['version'] != 1) return const [];
      final places = [
        for (final row in data['places'] as List)
          AttendancePlace.fromJson(Map<String, dynamic>.from(row as Map)),
      ];
      _validate(places);
      return List.unmodifiable(places);
    } catch (_) {
      return const [];
    }
  }

  void _validate(List<AttendancePlace> places) {
    if (places.length > limit ||
        places.map((p) => p.id).toSet().length != places.length) {
      throw ArgumentError('invalid_attendance_places');
    }
  }

  void write(String school, String provider, List<AttendancePlace> places) {
    _validate(places);
    final ref = _ref(school, provider);
    if (places.isEmpty) {
      store.delete(ref);
      return;
    }
    store.put(
      CredentialEntry(
        ref: ref,
        schoolId: school,
        type: type,
        scope: const [],
        value: jsonEncode({
          'version': 1,
          'places': places.map((p) => p.toJson()).toList(),
        }),
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: null,
        status: CredentialStatus.active,
      ),
    );
  }
}
