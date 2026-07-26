// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ClassroomBuildings {
  /** 楼栋列表所属校区；缺失表示未按校区筛选或来源未提供。 */
  campus?: string;
  /** 楼栋列表所属学期标识；缺失表示未按学期筛选或来源未提供。 */
  term?: string;
  /** 可用于空教室查询的教学楼列表；无可用楼栋时可为空数组。 */
  items?: ClassroomBuildingsItems[];
}

export interface ClassroomBuildingsItems {
  /** 教学楼所属校区；缺失表示来源未提供。 */
  campus?: string;
  /** 教学楼展示名；禁止空串；未知填 "-" */
  building: string;
  /** 教学楼在校内系统中的标识或代码；缺失表示来源未提供。 */
  buildingId?: string;
  /** 教学楼内教室数量，单位为间；缺失表示来源未提供。 */
  roomCount?: number;
}
