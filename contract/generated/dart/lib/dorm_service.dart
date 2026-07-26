// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class DormService {
  const DormService({
    this.items,
  });

  /// 宿舍服务记录列表；可选，缺失表示学校不提供。
  final List<DormServiceItems>? items;
}

class DormServiceItems {
  const DormServiceItems({
    this.id,
    this.type,
    this.description,
    this.status,
    this.updatedAt,
  });

  /// 校内作用域的宿舍服务记录标识；可选，缺失表示学校不提供。
  final String? id;
  /// 宿舍服务类型；可选，缺失表示学校不提供。
  final String? type;
  /// 宿舍服务事项描述；可选，缺失表示学校不提供。
  final String? description;
  /// 服务状态：submitted=已提交，processing=处理中，completed=已完成，cancelled=已取消，unknown=未知；可选，缺失表示学校不提供。
  final String? status;
  /// 服务记录最近更新时间，RFC3339/UTC；可选，缺失表示学校不提供。
  final String? updatedAt;
}
