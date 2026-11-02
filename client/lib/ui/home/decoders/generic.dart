import '../models.dart';
import 'values.dart';

/// Contract data only: unknown roles remain ordinary text, never executable UI.
GenericSection? genericSectionFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null || map['sectionId'] is! String || map['title'] is! String) {
    return null;
  }
  GenericRole role(Object? value) =>
      GenericRole.values.where((role) => role.name == value).firstOrNull ??
      GenericRole.unknown;
  final rawFields = map['fields'] ?? const [];
  if (rawFields is! List) return null;
  final fields = <GenericField>[];
  for (final value in rawFields) {
    final field = asStringKeyedMap(value);
    if (field == null || field['label'] is! String) return null;
    fields.add(
      GenericField(
        label: field['label'],
        role: role(field['role']),
        value: field['value'],
      ),
    );
  }
  GenericTable? table;
  if (map['table'] != null) {
    final value = asStringKeyedMap(map['table']);
    if (value == null || value['columns'] is! List || value['rows'] is! List) {
      return null;
    }
    final columns = <GenericColumn>[];
    for (final rawColumn in value['columns']) {
      final column = asStringKeyedMap(rawColumn);
      if (column == null || column['label'] is! String) return null;
      columns.add(
        GenericColumn(label: column['label'], role: role(column['role'])),
      );
    }
    final rows = <List<Object?>>[];
    for (final row in value['rows']) {
      if (row is! List || row.length != columns.length) return null;
      rows.add(List<Object?>.from(row));
    }
    table = GenericTable(columns: columns, rows: rows);
  }
  return GenericSection(
    sectionId: map['sectionId'],
    title: map['title'],
    fields: fields,
    table: table,
  );
}
