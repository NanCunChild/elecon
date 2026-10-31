// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsClimateCommand {
  const ParamsClimateCommand({
    required this.deviceId,
    required this.command,
    required this.settings,
  });

  /// 当前身份已绑定并通过查询验证的设备。
  final String deviceId;
  /// 有限控制项；settings 必须与该操作及设备联动规则一致。
  final String command;
  /// 用户确认的完整目标变更；不接受任意学校 JSON。
  final ParamsClimateCommandSettings settings;
}

class ParamsClimateCommandSettings {
  const ParamsClimateCommandSettings({
    this.power,
    this.mode,
    this.fanSpeed,
    this.targetTemperature,
    this.verticalSwing,
    this.turbo,
    this.auxiliaryHeat,
    this.indoorClean,
    this.outdoorClean,
  });

  /// 目标电源开关；非本次变更则省略。
  final bool? power;
  /// 目标模式；非本次变更则省略。
  final String? mode;
  /// 目标风速；非本次变更则省略。
  final String? fanSpeed;
  /// 目标摄氏温度；还须满足该设备范围。
  final int? targetTemperature;
  /// 目标上下扫风开关。
  final bool? verticalSwing;
  /// 目标强力开关。
  final bool? turbo;
  /// 目标辅热开关。
  final bool? auxiliaryHeat;
  /// 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。
  final bool? indoorClean;
  /// 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。
  final bool? outdoorClean;
}
