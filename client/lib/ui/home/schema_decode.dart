/// adapter 产出（JSON 往返 Map）→ 契约 view 类型的薄解码。
///
/// codegen 的 Dart 类型目前无 `fromJson`；此处按 `contract/schema` 字段形状做防御性映射，
/// 供首页 snapshot 装配。字段含义不得臆造（红线 #6）。
library;

import 'models.dart';

NoticeList? noticeListFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final itemsRaw = map['items'];
  if (itemsRaw is! List) return null;
  final items = <NoticeListItems>[];
  for (final entry in itemsRaw) {
    final item = _noticeItem(entry);
    if (item != null) items.add(item);
  }
  return NoticeList(items: items);
}

NoticeListItems? _noticeItem(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final id = map['id']?.toString();
  final title = map['title']?.toString();
  final category = map['category']?.toString();
  final source = map['source']?.toString();
  if (id == null ||
      id.isEmpty ||
      title == null ||
      title.isEmpty ||
      category == null ||
      category.isEmpty ||
      source == null ||
      source.isEmpty) {
    return null;
  }
  final attachments = _attachments(map['attachments']);
  return NoticeListItems(
    id: id,
    title: title,
    category: category,
    source: source,
    summary: map['summary']?.toString(),
    // 正文/作者/部门供 App 内详情下钻展示（ADR-025 §2.2）；均为 schema 既有字段，
    // 非臆造（红线 #6）。缺失即 null。
    content: map['content']?.toString(),
    author: map['author']?.toString(),
    department: map['department']?.toString(),
    url: map['url']?.toString(),
    publishedAt: map['publishedAt']?.toString(),
    attachments: attachments,
  );
}

List<NoticeListItemsAttachments>? _attachments(Object? raw) {
  if (raw is! List) return null;
  final out = <NoticeListItemsAttachments>[];
  for (final entry in raw) {
    final map = _asStringKeyedMap(entry);
    if (map == null) continue;
    final name = map['name']?.toString();
    final url = map['url']?.toString();
    if (name == null || name.isEmpty || url == null || url.isEmpty) continue;
    final size = map['sizeBytes'];
    out.add(
      NoticeListItemsAttachments(
        name: name,
        url: url,
        sizeBytes: size is int ? size : (size is num ? size.toInt() : null),
        mimeType: map['mimeType']?.toString(),
      ),
    );
  }
  return out.isEmpty ? null : out;
}

// ---------------------------------------------------------------------------
// grades.list（ehall-session；App 内成绩单）
// ---------------------------------------------------------------------------

GradesList? gradesListFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final term = map['term']?.toString();
  if (term == null || term.isEmpty) return null;
  final itemsRaw = map['items'];
  if (itemsRaw is! List) return null;
  final items = <GradesListItems>[];
  for (final entry in itemsRaw) {
    final item = _gradeItem(entry);
    if (item != null) items.add(item);
  }
  return GradesList(
    term: term,
    academicYear: map['academicYear']?.toString(),
    termName: map['termName']?.toString(),
    updatedAt: map['updatedAt']?.toString(),
    total: _asInt(map['total']),
    hasNext: map['hasNext'] is bool ? map['hasNext'] as bool : null,
    items: items,
  );
}

GradesListItems? _gradeItem(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final courseId = map['courseId']?.toString();
  final courseName = map['courseName']?.toString();
  final credit = map['credit'];
  final category = map['category']?.toString();
  final status = map['status']?.toString();
  final score = _gradeScore(map['score']);
  if (courseId == null ||
      courseId.isEmpty ||
      courseName == null ||
      courseName.isEmpty ||
      credit is! num ||
      category == null ||
      category.isEmpty ||
      status == null ||
      status.isEmpty ||
      score == null) {
    return null;
  }
  return GradesListItems(
    courseId: courseId,
    courseName: courseName,
    credit: credit,
    creditType: map['creditType']?.toString(),
    courseNature: map['courseNature']?.toString(),
    courseCategory: map['courseCategory']?.toString(),
    teacher: map['teacher']?.toString(),
    offeringUnit: map['offeringUnit']?.toString(),
    classNo: map['classNo']?.toString(),
    examMethod: map['examMethod']?.toString(),
    examAt: map['examAt']?.toString(),
    retake: map['retake'] is bool ? map['retake'] as bool : null,
    sourceStatus: map['sourceStatus']?.toString(),
    rank: _asInt(map['rank']),
    courseAverage: map['courseAverage'] is num
        ? map['courseAverage'] as num
        : null,
    score: score,
    gradePoint: map['gradePoint'] is num ? map['gradePoint'] as num : null,
    category: category,
    status: status,
  );
}

