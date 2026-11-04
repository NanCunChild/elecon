// Pure Dart regression for the generated boundary; no school data or test deps.
import '../generated/dart/lib/output_validator_registry.dart';

void expect(bool condition, String behavior) {
  if (!condition) throw StateError(behavior);
}

void main() {
  final form = outputValidatorFor('elecon.query.controls', '2.0')!;
  final deferredForm = outputValidatorFor('elecon.query.controls', '2.1')!;
  final legacy = outputValidatorFor('elecon.query.controls', '1.0')!;
  final base = {
    'target': 'classroom.available',
    'title': 'Synthetic',
    'submitLabel': 'Apply',
  };
  Map<String, Object?> withControl(Map<String, Object?> control) => {
    ...base,
    'controls': [
      {'id': 'schoolField', 'label': 'School field', ...control},
    ],
  };
  for (final control in <Map<String, Object?>>[
    {'kind': 'text', 'initialValue': 'Synthetic'},
    {'kind': 'number', 'initialValue': 0},
    {'kind': 'boolean', 'initialValue': false},
    {'kind': 'date', 'initialValue': '2026-11-04'},
    {
      'kind': 'select',
      'options': [],
      'disabled': true,
      'disabledReason': 'Choose campus',
    },
    {'kind': 'multiSelect', 'options': [], 'initialValue': <String>[]},
    {
      'kind': 'timeRange',
      'timeZone': 'UTC',
      'initialValue': {'start': '09:00', 'end': '10:00'},
    },
  ]) {
    expect(form(withControl(control)), 'valid ${control['kind']}');
  }
  for (final control in <Map<String, Object?>>[
    {'id': 'constructor', 'kind': 'text'},
    {'id': 'prototype', 'kind': 'text'},
    {'kind': 'number', 'initialValue': '0'},
    {'kind': 'number', 'initialValue': double.infinity},
    {'kind': 'boolean', 'initialValue': 0},
    {'kind': 'date', 'initialValue': '2026-02-30'},
    {
      'kind': 'multiSelect',
      'options': [],
      'initialValue': ['a', 'a'],
    },
    {
      'kind': 'timeRange',
      'initialValue': {'start': '09:00', 'end': '10:00'},
    },
  ]) {
    expect(!form(withControl(control)), 'reject invalid ${control['kind']}');
  }
  expect(form({...base, 'controls': []}), 'empty v2 form');
  final deferred = withControl({
    'kind': 'select',
    'options': [],
    'deferred': true,
  });
  expect(deferredForm(deferred), '2.1 accepts deferred field declarations');
  expect(!form(deferred), '2.0 keeps its exact closed field shape');
  expect(
    !deferredForm(
      withControl({'kind': 'select', 'options': [], 'deferred': 'true'}),
    ),
    'deferred must be a boolean',
  );
  expect(!legacy({...base, 'controls': []}), 'legacy retains minItems');
  expect(
    legacy(withControl({'kind': 'text', 'parameter': 'room'})),
    'legacy parameter retained',
  );
  expect(
    !form(withControl({'kind': 'text', 'parameter': 'room'})),
    'v2 rejects host parameter binding',
  );

  final room = outputValidatorFor('elecon.classroom.available', '1.3')!;
  final oldRoom = outputValidatorFor('elecon.classroom.available', '1.2')!;
  final result = {
    'items': [
      {'building': 'Synthetic', 'room': '101'},
    ],
  };
  expect(
    room({
      ...result,
      'appliedFilters': {
        'flag': false,
        'minimumSeats': 0,
        'window': {'start': '09:00', 'end': '10:00'},
      },
      'coverage': {'complete': true},
    }),
    'bounded fields keep false and zero',
  );
  for (final filters in <Map<String, Object?>>[
    {'constructor': 'x'},
    {'prototype': 'x'},
    {'__proto__': 'x'},
    {'invalid key': 'x'},
    {'value': null},
    {'value': double.nan},
    {
      'value': ['a', 'a'],
    },
    {'value': 'x' * 513},
    {for (var i = 0; i < 33; i++) 'field$i': i},
  ]) {
    expect(
      !room({...result, 'appliedFilters': filters}),
      'reject invalid map shape',
    );
  }
  final extension = {
    'items': [
      {
        'building': 'Synthetic',
        'room': '101',
        'teachingCapacity': 'old extension',
      },
    ],
  };
  expect(oldRoom(extension), 'old open schema keeps extension meaning');
  expect(!room(extension), 'new standardized field validates numeric capacity');
  print(
    'Dart query forms validators: typed controls, bounds, key names, uniqueness and old versions passed',
  );
}
