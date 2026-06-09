/**
 * codegen：JSON Schema（contract/schema/，唯一事实来源）→ Dart / TS 类型。
 *
 * 宿主在边界处校验：客户端核心 Dart、服务端 TS（ajv）。生成 Dart 与 TS 两套
 * 类型供两端消费（ADR-001 §3.1，服务端语言见 ADR-005）。
 *
 * 尚未实现。
 */

function main(): void {
  console.log("codegen (Node/TS): not implemented yet");
  console.log("Will generate Dart and TS types from contract/schema/*.schema.json");
}

main();