GradesListItemsScore? _gradeScore(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final kind = map['kind']?.toString();
  if (kind == null || kind.isEmpty) return null;
  // value 契约允许 number / string / null（通过制或缺考），原样透传，不臆造。
  return GradesListItemsScore(
    kind: kind,
    value: map['value'],
    raw: map['raw']?.toString(),
    status: map['status']?.toString(),
    max: map['max'] is num ? map['max'] as num : null,
  );
}

// ---------------------------------------------------------------------------
// schedule.week（ehall-session；单周课表）
// ---------------------------------------------------------------------------

ScheduleWeek? scheduleWeekFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final term = map['term']?.toString();
  final week = _asInt(map['week']);
  if (term == null || term.isEmpty || week == null) return null;
  final daysRaw = map['days'];
  final days = <ScheduleWeekDays>[];
  if (daysRaw is List) {
    for (final entry in daysRaw) {
      final day = _scheduleDay(entry);
      if (day != null) days.add(day);
    }
  }
  return ScheduleWeek(
    term: term,
    week: week,
    academicYear: map['academicYear']?.toString(),
    termStartDate: map['termStartDate']?.toString(),
    termEndDate: map['termEndDate']?.toString(),
    updatedAt: map['updatedAt']?.toString(),
    sourceSystem: map['sourceSystem']?.toString(),
    days: days,
  );
}

ScheduleWeekDays? _scheduleDay(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final dayOfWeek = _asInt(map['dayOfWeek']);
  if (dayOfWeek == null) return null;
  final slotsRaw = map['slots'];
  final slots = <ScheduleWeekDaysSlots>[];
  if (slotsRaw is List) {
    for (final entry in slotsRaw) {
      final slot = _scheduleSlot(entry);
      if (slot != null) slots.add(slot);
    }
  }
  return ScheduleWeekDays(dayOfWeek: dayOfWeek, slots: slots);
}

ScheduleWeekDaysSlots? _scheduleSlot(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final start = map['start']?.toString();
  final end = map['end']?.toString();
  final courseName = map['courseName']?.toString();
  if (start == null ||
      start.isEmpty ||
      end == null ||
      end.isEmpty ||
      courseName == null ||
      courseName.isEmpty) {
    return null;
  }
  return ScheduleWeekDaysSlots(
    start: start,
    end: end,
    courseName: courseName,
    courseId: map['courseId']?.toString(),
    date: map['date']?.toString(),
    timeStart: map['timeStart']?.toString(),
    timeEnd: map['timeEnd']?.toString(),
    campus: map['campus']?.toString(),
    building: map['building']?.toString(),
    room: map['room']?.toString(),
    courseNature: map['courseNature']?.toString(),
    classNo: map['classNo']?.toString(),
    teacher: map['teacher']?.toString(),
    location: map['location']?.toString(),
  );
}

// ---------------------------------------------------------------------------
// classroom.buildings / classroom.available（ehall-session；空教室）
// ---------------------------------------------------------------------------

