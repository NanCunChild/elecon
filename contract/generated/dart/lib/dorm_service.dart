// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class DormService {
  const DormService({
    this.items,
  });

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

  final String? id;
  final String? type;
  final String? description;
  final String? status;
  final String? updatedAt;
}
