/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

LibraryLoans? libraryLoansFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  final itemsRaw = map?['items'];
  if (map == null || itemsRaw is! List) return null;
  final items = <LibraryLoansItems>[];
  for (final rawItem in itemsRaw) {
    final item = _libraryLoanItem(rawItem);
    if (item != null) items.add(item);
  }
  return LibraryLoans(items: items);
}

LibraryLoansItems? _libraryLoanItem(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final bookId = map['bookId'];
  final title = map['title'];
  final borrowedAt = requiredUtcDateTime(map['borrowedAt']);
  final dueAt = requiredUtcDateTime(map['dueAt']);
  if (bookId is! String ||
      bookId.isEmpty ||
      title is! String ||
      title.isEmpty ||
      borrowedAt == null ||
      dueAt == null) {
    return null;
  }
  for (final field in const ['author', 'callNumber', 'location', 'branch']) {
    if (!optionalIs<String>(map, field)) return null;
  }
  for (final field in const [
    'renewable',
    'overdue',
    'reserved',
    'returnConfirmed',
  ]) {
    if (!optionalIs<bool>(map, field)) return null;
  }
  final renewCount = optionalSchemaNonNegativeInt(map, 'renewCount');
  final renewalMax = optionalSchemaNonNegativeInt(map, 'renewalMax');
  if ((map.containsKey('renewCount') && renewCount == null) ||
      (map.containsKey('renewalMax') && renewalMax == null)) {
    return null;
  }
  final pickupDeadline = optionalUtcDateTime(map, 'pickupDeadline');
  final renewalDeadline = optionalUtcDateTime(map, 'renewalDeadline');
  if ((map.containsKey('pickupDeadline') && pickupDeadline == null) ||
      (map.containsKey('renewalDeadline') && renewalDeadline == null)) {
    return null;
  }
  final overdueFee = _overdueFee(map['overdueFee']);
  if (map.containsKey('overdueFee') && overdueFee == null) return null;
  return LibraryLoansItems(
    bookId: bookId,
    title: title,
    author: map['author'] as String?,
    callNumber: map['callNumber'] as String?,
    location: map['location'] as String?,
    branch: map['branch'] as String?,
    borrowedAt: borrowedAt,
    dueAt: dueAt,
    renewCount: renewCount,
    renewalMax: renewalMax,
    renewable: map['renewable'] as bool?,
    overdue: map['overdue'] as bool?,
    overdueFee: overdueFee,
    reserved: map['reserved'] as bool?,
    pickupDeadline: pickupDeadline,
    renewalDeadline: renewalDeadline,
    returnConfirmed: map['returnConfirmed'] as bool?,
  );
}

LibraryLoansItemsOverdueFee? _overdueFee(Object? raw) {
  if (raw == null) return null;
  final map = asStringKeyedMap(raw);
  final amountMinor = asSchemaNonNegativeInt(map?['amountMinor']);
  final currency = map?['currency'];
  if (map == null ||
      amountMinor == null ||
      currency is! String ||
      !currencyPattern.hasMatch(currency)) {
    return null;
  }
  return LibraryLoansItemsOverdueFee(
    amountMinor: amountMinor,
    currency: currency,
  );
}
