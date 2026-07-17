// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

/// 所有合法 capability id —— 契约单源 contract/capability/registry.json。
/// 客户端加载器据此拒绝 catalog 引入 registry 之外的新能力（ADR-010 §3.3.2(a)，红线 #6）。
const Set<String> kCapabilityIds = {
  'card.balance',
  'card.transactions',
  'generic.section',
  'grades.list',
  'library.loans',
  'notice.list',
  'schedule.week',
};
