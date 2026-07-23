// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsClassroomAvailable {
  const ParamsClassroomAvailable({
    this.date,
    this.term,
    this.week,
    this.weekday,
    this.campus,
    this.building,
    this.buildingId,
    this.room,
    this.roomId,
    this.start,
    this.end,
    this.timeZone,
    this.sectionStart,
    this.sectionEnd,
    this.onlyAvailable,
  });

  /// 查询日历日 YYYY-MM-DD
  final String? date;
  /// 学期标识，如 2025-2026-2；省略=当前学期（若源站需要）
  final String? term;
  /// 教学周序号
  final int? week;
  /// 星期 1=周一 … 7=周日
  final int? weekday;
  /// 校区名称或校内 code（校作用域）
  final String? campus;
  /// 教学楼展示名；模糊匹配时 adapter 自定，优先用 buildingId
  final String? building;
  /// 教学楼校内 id/code（如西电 JXLDM）
  final String? buildingId;
  /// 教室展示名过滤
  final String? room;
  /// 教室校内 id
  final String? roomId;
  /// 窗口起点，推荐 HH:mm（墙钟）
  final String? start;
  /// 窗口终点，推荐 HH:mm（墙钟）
  final String? end;
  /// IANA 时区；调用方可选提示；权威声明在 adapter emits
  final String? timeZone;
  /// 节次窗口起点（含），1-based
  final int? sectionStart;
  /// 节次窗口终点（含），1-based；须 ≥ sectionStart
  final int? sectionEnd;
  /// true=只返回在查询窗口内判定为空闲的教室；默认 false=返回楼内对照列表
  final bool? onlyAvailable;
}
