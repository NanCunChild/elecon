// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CampusNetwork {
  const CampusNetwork({
    this.accountStatus,
    this.usageBytes,
    this.online,
    this.devices,
  });

  /// 校园网账号状态：active=已启用，disabled=已停用，unknown=无法识别；缺失表示来源未提供。
  final String? accountStatus;
  /// 校园网流量用量，单位为字节；缺失表示来源未提供。
  final int? usageBytes;
  final bool? online;
  /// 校园网账号关联的设备列表；缺失表示来源未提供设备信息。
  final List<CampusNetworkDevices>? devices;
}

class CampusNetworkDevices {
  const CampusNetworkDevices({
    this.id,
    this.name,
    this.online,
  });

  /// 设备在校园网系统中的标识；缺失表示来源未提供。
  final String? id;
  /// 设备名称；缺失表示来源未提供。
  final String? name;
  /// 该设备当前是否在线；缺失表示来源未提供在线状态。
  final bool? online;
}
