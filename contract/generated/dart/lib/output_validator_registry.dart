// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

typedef OutputValidator = bool Function(Object? payload);

/// 精确按已验签 manifest 的 emits 定位 validator；未知 schema/version 不存在于 registry。
OutputValidator? outputValidatorFor(String schema, String schemaVersion) {
  final descriptor = _outputSchemas['$schema\u0000$schemaVersion'];
  return descriptor == null ? null : (payload) => _validate(payload, descriptor);
}

final Map<String, Map<String, Object?>> _outputSchemas = {
  "elecon.app.announcement\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"version":<String,Object?>{"t":"s"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"title":<String,Object?>{"t":"s"},"content":<String,Object?>{"t":"s"},"publishedAt":<String,Object?>{"t":"s","f":"date-time"},"url":<String,Object?>{"t":"s","f":"uri"},"privacyUrl":<String,Object?>{"t":"s","f":"uri"}}}}}},
  "elecon.attendance.summary\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"term":<String,Object?>{"t":"s"},"total":<String,Object?>{"t":"i","n":0},"absent":<String,Object?>{"t":"i","n":0},"late":<String,Object?>{"t":"i","n":0},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"courseId":<String,Object?>{"t":"s"},"courseName":<String,Object?>{"t":"s"},"date":<String,Object?>{"t":"s","f":"date"},"type":<String,Object?>{"t":"s","e":<Object?>["absent","late","leave","earlyLeave","unknown"]},"appealStatus":<String,Object?>{"t":"s","e":<Object?>["none","pending","approved","rejected","unknown"]}}}}}},
  "elecon.calendar.academic\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"term":<String,Object?>{"t":"s"},"startDate":<String,Object?>{"t":"s","f":"date"},"endDate":<String,Object?>{"t":"s","f":"date"},"currentWeek":<String,Object?>{"t":"i","n":1},"holidays":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["date","name"],"p":<String,Object?>{"date":<String,Object?>{"t":"s","f":"date"},"name":<String,Object?>{"t":"s"},"isTeachingDay":<String,Object?>{"t":"b"}}}}}},
  "elecon.campus.network\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"accountStatus":<String,Object?>{"t":"s","e":<Object?>["active","disabled","unknown"]},"usageBytes":<String,Object?>{"t":"i","n":0},"online":<String,Object?>{"t":"b"},"devices":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"id":<String,Object?>{"t":"s"},"name":<String,Object?>{"t":"s"},"online":<String,Object?>{"t":"b"}}}}}},
  "elecon.card.balance\u00001.0": <String,Object?>{"t":"o","r":<Object?>["cardNumber","balance"],"p":<String,Object?>{"cardNumber":<String,Object?>{"t":"s"},"cardNumberMasked":<String,Object?>{"t":"s"},"cardType":<String,Object?>{"t":"s"},"accountType":<String,Object?>{"t":"s"},"campus":<String,Object?>{"t":"s"},"wallet":<String,Object?>{"t":"s"},"status":<String,Object?>{"t":"s","e":<Object?>["active","frozen","lost","cancelled","unknown"]},"balanceUpdatedAt":<String,Object?>{"t":"s","f":"date-time"},"snapshotAt":<String,Object?>{"t":"s","f":"date-time"},"errorStatus":<String,Object?>{"t":"s","e":<Object?>["failed","pending","unknown"]},"balance":<String,Object?>{"t":"o","r":<Object?>["amountMinor","currency"],"p":<String,Object?>{"amountMinor":<String,Object?>{"t":"i"},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"}}},"lastTransaction":<String,Object?>{"t":"o","p":<String,Object?>{"amountMinor":<String,Object?>{"t":"i"},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"},"time":<String,Object?>{"t":"s","f":"date-time"},"merchant":<String,Object?>{"t":"s"}}}}},
  "elecon.card.transactions\u00001.0": <String,Object?>{"t":"o","r":<Object?>["cardNumber","items"],"p":<String,Object?>{"cardNumber":<String,Object?>{"t":"s"},"cardNumberMasked":<String,Object?>{"t":"s"},"cardType":<String,Object?>{"t":"s"},"accountType":<String,Object?>{"t":"s"},"campus":<String,Object?>{"t":"s"},"wallet":<String,Object?>{"t":"s"},"page":<String,Object?>{"t":"i","n":1},"size":<String,Object?>{"t":"i","n":1},"cursor":<String,Object?>{"t":"s"},"total":<String,Object?>{"t":"i","n":0},"hasNext":<String,Object?>{"t":"b"},"windowStart":<String,Object?>{"t":"s","f":"date-time"},"windowEnd":<String,Object?>{"t":"s","f":"date-time"},"snapshotAt":<String,Object?>{"t":"s","f":"date-time"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["time","amountMinor","currency","direction"],"p":<String,Object?>{"time":<String,Object?>{"t":"s","f":"date-time"},"transactionId":<String,Object?>{"t":"s"},"postedAt":<String,Object?>{"t":"s","f":"date-time"},"amountMinor":<String,Object?>{"t":"i","n":0},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"},"direction":<String,Object?>{"t":"s","e":<Object?>["debit","credit","refund","reversal","freeze","transfer","subsidy","unknown"]},"merchant":<String,Object?>{"t":"s"},"location":<String,Object?>{"t":"s"},"status":<String,Object?>{"t":"s","e":<Object?>["final","pending","failed","cancelled","unknown"]},"balanceAfterMinor":<String,Object?>{"t":"i"},"type":<String,Object?>{"t":"s"}}}}}},
  "elecon.classroom.available\u00001.1": <String,Object?>{"t":"o","p":<String,Object?>{"date":<String,Object?>{"t":"s","f":"date"},"term":<String,Object?>{"t":"s"},"week":<String,Object?>{"t":"i","n":1},"weekday":<String,Object?>{"t":"i","n":1,"x":7},"start":<String,Object?>{"t":"s"},"end":<String,Object?>{"t":"s"},"timeZone":<String,Object?>{"t":"s"},"sectionStart":<String,Object?>{"t":"i","n":1},"sectionEnd":<String,Object?>{"t":"i","n":1},"sourceSystem":<String,Object?>{"t":"s"},"updatedAt":<String,Object?>{"t":"s","f":"date-time"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["building","room"],"p":<String,Object?>{"campus":<String,Object?>{"t":"s"},"building":<String,Object?>{"t":"s","l":1},"buildingId":<String,Object?>{"t":"s"},"room":<String,Object?>{"t":"s","l":1},"roomId":<String,Object?>{"t":"s"},"floor":<String,Object?>{"t":"s"},"capacity":<String,Object?>{"t":"i","n":0},"equipment":<String,Object?>{"t":"a","i":<String,Object?>{"t":"s"}},"occupied":<String,Object?>{"t":"b"},"status":<String,Object?>{"t":"s","e":<Object?>["available","occupied","partial","unknown"]},"sections":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["index","occupied"],"p":<String,Object?>{"index":<String,Object?>{"t":"i","n":1,"x":24},"occupied":<String,Object?>{"t":"b"},"label":<String,Object?>{"t":"s"},"timeStart":<String,Object?>{"t":"s"},"timeEnd":<String,Object?>{"t":"s"}}},"m":24}}}}}},
  "elecon.classroom.buildings\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"campus":<String,Object?>{"t":"s"},"term":<String,Object?>{"t":"s"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["building"],"p":<String,Object?>{"campus":<String,Object?>{"t":"s"},"building":<String,Object?>{"t":"s","l":1},"buildingId":<String,Object?>{"t":"s"},"roomCount":<String,Object?>{"t":"i","n":0}}}}}},
  "elecon.course.catalog\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"courseId":<String,Object?>{"t":"s"},"name":<String,Object?>{"t":"s"},"teacher":<String,Object?>{"t":"s"},"capacity":<String,Object?>{"t":"i","n":0},"enrolled":<String,Object?>{"t":"i","n":0},"prerequisites":<String,Object?>{"t":"a","i":<String,Object?>{"t":"s"}},"term":<String,Object?>{"t":"s"}}}}}},
  "elecon.course.selection\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"courseId":<String,Object?>{"t":"s"},"name":<String,Object?>{"t":"s"},"selected":<String,Object?>{"t":"b"},"status":<String,Object?>{"t":"s","e":<Object?>["available","selected","dropped","conflict","full","unknown"]},"reason":<String,Object?>{"t":"s"}}}}}},
  "elecon.dining.summary\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"merchant":<String,Object?>{"t":"s"},"amountMinor":<String,Object?>{"t":"i"},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"},"period":<String,Object?>{"t":"s"},"open":<String,Object?>{"t":"b"}}}}}},
  "elecon.dorm.health\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"metric":<String,Object?>{"t":"s"},"value":<String,Object?>{"t":"n"},"unit":<String,Object?>{"t":"s"},"measuredAt":<String,Object?>{"t":"s","f":"date-time"},"status":<String,Object?>{"t":"s","e":<Object?>["normal","abnormal","unknown"]}}}}}},
  "elecon.dorm.service\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"id":<String,Object?>{"t":"s"},"type":<String,Object?>{"t":"s"},"description":<String,Object?>{"t":"s"},"status":<String,Object?>{"t":"s","e":<Object?>["submitted","processing","completed","cancelled","unknown"]},"updatedAt":<String,Object?>{"t":"s","f":"date-time"}}}}}},
  "elecon.energy.usage\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"campus":<String,Object?>{"t":"s"},"dormitory":<String,Object?>{"t":"s"},"room":<String,Object?>{"t":"s"},"type":<String,Object?>{"t":"s","e":<Object?>["water","electricity","unknown"]},"reading":<String,Object?>{"t":"n"},"usage":<String,Object?>{"t":"n"},"unit":<String,Object?>{"t":"s"},"from":<String,Object?>{"t":"s","f":"date-time"},"to":<String,Object?>{"t":"s","f":"date-time"}}}}}},
  "elecon.exam.list\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"term":<String,Object?>{"t":"s"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["courseName"],"p":<String,Object?>{"courseId":<String,Object?>{"t":"s"},"courseName":<String,Object?>{"t":"s"},"examAt":<String,Object?>{"t":"s","f":"date-time"},"campus":<String,Object?>{"t":"s"},"building":<String,Object?>{"t":"s"},"room":<String,Object?>{"t":"s"},"seat":<String,Object?>{"t":"s"},"examType":<String,Object?>{"t":"s"},"status":<String,Object?>{"t":"s","e":<Object?>["scheduled","changed","cancelled","completed","unknown"]},"changeReason":<String,Object?>{"t":"s"}}}}}},
  "elecon.generic.section\u00001.0": <String,Object?>{"t":"o","r":<Object?>["sectionId","title"],"p":<String,Object?>{"sectionId":<String,Object?>{"t":"s"},"title":<String,Object?>{"t":"s"},"fields":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["label","role","value"],"p":<String,Object?>{"label":<String,Object?>{"t":"s"},"role":<String,Object?>{"t":"s","e":<Object?>["identifier","label","status","datetime","deadline","amount","quantity","link","unknown"]},"value":<String,Object?>{"o":<Object?>[<String,Object?>{"t":"s"},<String,Object?>{"t":"n"},<String,Object?>{"t":"b"},<String,Object?>{"t":"z"},<String,Object?>{"t":"o","r":<Object?>["amountMinor","currency"],"p":<String,Object?>{"amountMinor":<String,Object?>{"t":"i"},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"}}}]}}}},"table":<String,Object?>{"t":"o","r":<Object?>["columns","rows"],"p":<String,Object?>{"columns":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["label","role"],"p":<String,Object?>{"label":<String,Object?>{"t":"s"},"role":<String,Object?>{"t":"s","e":<Object?>["identifier","label","status","datetime","deadline","amount","quantity","link","unknown"]}}}},"rows":<String,Object?>{"t":"a","i":<String,Object?>{"t":"a","i":<String,Object?>{"o":<Object?>[<String,Object?>{"t":"s"},<String,Object?>{"t":"n"},<String,Object?>{"t":"b"},<String,Object?>{"t":"z"},<String,Object?>{"t":"o","r":<Object?>["amountMinor","currency"],"p":<String,Object?>{"amountMinor":<String,Object?>{"t":"i"},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"}}}]}}}}}}},
  "elecon.gpa.summary\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"gpa":<String,Object?>{"t":"n"},"earnedCredits":<String,Object?>{"t":"n","n":0},"attemptedCredits":<String,Object?>{"t":"n","n":0},"rank":<String,Object?>{"t":"i","n":1},"rankTotal":<String,Object?>{"t":"i","n":1},"window":<String,Object?>{"t":"s"},"updatedAt":<String,Object?>{"t":"s","f":"date-time"}}},
  "elecon.grades.list\u00001.0": <String,Object?>{"t":"o","r":<Object?>["term","items"],"p":<String,Object?>{"term":<String,Object?>{"t":"s"},"academicYear":<String,Object?>{"t":"s"},"termName":<String,Object?>{"t":"s"},"updatedAt":<String,Object?>{"t":"s","f":"date-time"},"page":<String,Object?>{"t":"i","n":1},"size":<String,Object?>{"t":"i","n":1},"cursor":<String,Object?>{"t":"s"},"total":<String,Object?>{"t":"i","n":0},"hasNext":<String,Object?>{"t":"b"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["courseId","courseName","credit","score","category","status"],"p":<String,Object?>{"courseId":<String,Object?>{"t":"s"},"courseName":<String,Object?>{"t":"s"},"credit":<String,Object?>{"t":"n","n":0},"creditType":<String,Object?>{"t":"s"},"courseNature":<String,Object?>{"t":"s"},"courseCategory":<String,Object?>{"t":"s"},"courseGroup":<String,Object?>{"t":"s"},"language":<String,Object?>{"t":"s"},"teacher":<String,Object?>{"t":"s"},"offeringUnit":<String,Object?>{"t":"s"},"classNo":<String,Object?>{"t":"s"},"sectionNo":<String,Object?>{"t":"s"},"examMethod":<String,Object?>{"t":"s"},"examAt":<String,Object?>{"t":"s","f":"date-time"},"retake":<String,Object?>{"t":"b"},"sourceStatus":<String,Object?>{"t":"s","e":<Object?>["normal","retake","makeup","deferred","exempt","改分","withdrawn","unknown"]},"rank":<String,Object?>{"t":"i","n":1},"gradeDistribution":<String,Object?>{"t":"o","a":<String,Object?>{"t":"i","n":0}},"courseAverage":<String,Object?>{"t":"n"},"score":<String,Object?>{"t":"o","r":<Object?>["kind","value"],"p":<String,Object?>{"kind":<String,Object?>{"t":"s","e":<Object?>["numeric","letter","passfail","unknown"]},"value":<String,Object?>{},"raw":<String,Object?>{"t":"s"},"status":<String,Object?>{"t":"s","e":<Object?>["known","unknown","absent","notReleased","exempt"]},"max":<String,Object?>{"t":"n"}}},"gradePoint":<String,Object?>{"t":"n"},"category":<String,Object?>{"t":"s","e":<Object?>["required","elective","unknown"]},"status":<String,Object?>{"t":"s","e":<Object?>["final","provisional","unknown"]}}}}}},
  "elecon.invoice.list\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"invoiceNo":<String,Object?>{"t":"s"},"amountMinor":<String,Object?>{"t":"i"},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"},"issuedAt":<String,Object?>{"t":"s","f":"date-time"},"status":<String,Object?>{"t":"s","e":<Object?>["issued","voided","processing","unknown"]},"downloadUrl":<String,Object?>{"t":"s","f":"uri"}}}}}},
  "elecon.library.booking\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"id":<String,Object?>{"t":"s"},"library":<String,Object?>{"t":"s"},"room":<String,Object?>{"t":"s"},"seatId":<String,Object?>{"t":"s"},"startAt":<String,Object?>{"t":"s","f":"date-time"},"endAt":<String,Object?>{"t":"s","f":"date-time"},"status":<String,Object?>{"t":"s","e":<Object?>["reserved","cancelled","checkedIn","expired","unknown"]}}}}}},
  "elecon.library.loans\u00001.0": <String,Object?>{"t":"o","r":<Object?>["items"],"p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["bookId","title","borrowedAt","dueAt"],"p":<String,Object?>{"bookId":<String,Object?>{"t":"s"},"title":<String,Object?>{"t":"s"},"author":<String,Object?>{"t":"s"},"callNumber":<String,Object?>{"t":"s"},"location":<String,Object?>{"t":"s"},"branch":<String,Object?>{"t":"s"},"borrowedAt":<String,Object?>{"t":"s","f":"date-time"},"dueAt":<String,Object?>{"t":"s","f":"date-time"},"renewCount":<String,Object?>{"t":"i","n":0},"renewalMax":<String,Object?>{"t":"i","n":0},"renewable":<String,Object?>{"t":"b"},"overdue":<String,Object?>{"t":"b"},"overdueFee":<String,Object?>{"t":"o","r":<Object?>["amountMinor","currency"],"p":<String,Object?>{"amountMinor":<String,Object?>{"t":"i","n":0},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"}}},"reserved":<String,Object?>{"t":"b"},"pickupDeadline":<String,Object?>{"t":"s","f":"date-time"},"renewalDeadline":<String,Object?>{"t":"s","f":"date-time"},"returnConfirmed":<String,Object?>{"t":"b"}}}}}},
  "elecon.library.seats\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"library":<String,Object?>{"t":"s"},"floor":<String,Object?>{"t":"s"},"seatId":<String,Object?>{"t":"s"},"status":<String,Object?>{"t":"s","e":<Object?>["available","occupied","reserved","unknown"]},"availableFrom":<String,Object?>{"t":"s","f":"date-time"},"availableUntil":<String,Object?>{"t":"s","f":"date-time"}}}}}},
  "elecon.notice.detail\u00001.0": <String,Object?>{"t":"o","r":<Object?>["id","title"],"p":<String,Object?>{"id":<String,Object?>{"t":"s"},"title":<String,Object?>{"t":"s"},"content":<String,Object?>{"t":"s"},"updatedAt":<String,Object?>{"t":"s","f":"date-time"},"attachments":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["name","url"],"p":<String,Object?>{"name":<String,Object?>{"t":"s"},"url":<String,Object?>{"t":"s","f":"uri"}}}}}},
  "elecon.notice.list\u00001.1": <String,Object?>{"t":"o","r":<Object?>["items"],"p":<String,Object?>{"page":<String,Object?>{"t":"i","n":1},"size":<String,Object?>{"t":"i","n":1},"cursor":<String,Object?>{"t":"s"},"total":<String,Object?>{"t":"i","n":0},"hasNext":<String,Object?>{"t":"b"},"updatedAt":<String,Object?>{"t":"s","f":"date-time"},"sourceSystem":<String,Object?>{"t":"s"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["id","title","category","source"],"p":<String,Object?>{"id":<String,Object?>{"t":"s"},"title":<String,Object?>{"t":"s"},"summary":<String,Object?>{"t":"s"},"content":<String,Object?>{"t":"s"},"author":<String,Object?>{"t":"s"},"department":<String,Object?>{"t":"s"},"audience":<String,Object?>{"t":"a","i":<String,Object?>{"t":"s"}},"tags":<String,Object?>{"t":"a","i":<String,Object?>{"t":"s"}},"pinned":<String,Object?>{"t":"b"},"importance":<String,Object?>{"t":"s","e":<Object?>["normal","important","urgent","unknown"]},"validFrom":<String,Object?>{"t":"s","f":"date-time"},"validUntil":<String,Object?>{"t":"s","f":"date-time"},"status":<String,Object?>{"t":"s","e":<Object?>["draft","published","withdrawn","expired","unknown"]},"attachments":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["name","url"],"p":<String,Object?>{"name":<String,Object?>{"t":"s"},"url":<String,Object?>{"t":"s","f":"uri"},"sizeBytes":<String,Object?>{"t":"i","n":0},"mimeType":<String,Object?>{"t":"s"}}}},"url":<String,Object?>{"t":"s","f":"uri"},"publishedAt":<String,Object?>{"t":"s","f":"date-time"},"category":<String,Object?>{"t":"s","e":<Object?>["academic","admin","event","unknown"]},"source":<String,Object?>{"t":"s"}}}}}},
  "elecon.profile.me\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"name":<String,Object?>{"t":"s"},"studentIdMasked":<String,Object?>{"t":"s"},"department":<String,Object?>{"t":"s"},"major":<String,Object?>{"t":"s"},"grade":<String,Object?>{"t":"s"},"identityType":<String,Object?>{"t":"s","e":<Object?>["undergraduate","graduate","faculty","staff","other","unknown"]},"campus":<String,Object?>{"t":"s"},"updatedAt":<String,Object?>{"t":"s","f":"date-time"}}},
  "elecon.program.progress\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"requiredCredits":<String,Object?>{"t":"n"},"completedCredits":<String,Object?>{"t":"n"},"remainingCredits":<String,Object?>{"t":"n"},"status":<String,Object?>{"t":"s","e":<Object?>["inProgress","completed","unknown"]},"groups":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"name":<String,Object?>{"t":"s"},"requiredCredits":<String,Object?>{"t":"n"},"completedCredits":<String,Object?>{"t":"n"}}}}}},
  "elecon.research.income\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"month":<String,Object?>{"t":"s"},"amountMinor":<String,Object?>{"t":"i"},"currency":<String,Object?>{"t":"s","g":"^[A-Z]{3}\$"},"status":<String,Object?>{"t":"s","e":<Object?>["pending","paid","failed","unknown"]},"source":<String,Object?>{"t":"s"}}}}}},
  "elecon.schedule.week\u00001.0": <String,Object?>{"t":"o","r":<Object?>["term","week","days"],"p":<String,Object?>{"term":<String,Object?>{"t":"s"},"academicYear":<String,Object?>{"t":"s"},"termStartDate":<String,Object?>{"t":"s","f":"date"},"termEndDate":<String,Object?>{"t":"s","f":"date"},"teachingWeekStart":<String,Object?>{"t":"s","f":"date"},"teachingWeekEnd":<String,Object?>{"t":"s","f":"date"},"weekType":<String,Object?>{"t":"s","e":<Object?>["teaching","exam","holiday","unknown"]},"updatedAt":<String,Object?>{"t":"s","f":"date-time"},"sourceSystem":<String,Object?>{"t":"s"},"week":<String,Object?>{"t":"i","n":1},"days":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["dayOfWeek","slots"],"p":<String,Object?>{"dayOfWeek":<String,Object?>{"t":"i","n":1,"x":7},"slots":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["start","end","courseName"],"p":<String,Object?>{"start":<String,Object?>{"t":"s"},"end":<String,Object?>{"t":"s"},"courseName":<String,Object?>{"t":"s"},"courseId":<String,Object?>{"t":"s"},"date":<String,Object?>{"t":"s","f":"date"},"timeStart":<String,Object?>{"t":"s"},"timeEnd":<String,Object?>{"t":"s"},"campus":<String,Object?>{"t":"s"},"building":<String,Object?>{"t":"s"},"room":<String,Object?>{"t":"s"},"roomCapacity":<String,Object?>{"t":"i","n":0},"courseNature":<String,Object?>{"t":"s"},"classNo":<String,Object?>{"t":"s"},"language":<String,Object?>{"t":"s"},"courseUrl":<String,Object?>{"t":"s","f":"uri"},"group":<String,Object?>{"t":"s"},"onlineUrl":<String,Object?>{"t":"s","f":"uri"},"meetingNumberPresent":<String,Object?>{"t":"b"},"meetingPasswordPresent":<String,Object?>{"t":"b"},"changeType":<String,Object?>{"t":"s","e":<Object?>["none","rescheduled","cancelled","makeup","substitute","temporaryRoom","unknown"]},"changeReason":<String,Object?>{"t":"s"},"weekExceptions":<String,Object?>{"t":"a","i":<String,Object?>{"t":"i","n":1}},"teacher":<String,Object?>{"t":"s"},"location":<String,Object?>{"t":"s"},"weeks":<String,Object?>{"t":"a","i":<String,Object?>{"t":"i"}}}}}}}}}},
  "elecon.term.list\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"currentTerm":<String,Object?>{"t":"s"},"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","r":<Object?>["id","name"],"p":<String,Object?>{"id":<String,Object?>{"t":"s"},"name":<String,Object?>{"t":"s"},"academicYear":<String,Object?>{"t":"s"},"startDate":<String,Object?>{"t":"s","f":"date"},"endDate":<String,Object?>{"t":"s","f":"date"},"teachingWeeks":<String,Object?>{"t":"i","n":0}}}}}},
  "elecon.transport.schedule\u00001.0": <String,Object?>{"t":"o","p":<String,Object?>{"items":<String,Object?>{"t":"a","i":<String,Object?>{"t":"o","p":<String,Object?>{"route":<String,Object?>{"t":"s"},"stop":<String,Object?>{"t":"s"},"departureAt":<String,Object?>{"t":"s","f":"date-time"},"operatingDate":<String,Object?>{"t":"s","f":"date"},"status":<String,Object?>{"t":"s","e":<Object?>["scheduled","delayed","cancelled","unknown"]}}}}}},
};

