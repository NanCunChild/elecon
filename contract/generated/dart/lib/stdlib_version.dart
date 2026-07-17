// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

/// 本端随 app 打包的 elecon:html stdlib 版本 —— 契约单源
/// adapters/_stdlib/package.json（与 server 双端锁步，ADR-018 §2.4 B-host）。
/// 加载器 stdlibMin 门据此 fail-closed：本端 < bundle manifest 声明的 stdlibMin → 拒载。
const String kHostStdlibVersion = '1.0.0';
