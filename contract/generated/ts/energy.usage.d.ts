// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface EnergyUsage {
  items?: EnergyUsageItems[];
}

export interface EnergyUsageItems {
  campus?: string;
  dormitory?: string;
  room?: string;
  type?: "water" | "electricity" | "unknown";
  reading?: number;
  usage?: number;
  unit?: string;
  from?: string;
  to?: string;
}