bool _validate(Object? value, Map<String, Object?> schema) {
  final choices = schema['o'];
  if (choices is List && choices.where((s) => _validate(value, (s as Map).cast<String, Object?>())).length != 1) {
    return false;
  }
  if (schema.containsKey('c') && !_jsonEqual(value, schema['c'])) return false;
  final allowed = schema['e'];
  if (allowed is List && !allowed.any((item) => _jsonEqual(value, item))) return false;

  switch (schema['t']) {
    case 'o':
      if (value is! Map || value.keys.any((key) => key is! String)) return false;
      final object = value.cast<String, Object?>();
      final required = schema['r'];
      if (required is List && required.any((key) => !object.containsKey(key))) return false;
      final properties = (schema['p'] as Map?)?.cast<String, Object?>() ?? const {};
      for (final entry in object.entries) {
        final child = properties[entry.key];
        if (child is Map) {
          if (!_validate(entry.value, child.cast<String, Object?>())) return false;
        } else {
          final additional = schema['a'];
          if (additional == false) return false;
          if (additional is Map && !_validate(entry.value, additional.cast<String, Object?>())) return false;
        }
      }
      break;
    case 'a':
      if (value is! List) return false;
      final min = schema['q'];
      final max = schema['m'];
      if (min is int && value.length < min || max is int && value.length > max) return false;
      final item = schema['i'];
      if (item is Map && value.any((v) => !_validate(v, item.cast<String, Object?>()))) return false;
      break;
    case 's':
      if (value is! String) return false;
      final length = value.runes.length;
      final min = schema['l'];
      final max = schema['L'];
      if (min is int && length < min || max is int && length > max) return false;
      final pattern = schema['g'];
      if (pattern is String && !RegExp(pattern).hasMatch(value)) return false;
      final format = schema['f'];
      if (format is String && !_validFormat(value, format)) return false;
      break;
    case 'n':
      if (value is! num || !value.isFinite) return false;
      if (!_validRange(value, schema)) return false;
      break;
    case 'i':
      if (value is! num || !value.isFinite || value != value.truncateToDouble()) return false;
      if (!_validRange(value, schema)) return false;
      break;
    case 'b':
      if (value is! bool) return false;
      break;
    case 'z':
      if (value != null) return false;
      break;
  }
  return true;
}