ClassroomBuildings? classroomBuildingsFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final itemsRaw = map['items'];
  final items = <ClassroomBuildingsItems>[];
  if (itemsRaw is List) {
    for (final entry in itemsRaw) {
      final m = _asStringKeyedMap(entry);
      if (m == null) continue;
      final building = m['building']?.toString();
      if (building == null || building.isEmpty) continue;
      items.add(
        ClassroomBuildingsItems(
          building: building,
          buildingId: m['buildingId']?.toString(),
          campus: m['campus']?.toString(),
          roomCount: _asInt(m['roomCount']),
        ),
      );
    }
  }
  return ClassroomBuildings(
    campus: map['campus']?.toString(),
    term: map['term']?.toString(),
    items: items,
  );
}

ClassroomAvailable? classroomAvailableFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final itemsRaw = map['items'];
  final items = <ClassroomAvailableItems>[];
  if (itemsRaw is List) {
    for (final entry in itemsRaw) {
      final item = _classroomItem(entry);
      if (item != null) items.add(item);
    }
  }
  return ClassroomAvailable(
    date: map['date']?.toString(),
    term: map['term']?.toString(),
    week: _asInt(map['week']),
    weekday: _asInt(map['weekday']),
    start: map['start']?.toString(),
    end: map['end']?.toString(),
    timeZone: map['timeZone']?.toString(),
    sourceSystem: map['sourceSystem']?.toString(),
    updatedAt: map['updatedAt']?.toString(),
    items: items,
  );
}

ClassroomAvailableItems? _classroomItem(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final building = map['building']?.toString();
  final room = map['room']?.toString();
  if (building == null || building.isEmpty || room == null || room.isEmpty) {
    return null;
  }
  final sectionsRaw = map['sections'];
  List<ClassroomAvailableItemsSections>? sections;
  if (sectionsRaw is List) {
    final out = <ClassroomAvailableItemsSections>[];
    for (final entry in sectionsRaw) {
      final m = _asStringKeyedMap(entry);
      if (m == null) continue;
      final index = _asInt(m['index']);
      final occupied = m['occupied'];
      if (index == null || occupied is! bool) continue;
      out.add(
        ClassroomAvailableItemsSections(
          index: index,
          occupied: occupied,
          label: m['label']?.toString(),
          timeStart: m['timeStart']?.toString(),
          timeEnd: m['timeEnd']?.toString(),
        ),
      );
    }
    sections = out.isEmpty ? null : out;
  }
  return ClassroomAvailableItems(
    campus: map['campus']?.toString(),
    building: building,
    buildingId: map['buildingId']?.toString(),
    room: room,
    roomId: map['roomId']?.toString(),
    floor: map['floor']?.toString(),
    capacity: _asInt(map['capacity']),
    equipment: _asStringList(map['equipment']),
    occupied: map['occupied'] is bool ? map['occupied'] as bool : null,
    status: map['status']?.toString(),
    sections: sections,
  );
}

// ---------------------------------------------------------------------------
// card.balance / card.transactions（card-session；用户按需触发）
// ---------------------------------------------------------------------------

CardBalance? cardBalanceFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final cardNumber = map['cardNumber']?.toString();
  final balanceMap = _asStringKeyedMap(map['balance']);
  final amountMinor = _asInt(balanceMap?['amountMinor']);
  final currency = balanceMap?['currency']?.toString();
  if (cardNumber == null ||
      cardNumber.isEmpty ||
      amountMinor == null ||
      currency == null ||
      !_currencyPattern.hasMatch(currency)) {
    return null;
  }
  final lastMap = _asStringKeyedMap(map['lastTransaction']);
  return CardBalance(
    cardNumber: cardNumber,
    cardNumberMasked: map['cardNumberMasked']?.toString(),
    cardType: map['cardType']?.toString(),
    accountType: map['accountType']?.toString(),
    campus: map['campus']?.toString(),
    wallet: map['wallet']?.toString(),
    status: map['status']?.toString(),
    balanceUpdatedAt: map['balanceUpdatedAt']?.toString(),
    snapshotAt: map['snapshotAt']?.toString(),
    errorStatus: map['errorStatus']?.toString(),
    balance: CardBalanceBalance(amountMinor: amountMinor, currency: currency),
    lastTransaction: lastMap == null
        ? null
        : CardBalanceLastTransaction(
            amountMinor: _asInt(lastMap['amountMinor']),
            currency: lastMap['currency']?.toString(),
            time: lastMap['time']?.toString(),
            merchant: lastMap['merchant']?.toString(),
          ),
  );
}

