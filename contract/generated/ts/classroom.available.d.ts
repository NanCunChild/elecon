// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ClassroomAvailable {
  date?: string;
  start?: string;
  end?: string;
  items?: ClassroomAvailableItems[];
}

export interface ClassroomAvailableItems {
  campus?: string;
  building: string;
  room: string;
  capacity?: number;
  equipment?: string[];
  occupied?: boolean;
  status?: "available" | "occupied" | "unknown";
}
