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

  final String? accountStatus;
  final int? usageBytes;
  final bool? online;
  final List<CampusNetworkDevices>? devices;
}

class CampusNetworkDevices {
  const CampusNetworkDevices({
    this.id,
    this.name,
    this.online,
  });

  final String? id;
  final String? name;
  final bool? online;
}