CardTransactions? cardTransactionsFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final cardNumber = map['cardNumber']?.toString();
  final itemsRaw = map['items'];
  if (cardNumber == null || cardNumber.isEmpty || itemsRaw is! List) {
    return null;
  }
  final items = <CardTransactionsItems>[];
  for (final rawItem in itemsRaw) {
    final item = _cardTransactionItem(rawItem);
    if (item != null) items.add(item);
  }
  return CardTransactions(
    cardNumber: cardNumber,
    cardNumberMasked: map['cardNumberMasked']?.toString(),
    cardType: map['cardType']?.toString(),
    accountType: map['accountType']?.toString(),
    campus: map['campus']?.toString(),
    wallet: map['wallet']?.toString(),
    page: _asInt(map['page']),
    size: _asInt(map['size']),
    cursor: map['cursor']?.toString(),
    total: _asInt(map['total']),
    hasNext: map['hasNext'] is bool ? map['hasNext'] as bool : null,
    windowStart: map['windowStart']?.toString(),
    windowEnd: map['windowEnd']?.toString(),
    snapshotAt: map['snapshotAt']?.toString(),
    items: items,
  );
}

CardTransactionsItems? _cardTransactionItem(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final time = map['time']?.toString();
  final amountMinor = _asNonNegativeInt(map['amountMinor']);
  final currency = map['currency']?.toString();
  final direction = map['direction']?.toString();
  if (time == null ||
      time.isEmpty ||
      DateTime.tryParse(time) == null ||
      amountMinor == null ||
      currency == null ||
      !_currencyPattern.hasMatch(currency) ||
      direction == null ||
      !_cardDirections.contains(direction)) {
    return null;
  }
  return CardTransactionsItems(
    time: time,
    transactionId: map['transactionId']?.toString(),
    postedAt: map['postedAt']?.toString(),
    amountMinor: amountMinor,
    currency: currency,
    direction: direction,
    merchant: map['merchant']?.toString(),
    location: map['location']?.toString(),
    status: map['status']?.toString(),
    balanceAfterMinor: _asInt(map['balanceAfterMinor']),
    type: map['type']?.toString(),
  );
}

// ---------------------------------------------------------------------------
// exam.list / library.loans（用户按需触发）
// ---------------------------------------------------------------------------

ExamList? examListFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null || !_optionalIs<String>(map, 'term')) return null;
  final itemsRaw = map['items'];
  if (map.containsKey('items') && itemsRaw is! List) return null;
  final items = <ExamListItems>[];
  if (itemsRaw is List) {
    for (final rawItem in itemsRaw) {
      final item = _examItem(rawItem);
      if (item != null) items.add(item);
    }
  }
  return ExamList(
    term: map['term'] as String?,
    items: itemsRaw == null ? null : items,
  );
}

ExamListItems? _examItem(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final courseName = map['courseName'];
  if (courseName is! String || courseName.isEmpty) return null;
  for (final field in const [
    'courseId',
    'campus',
    'building',
    'room',
    'seat',
    'examType',
    'changeReason',
  ]) {
    if (!_optionalIs<String>(map, field)) return null;
  }
  final examAt = _optionalUtcDateTime(map, 'examAt');
  if (map.containsKey('examAt') && examAt == null) return null;
  final status = map['status'];
  if (status != null &&
      (status is! String || !_examStatuses.contains(status))) {
    return null;
  }
  return ExamListItems(
    courseId: map['courseId'] as String?,
    courseName: courseName,
    examAt: examAt,
    campus: map['campus'] as String?,
    building: map['building'] as String?,
    room: map['room'] as String?,
    seat: map['seat'] as String?,
    examType: map['examType'] as String?,
    status: status as String?,
    changeReason: map['changeReason'] as String?,
  );
}

