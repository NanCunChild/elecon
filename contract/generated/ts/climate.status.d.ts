// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ClimateStatus {
  /** 本次状态对应的已绑定设备。 */
  deviceId: string;
  /** 目标电源开关；非本次变更则省略。 */
  power?: boolean;
  /** 目标模式；非本次变更则省略。 */
  mode?: "fan" | "heat" | "cool" | "dry" | "auto";
  /** 目标风速；非本次变更则省略。 */
  fanSpeed?: "auto" | "silent" | "low" | "medium" | "high";
  /** 目标摄氏温度；还须满足该设备范围。 */
  targetTemperature?: number;
  /** 目标上下扫风开关。 */
  verticalSwing?: boolean;
  /** 目标强力开关。 */
  turbo?: boolean;
  /** 目标辅热开关。 */
  auxiliaryHeat?: boolean;
  /** 室内摄氏温度；未提供时省略。 */
  indoorTemperature?: number;
  /** 剩余电量，与 unit 同单位；来源不能证明语义时省略。 */
  remainingEnergy?: number;
  /** remainingEnergy 的单位；缺失余量时可省略。 */
  unit?: string;
  /** 设备状态采样时刻，RFC3339/UTC；未知时省略。 */
  observedAt?: string;
  /** 净化后的设备错误分类，不含远端原始消息。 */
  errorCode?: string;
  /** 设备明确报告的在线状态；未知时省略。 */
  online?: boolean;
  /** 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。 */
  indoorClean?: boolean;
  /** 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。 */
  outdoorClean?: boolean;
}
