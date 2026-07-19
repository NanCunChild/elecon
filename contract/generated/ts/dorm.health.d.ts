// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface DormHealth {
  items?: DormHealthItems[];
}

export interface DormHealthItems {
  metric?: string;
  value?: number;
  unit?: string;
  measuredAt?: string;
  status?: "normal" | "abnormal" | "unknown";
}
