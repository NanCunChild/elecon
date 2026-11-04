// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface QueryControls {
  /** 同来源、同包只读查询目标；必须与请求target一致。 */
  target: "grades.list" | "classroom.available";
  /** 原生表单的纯文本标题。 */
  title: string;
  /** 显式提交查询的按钮纯文本；不能绑定其他能力或命令。 */
  submitLabel: string;
  /** 0–32个字段实例；允许同kind多个不同id。完整元数据最多128KiB UTF-8，语义组合由宿主和脚本再校验。 */
  controls: QueryControlsControls[];
}

export interface QueryControlsControls {
  /** 同组稳定唯一字段标识；仅作为filters键，不是宿主参数或执行入口。 */
  id: string;
  /** 宿主固定控件种类，学校业务含义由脚本定义。 */
  kind: "text" | "number" | "boolean" | "select" | "multiSelect" | "date" | "timeRange";
  /** 字段纯文本标签。 */
  label: string;
  /** 可选纯文本帮助说明；省略表示没有附加说明。 */
  description?: string;
  /** 是否必须填写；省略等于false。false和0属于有效值。 */
  required?: boolean;
  /** 字段当前是否不可用；省略等于false，禁用字段不得提交。 */
  disabled?: boolean;
  /** 字段暂不可用的纯文本原因；disabled=true时应提供。 */
  disabledReason?: string;
  /** 仅用于初始化或无已有有效值时的默认值；类型须匹配kind且满足当前约束/选项，省略表示空值。 */
  initialValue?: string | number | boolean | string[] | QueryControlsControlsInitialValue;
  /** select/multiSelect所需选项，value同组唯一；空数组表示当前没有可选项，依赖未就绪时声明disabled及原因。 */
  options?: QueryControlsControlsOptions[];
  /** 仅number：允许的最小值（含），必须有限；省略不设下界。 */
  minimum?: number;
  /** 仅number：允许的最大值（含），必须有限且不小于minimum；省略不设上界。 */
  maximum?: number;
  /** 仅number：true要求整数；省略等于false。 */
  integer?: boolean;
  /** 仅text：最大Unicode字符数，1–512；省略使用512。 */
  maxLength?: number;
  /** 上游字段id，必须存在、无自身引用且依赖无环；改变上游清除递归下游值再读取元数据。省略表示无依赖。 */
  dependsOn?: string[];
  /** 仅timeRange且必填：学校解释墙钟时刻所用IANA时区名称，不能从设备地区推断。 */
  timeZone?: string;
  /** 2.1：true表示可选叶子字段待只读补充，不呈现或提交；不得required=true或含initialValue，其依赖须为普通字段。disabled时不加载；省略或false表示已解析。补充响应仅替换请求字段并保持id/kind/dependsOn，不能新增必填条件。 */
  deferred?: boolean;
}

export interface QueryControlsControlsInitialValue {
  /** 同日开始墙钟时刻，HH:mm；必须早于end。 */
  start: string;
  /** 同日结束墙钟时刻，HH:mm；不含该时刻。 */
  end: string;
}

export interface QueryControlsControlsOptions {
  /** 提交给学校脚本的稳定字符串值，标签不参与寻址。 */
  value: string;
  /** 选项纯文本名称。 */
  label: string;
}
