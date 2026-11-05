// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ClimateDevices {
  const ClimateDevices({
    required this.items,
  });

  /// 当前学校身份下用户明确保存的本地绑定及有限控制范围；允许离线读取，不证明设备当前在线或控制可达。
  final List<ClimateDevicesItems> items;
}

class ClimateDevicesItems {
  const ClimateDevicesItems({
    required this.deviceId,
    required this.label,
    this.minTemperature,
    this.maxTemperature,
    this.modes,
    this.fanSpeeds,
    required this.commands,
    this.modeDefaults,
    this.powerOffClearsAuxiliaryHeat,
    this.fanSpeedClearsTurbo,
    this.turboUsesAutoFan,
    this.powerOffClearsCleaning,
    this.bindingVerifiedAt,
  });

  /// 当前学校身份下用户明确绑定的设备标识。
  final String deviceId;
  /// 用户友好名称，不包含完整设备标识。
  final String label;
  /// 设备最低设定摄氏温度。
  final int? minTemperature;
  /// 设备最高设定摄氏温度。
  final int? maxTemperature;
  /// 设备支持的模式。
  final List<String>? modes;
  /// 设备支持的风速。
  final List<String>? fanSpeeds;
  /// 设备允许的有限控制项。
  final List<String> commands;
  /// 切模式时必须一并确认的完整设置；由提供者声明。
  final List<ClimateDevicesItemsModeDefaults>? modeDefaults;
  /// 关机是否同时关闭辅热。
  final bool? powerOffClearsAuxiliaryHeat;
  /// 设置风速是否同时关闭强力。
  final bool? fanSpeedClearsTurbo;
  /// 开启强力是否同时使用自动风速。
  final bool? turboUsesAutoFan;
  /// 关机是否同时关闭室内和室外清洁。
  final bool? powerOffClearsCleaning;
  /// 脚本最后成功通过只读状态核验该绑定的时刻，RFC3339/UTC；缺失表示旧记录未提供，不是当前读数或在线证据。
  final String? bindingVerifiedAt;
}

class ClimateDevicesItemsModeDefaults {
  const ClimateDevicesItemsModeDefaults({
    this.power,
    required this.mode,
    required this.fanSpeed,
    required this.targetTemperature,
    this.verticalSwing,
    required this.turbo,
    required this.auxiliaryHeat,
    required this.indoorClean,
    required this.outdoorClean,
  });

  /// 目标电源开关；非本次变更则省略。
  final bool? power;
  /// 目标模式；非本次变更则省略。
  final String mode;
  /// 目标风速；非本次变更则省略。
  final String fanSpeed;
  /// 目标摄氏温度；还须满足该设备范围。
  final int targetTemperature;
  /// 目标上下扫风开关。
  final bool? verticalSwing;
  /// 目标强力开关。
  final bool turbo;
  /// 目标辅热开关。
  final bool auxiliaryHeat;
  /// 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。
  final bool indoorClean;
  /// 本次操作联动的清洁模式开关；仅用于完整确认及状态核验，不新增独立控制项。
  final bool outdoorClean;
}
