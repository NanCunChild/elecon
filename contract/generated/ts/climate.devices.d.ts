// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ClimateDevices {
  /** 当前学校身份下用户明确保存的本地绑定及有限控制范围；允许离线读取，不证明设备当前在线或控制可达。 */
  items: ClimateDevicesItems[];
}

export interface ClimateDevicesItems {
  /** 当前学校身份下用户明确绑定的设备标识。 */
  deviceId: string;
  /** 用户友好名称，不包含完整设备标识。 */
  label: string;
  /** 设备最低设定摄氏温度。 */
  minTemperature?: number;
  /** 设备最高设定摄氏温度。 */
  maxTemperature?: number;
  /** 设备支持的模式。 */
  modes?: "fan" | "heat" | "cool" | "dry" | "auto"[];
  /** 设备支持的风速。 */
  fanSpeeds?: "auto" | "silent" | "low" | "medium" | "high"[];
  /** 设备允许的有限控制项。 */
  commands: "power" | "temperature" | "mode" | "fanSpeed" | "verticalSwing" | "turbo" | "auxiliaryHeat"[];
  /** 切模式时必须一并确认的完整设置；由提供者声明。 */
  modeDefaults?: ClimateDevicesItemsModeDefaults[];
  /** 关机是否同时关闭辅热。 */
  powerOffClearsAuxiliaryHeat?: boolean;
  /** 设置风速是否同时关闭强力。 */
  fanSpeedClearsTurbo?: boolean;
  /** 开启强力是否同时使用自动风速。 */
  turboUsesAutoFan?: boolean;
  /** 关机是否同时关闭室内和室外清洁。 */
  powerOffClearsCleaning?: boolean;
  /** 脚本最后成功通过只读状态核验该绑定的时刻，RFC3339/UTC；缺失表示旧记录未提供，不是当前读数或在线证据。 */
  bindingVerifiedAt?: string;
}

export interface ClimateDevicesItemsModeDefaults {
  /** 目标电源开关；非本次变更则省略。 */
  power?: boolean;
  /** 目标模式；非本次变更则省略。 */
  mode: "fan" | "heat" | "cool" | "dry" | "auto";
  /** 目标风速；非本次变更则省略。 */
  fanSpeed: "auto" | "silent" | "low" | "medium" | "high";
  /** 目标摄氏温度；还须满足该设备范围。 */
  targetTemperature: number;
  /** 目标上下扫风开关。 */
  verticalSwing?: boolean;
  /** 目标强力开关。 */
  turbo: boolean;
  /** 目标辅热开关。 */
  auxiliaryHeat: boolean;
  /** 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。 */
  indoorClean: boolean;
  /** 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。 */
  outdoorClean: boolean;
}
