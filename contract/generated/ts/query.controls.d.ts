// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface QueryControls {
  /** 这些控件绑定的同包只读领域查询；必须与请求target一致。 */
  target: "grades.list" | "classroom.available";
  /** 条件对话框的纯文本标题，脚本按当前语言返回。 */
  title: string;
  /** 显式应用条件并查询的按钮纯文本，不表示另一个能力或命令。 */
  submitLabel: string;
  /** 固定原生控件描述；id和绑定参数均唯一，组合由原生消费者再次校验。 */
  controls: QueryControlsControls[];
}

export interface QueryControlsControls {
  /** 此组条件内稳定唯一的控件标识，不是可执行函数名。 */
  id: string;
  /** 固定原生输入种类，不接受脚本或HTML。 */
  kind: "select" | "text" | "date" | "timeRange";
  /** 输入标签纯文本，脚本按当前语言返回。 */
  label: string;
  /** 绑定已有标准参数；grades仅term；教室date/room；timeRange固定start并同时生成end。 */
  parameter: "term" | "date" | "room" | "start";
  /** 可选默认值；省略表示沿当前参数或留空。timeRange格式HH:mm，必须与initialEnd同时给出。 */
  initialValue?: string;
  /** 仅timeRange可用的默认结束时刻HH:mm，与initialValue同日且更晚。 */
  initialEnd?: string;
  /** 仅select需要的唯一可选值列表，标签不是请求参数。 */
  options?: QueryControlsControlsOptions[];
}

export interface QueryControlsControlsOptions {
  /** 送给领域参数的稳定字符串值。 */
  value: string;
  /** 供用户阅读的纯文本选项名称。 */
  label: string;
}
