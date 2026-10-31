// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ClimateStatus {
  const ClimateStatus({
    required this.deviceId,
    this.power,
    this.mode,
    this.fanSpeed,
    this.targetTemperature,
    this.verticalSwing,
    this.turbo,
    this.auxiliaryHeat,
    this.indoorTemperature,
    this.remainingEnergy,
    this.unit,
    this.observedAt,
    this.errorCode,
    this.online,
    this.indoorClean,
    this.outdoorClean,
  });

  /// 本次状态对应的已绑定设备。
  final String deviceId;
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
  /// 室内摄氏温度；未提供时省略。
  final num? indoorTemperature;
  /// 剩余电量，与 unit 同单位；来源不能证明语义时省略。
  final num? remainingEnergy;
  /// remainingEnergy 的单位；缺失余量时可省略。
  final String? unit;
  /// 设备状态采样时刻，RFC3339/UTC；未知时省略。
  final String? observedAt;
  /// 净化后的设备错误分类，不含远端原始消息。
  final String? errorCode;
  /// 设备明确报告的在线状态；未知时省略。
  final bool? online;
  /// 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。
  final bool? indoorClean;
  /// 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。
  final bool? outdoorClean;
}