LibraryLoans? libraryLoansFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
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
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final bookId = map['bookId'];
  final title = map['title'];
  final borrowedAt = _requiredUtcDateTime(map['borrowedAt']);
  final dueAt = _requiredUtcDateTime(map['dueAt']);
  if (bookId is! String ||
      bookId.isEmpty ||
      title is! String ||
      title.isEmpty ||
      borrowedAt == null ||
      dueAt == null) {
    return null;
  }
  for (final field in const ['author', 'callNumber', 'location', 'branch']) {
    if (!_optionalIs<String>(map, field)) return null;
  }
  for (final field in const [
    'renewable',
    'overdue',
    'reserved',
    'returnConfirmed',
  ]) {
    if (!_optionalIs<bool>(map, field)) return null;
  }
  final renewCount = _optionalSchemaNonNegativeInt(map, 'renewCount');
  final renewalMax = _optionalSchemaNonNegativeInt(map, 'renewalMax');
  if ((map.containsKey('renewCount') && renewCount == null) ||
      (map.containsKey('renewalMax') && renewalMax == null)) {
    return null;
  }
  final pickupDeadline = _optionalUtcDateTime(map, 'pickupDeadline');
  final renewalDeadline = _optionalUtcDateTime(map, 'renewalDeadline');
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
  final map = _asStringKeyedMap(raw);
  final amountMinor = _asSchemaNonNegativeInt(map?['amountMinor']);
  final currency = map?['currency'];
  if (map == null ||
      amountMinor == null ||
      currency is! String ||
      !_currencyPattern.hasMatch(currency)) {
    return null;
  }
  return LibraryLoansItemsOverdueFee(
    amountMinor: amountMinor,
    currency: currency,
  );
}

const Set<String> _examStatuses = {
  'scheduled',
  'changed',
  'cancelled',
  'completed',
  'unknown',
};

bool _optionalIs<T>(Map<String, dynamic> map, String key) =>
    !map.containsKey(key) || map[key] is T;

int? _optionalSchemaNonNegativeInt(Map<String, dynamic> map, String key) =>
    map.containsKey(key) ? _asSchemaNonNegativeInt(map[key]) : null;

int? _asSchemaNonNegativeInt(Object? raw) {
  if (raw is String) return null;
  final value = _asInt(raw);
  return value != null && value >= 0 ? value : null;
}

String? _optionalUtcDateTime(Map<String, dynamic> map, String key) =>
    map.containsKey(key) ? _requiredUtcDateTime(map[key]) : null;

String? _requiredUtcDateTime(Object? raw) {
  if (raw is! String) return null;
  final match = _utcDateTimePattern.firstMatch(raw);
  final parsed = DateTime.tryParse(raw);
  if (match == null || parsed == null) return null;
  final parts = [
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
  ];
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] != int.parse(match.group(i + 1)!)) return null;
  }
  return raw;
}

final RegExp _utcDateTimePattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$',
);
final RegExp _currencyPattern = RegExp(r'^[A-Z]{3}$');
const Set<String> _cardDirections = {
  'debit',
  'credit',
  'refund',
  'reversal',
  'freeze',
  'transfer',
  'subsidy',
  'unknown',
};

int? _asNonNegativeInt(Object? raw) {
  final value = raw is int ? raw : (raw is String ? int.tryParse(raw) : null);
  return value != null && value >= 0 ? value : null;
}

int? _asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num && raw.isFinite && raw == raw.truncateToDouble()) {
    return raw.toInt();
  }
  if (raw is String) return int.tryParse(raw);
  return null;
}

List<String>? _asStringList(Object? raw) {
  if (raw is! List) return null;
  final out = <String>[];
  for (final entry in raw) {
    final s = entry?.toString();
    if (s != null && s.isNotEmpty) out.add(s);
  }
  return out.isEmpty ? null : out;
}

Map<String, dynamic>? _asStringKeyedMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}
