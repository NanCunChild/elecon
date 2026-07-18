// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class TransportSchedule {
  const TransportSchedule({
    this.items,
  });

  final List<TransportScheduleItems>? items;
}

class TransportScheduleItems {
  const TransportScheduleItems({
    this.route,
    this.stop,
    this.departureAt,
    this.operatingDate,
    this.status,
  });

  final String? route;
  final String? stop;
  final String? departureAt;
  final String? operatingDate;
  final String? status;
}
