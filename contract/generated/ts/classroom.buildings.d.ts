// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ClassroomBuildings {
  campus?: string;
  term?: string;
  items?: ClassroomBuildingsItems[];
}

export interface ClassroomBuildingsItems {
  campus?: string;
  /** 教学楼展示名；禁止空串；未知填 "-" */
  building: string;
  buildingId?: string;
  roomCount?: number;
}
