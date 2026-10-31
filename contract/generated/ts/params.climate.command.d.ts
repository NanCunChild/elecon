// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsClimateCommand {
  /** 当前身份已绑定并通过查询验证的设备。 */
  deviceId: string;
  /** 有限控制项；settings 必须与该操作及设备联动规则一致。 */
  command: "power" | "temperature" | "mode" | "fanSpeed" | "verticalSwing" | "turbo" | "auxiliaryHeat";
  /** 用户确认的完整目标变更；不接受任意学校 JSON。 */
  settings: ParamsClimateCommandSettings;
}

export interface ParamsClimateCommandSettings {
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
  /** 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。 */
  indoorClean?: boolean;
  /** 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。 */
  outdoorClean?: boolean;
}
