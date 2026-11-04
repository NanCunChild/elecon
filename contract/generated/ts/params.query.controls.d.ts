// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsQueryControls {
  /** 要描述字段的同包只读查询目标。 */
  target: "grades.list" | "classroom.available";
  /** 当前字段草稿，最多32项/32KiB UTF-8；字段值不是宿主参数。省略表示读取初始表单，空值省略对应key。 */
  current?: Record<string, string | number | boolean | string[] | ParamsQueryControlsCurrentValue>;
  /** 本次改变的字段id，用于重新求取依赖选项；无用户字段变更时省略。 */
  changed?: string;
}

export interface ParamsQueryControlsCurrentValue {
  /** 同日开始墙钟时刻，HH:mm；必须早于end。 */
  start: string;
  /** 同日结束墙钟时刻，HH:mm；不含该时刻。 */
  end: string;
}