bool _validRange(num value, Map<String, Object?> schema) {
  final min = schema['n'];
  final max = schema['x'];
  return (min is! num || value >= min) && (max is! num || value <= max);
}

bool _validFormat(String value, String format) {
  if (format == 'date') {
    return _validDate(value);
  }
  if (format == 'date-time') {
    final match = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))$').firstMatch(value);
    if (match == null || !_validDate(match[1]!)) return false;
    if (int.parse(match[2]!) > 23 || int.parse(match[3]!) > 59 || int.parse(match[4]!) > 59) return false;
    if (match[5] != null && (int.parse(match[5]!) > 23 || int.parse(match[6]!) > 59)) return false;
    return DateTime.tryParse(value) != null;
  }
  if (format == 'uri') {
    if (value.contains(RegExp(r'\s'))) return false;
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme.isNotEmpty && RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*$').hasMatch(uri.scheme);
  }
  return false;
}

bool _validDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.year == int.parse(match[1]!) && parsed.month == int.parse(match[2]!) && parsed.day == int.parse(match[3]!);
}

bool _jsonEqual(Object? a, Object? b) {
  if (a is List && b is List) {
    return a.length == b.length && List.generate(a.length, (i) => i).every((i) => _jsonEqual(a[i], b[i]));
  }
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((key) => b.containsKey(key) && _jsonEqual(a[key], b[key]));
  }
  return a == b;
}
