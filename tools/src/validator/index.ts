/**
 * adapter 校验器（CI 闸门）。契约校验用 ajv，与服务端共用一套。
 *
 * 将校验：
 *  - manifest 对 contract/manifest.schema.json 的合规性；
 *  - network.allow 白名单与已注册 capability 的对应；
 *  - sideload 信任档**强制** parser 模式（拒绝 sideload + fetch）；
 *  - 所有 capability id 存在于 contract/capability/registry.json；
 *  - 夹具 golden 测试：客户端 QuickJS 与服务端 QuickJS-wasm 双跑对同一夹具产出一致
 *    （两端同引擎，理应零漂移）。
 *
 * 尚未实现。
 */

function main(): void {
  console.log("adapter validator (Node/TS, ajv): not implemented yet");
  console.log("");
  console.log("Will validate:");
  console.log("  - manifest schema conformance (ajv)");
  console.log("  - network allow list against registered capabilities");
  console.log("  - sideload trust tier must use parser mode");
  console.log("  - all capability ids exist in registry.json");
  console.log("  - fixture golden tests (QuickJS client / QuickJS-wasm server dual-run)");
}

main();
