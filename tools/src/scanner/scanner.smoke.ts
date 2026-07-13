/**
 * scanner 冒烟测试 —— 针对 scanLine / isValidChineseId / luhnValid 的纯逻辑断言。
 * 端到端扫描（碰真实文件）由 `npm run scan` 在 CI 跑。
 *
 *   运行：cd tools && npx tsx src/scanner/scanner.smoke.ts
 */

import { strict as assert } from "node:assert";
import { isValidChineseId, luhnValid, scanLine } from "./index.js";

function codes(findings: { code: string }[]): string[] {
  return findings.map((f) => f.code);
}

// ---- P1 身份证校验位 ----

{
  assert.ok(isValidChineseId("110101199003078937"), "合法身份证应通过（校验集#1）");
  assert.ok(!isValidChineseId("110101199003078936"), "非法身份证应拒绝（错一位校验位）");
  assert.ok(!isValidChineseId("000000000000000000"), "全 0 应拒绝（占位豁免在 scanLine 层）");

  // 真实身份证命中
  const findings = scanLine('{"id": "110101199003078937", "name": "张三"}');
  assert.ok(codes(findings).includes("P1_id_card"), "真实身份证应命中 P1");
  assert.strictEqual(findings[0]?.level, "error");
}

// ---- P2 手机号 ----

{
  const f = scanLine('{"phone": "13800138000"}');
  assert.ok(codes(f).includes("P2_mobile"), "手机号应命中 P2");

  const exempt = scanLine('{"phone": "12345678901"} // example data');
  assert.ok(!codes(exempt).includes("P2_mobile"), "example 标注应豁免手机号");
}

// ---- P3 学号 ----

{
  const f = scanLine('"studentId": "2020123456"');
  assert.ok(codes(f).includes("P3_student_id"), "含 studentId 的 10 位数字应命中 P3");
  assert.strictEqual(f[0]?.level, "error");

  // 无上下文提示词不命中
  const no = scanLine('"value": "2020123456"');
  assert.ok(!codes(no).includes("P3_student_id"), "无学号提示词不命中 P3");
}

// ---- P4 邮箱 ----

{
  const f = scanLine('"email": "zhangsan@tsinghua.edu.cn"');
  assert.ok(codes(f).includes("P4_email"), "邮箱应命中 P4（warn）");
  assert.strictEqual(f[0]?.level, "warn");

  const exempt = scanLine('"email": "user@example.com"');
  assert.ok(!codes(exempt).includes("P4_email"), "example.com 应豁免");
}

// ---- P5 会话凭证 ----

{
  const f = scanLine('"cookie": "JSESSIONID=abc123def456ghi789jkl"');
  assert.ok(codes(f).includes("P5_session_credential"), "JSESSIONID 应命中 P5");
  assert.strictEqual(f[0]?.level, "error");

  const cas = scanLine('CASTGC="TGT-1234567890abcdef-abcdef1234567890-xyz"');
  assert.ok(codes(cas).includes("P5_session_credential"), "CASTGC 应命中 P5");
}

// ---- P6 银行卡 Luhn ----

{
  assert.ok(luhnValid("6222021001001234563"), "合法银行卡应通过 Luhn");
  assert.ok(!luhnValid("6222021001001234561"), "非法银行卡应拒绝");
  // 注：全 0 数学上通过 Luhn（sum=0），由 scanLine 的占位豁免拦截，不在 luhnValid 层。
  assert.strictEqual(scanLine('"card":"0000000000000000000"').length, 0, "全 0 应被占位豁免");

  const f = scanLine('"card": "6222021001001234563"');
  assert.ok(codes(f).includes("P6_bank_card"), "银行卡应命中 P6");
}

// ---- 脱敏占位豁免 ----

{
  const exempts = [
    '{"id": "000000000000000000"}', // 全 0
    '{"id": "xxxxxxxxxxxxxxxxxx"}', // 全 X
    '{"id": "12345678901234567890"}', // 递增
    '{"phone": "12345678901", "comment": "this is a demo"}', // demo 豁免
    '{"sno": "12345678", "note": "测试数据"}', // 测试 豁免
    '{"token": "test-token-placeholder-12345678"}', // test 豁免
  ];
  for (const s of exempts) {
    const f = scanLine(s);
    assert.strictEqual(f.length, 0, `占位行应豁免：${s.slice(0, 50)}`);
  }
}

// ---- 混合场景 ----

{
  const f = scanLine(
    '{"name":"张三","id":"110101199003078937","phone":"13800138000","email":"zhang@tsinghua.cn"}',
  );
  const cs = codes(f);
  assert.ok(cs.includes("P1_id_card"));
  assert.ok(cs.includes("P2_mobile"));
  assert.ok(cs.includes("P4_email"));
  assert.strictEqual(f.length, 3, "一行多命中应全部检出");
}

console.log("✓ P1 身份证校验位");
console.log("✓ P2 手机号");
console.log("✓ P3 学号");
console.log("✓ P4 邮箱");
console.log("✓ P5 会话凭证");
console.log("✓ P6 银行卡 Luhn");
console.log("✓ 脱敏占位豁免");
console.log("✓ 混合场景");
console.log("\nscanner smoke 全部通过 ✅");
