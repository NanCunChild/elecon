/**
 * scanner：夹具 PII 扫描（脱敏检查，CI 闸门）。
 *
 * 红线 #8：不提交真实学生数据。本工具在提交/CI 时扫描 `adapters/**\/fixtures/`
 * 与 `adapters_tests/**` 下的文本，拦截疑似**未脱敏**的真实身份信息：
 *  P1 中国大陆居民身份证号（18 位，末位校验）
 *  P2 中国大陆手机号（1[3-9] + 9 位）
 *  P3 学号（连续 8–12 位数字，且上下文含 学号/studentId/xh 等提示词）
 *  P4 邮箱（真实姓名拼音@真实域名——只报告，人工判断）
 *  P5 疑似真实会话凭证 / 凭证等价物（JSESSIONID / CASTGC / token / ticket / openid /
 *     SAMLResponse … `=` 后跟长随机串；红线 #1 等价物，ADR-018 §2.10 MVP 不可推迟门）
 *  P6 银行卡号（16–19 位，Luhn 校验通过）
 *  P7 CAS 裸票据（ST-/TGT-/PT-/PGT- 前缀，常见于重定向 Location / 日志，无 `ticket=` 前缀；红线 #1）
 *
 * **判据取向**：宁可误报（warn）也不漏报安全项（error）。身份证 / 银行卡（有校验位、
 * 几乎不可能是脱敏占位）判 error；手机号 / 学号 / 凭证判 error；邮箱判 warn（占位邮箱常见）。
 *
 * 脱敏占位豁免：全 0 / 全 X / 递增（12345678）/ 含 `example`/`test`/`demo`/`fixture`
 * /`脱敏`/`redacted` 等字样的行，视为已脱敏，不报。
 *
 *   运行：cd tools && npm run scan                       # 扫描全部
 *         cd tools && npm run scan -- --path=../adapters/school-xjt
 *
 * ⚠ 本工具是**启发式**闸门，不能替代人工审阅（红线 #8 最终由人负责）。
 */

import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

// ---- 类型 ----

export type Level = "error" | "warn";

export interface PiiFinding {
  level: Level;
  code: string;
  message: string;
  /** 命中片段（已截断/打码，避免把疑似 PII 完整写进 CI 日志）。 */
  sample: string;
}

export interface FileFinding extends PiiFinding {
  file: string;
  line: number;
}

// ---- 脱敏占位豁免 ----

const PLACEHOLDER_HINTS = /example|test|demo|fixture|sample|placeholder|dummy|redacted|脱敏|示例|测试|占位/i;

/** 全同字符 / 简单递增序列 / 全 X → 明显是占位，不算真实 PII。 */
function looksLikePlaceholder(digits: string): boolean {
  if (/^(.)\1*$/.test(digits)) return true; // 全同字符
  if (/^x+$/i.test(digits)) return true;
  const ascending = "0123456789012345678901234567890";
  const descending = "9876543210987654321098765432109";
  return ascending.includes(digits) || descending.includes(digits);
}

/** 把命中片段打码后再进日志（保留前 2 + 后 2）。 */
function mask(s: string): string {
  if (s.length <= 4) return "*".repeat(s.length);
  return `${s.slice(0, 2)}${"*".repeat(s.length - 4)}${s.slice(-2)}`;
}

// ---- 校验位 ----

const ID_WEIGHTS = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const ID_CHECK = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"];

/** 中国大陆 18 位身份证校验（GB 11643）。 */
export function isValidChineseId(s: string): boolean {
  if (!/^\d{17}[\dXx]$/.test(s)) return false;
  let sum = 0;
  for (let i = 0; i < 17; i++) sum += Number(s[i]) * (ID_WEIGHTS[i] ?? 0);
  return ID_CHECK[sum % 11] === (s[17] ?? "").toUpperCase();
}

/** Luhn 校验（银行卡）。 */
export function luhnValid(s: string): boolean {
  if (!/^\d{16,19}$/.test(s)) return false;
  let sum = 0;
  let dbl = false;
  for (let i = s.length - 1; i >= 0; i--) {
    let d = Number(s[i]);
    if (dbl) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    dbl = !dbl;
  }
  return sum % 10 === 0;
}

// ---- 单行扫描（纯函数，供单测直接调用） ----

/**
 * 扫描一行文本，返回命中的 PII 发现。纯函数、不碰文件系统。
 */
export function scanLine(line: string): PiiFinding[] {
  const out: PiiFinding[] = [];
  const exempt = PLACEHOLDER_HINTS.test(line);

  // P1 身份证（先于手机号/学号，避免 18 位被拆成手机号）
  for (const m of line.matchAll(/\d{17}[\dXx]/g)) {
    const v = m[0];
    if (isValidChineseId(v) && !looksLikePlaceholder(v.slice(0, 17)) && !exempt) {
      out.push({
        level: "error",
        code: "P1_id_card",
        message: "疑似真实身份证号（校验位通过）",
        sample: mask(v),
      });
    }
  }

  // P6 银行卡（Luhn）——放在身份证后，避免 18 位重复
  for (const m of line.matchAll(/(?<!\d)\d{16,19}(?!\d)/g)) {
    const v = m[0];
    if (v.length === 18 && isValidChineseId(v)) continue; // 已由 P1 覆盖
    if (luhnValid(v) && !looksLikePlaceholder(v) && !exempt) {
      out.push({
        level: "error",
        code: "P6_bank_card",
        message: "疑似真实银行卡号（Luhn 通过）",
        sample: mask(v),
      });
    }
  }

  // P2 手机号
  for (const m of line.matchAll(/(?<!\d)1[3-9]\d{9}(?!\d)/g)) {
    const v = m[0];
    if (!looksLikePlaceholder(v) && !exempt) {
      out.push({ level: "error", code: "P2_mobile", message: "疑似真实手机号", sample: mask(v) });
    }
  }

  // P3 学号（需上下文提示词）
  if (/学号|student[_-]?id|\bxh\b|\bsno\b/i.test(line)) {
    for (const m of line.matchAll(/(?<!\d)\d{8,12}(?!\d)/g)) {
      const v = m[0];
      if (!looksLikePlaceholder(v) && !exempt) {
        out.push({
          level: "error",
          code: "P3_student_id",
          message: "疑似真实学号（上下文含学号提示）",
          sample: mask(v),
        });
      }
    }
  }

  // P5 会话凭证 / 凭证等价物（红线 #1；含 CAS/SSO 换票链的 ticket / openid / SAML）
  for (const m of line.matchAll(
    /(JSESSIONID|CASTGC|CASPRIVACY|CASST|access_token|refresh_token|id_token|oauth_token|token|ticket|openid|SAMLResponse|SAMLart|TGC)["']?\s*[=:]\s*["']?([A-Za-z0-9._%+/-]{16,})/gi,
  )) {
    const name = m[1] ?? "";
    const val = m[2] ?? "";
    if (val && !looksLikePlaceholder(val) && !exempt) {
      out.push({
        level: "error",
        code: "P5_session_credential",
        message: `疑似真实凭证/凭证等价物（${name}，红线 #1）`,
        sample: mask(val),
      });
    }
  }

  // P7 CAS 裸票据（ST-/TGT-/PT-/PGT-/PGTIOU- + 计数段 + 随机段；无 `ticket=` 前缀也拦）
  for (const m of line.matchAll(/\b(ST|TGT|PT|PGT|PGTIOU)-\d+-[A-Za-z0-9._-]{8,}/g)) {
    const v = m[0];
    if (!looksLikePlaceholder(v) && !exempt) {
      out.push({
        level: "error",
        code: "P7_cas_ticket",
        message: "疑似 CAS 票据等价物（ST/TGT/PT，红线 #1）",
        sample: mask(v),
      });
    }
  }

  // P4 邮箱（warn）
  for (const m of line.matchAll(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g)) {
    const v = m[0];
    if (!exempt && !/example\.|test\.|localhost/i.test(v)) {
      out.push({
        level: "warn",
        code: "P4_email",
        message: "邮箱地址（请确认是否为真实个人邮箱）",
        sample: mask(v),
      });
    }
  }

  return out;
}

// ---- 文件系统扫描 ----

const SCAN_ROOTS = ["adapters", "adapters_tests"];
const TEXT_EXT = /\.(json|html?|txt|md|mjs|js|ts|csv|xml|py)$/i;
const SKIP_DIR = /(^|\/)(node_modules|\.venv|\.git|build|dist|\.dart_tool)(\/|$)/;

function walkFiles(dir: string, out: string[]): void {
  if (SKIP_DIR.test(dir)) return;
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    const st = statSync(p);
    if (st.isDirectory()) {
      if (!SKIP_DIR.test(p)) walkFiles(p, out);
    } else if (TEXT_EXT.test(entry)) {
      out.push(p);
    }
  }
}

export function scanFile(path: string): FileFinding[] {
  const findings: FileFinding[] = [];
  const text = readFileSync(path, "utf-8");
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    for (const f of scanLine(lines[i] ?? "")) {
      findings.push({ ...f, file: path, line: i + 1 });
    }
  }
  return findings;
}

function main(): void {
  const arg = process.argv.find((a) => a.startsWith("--path="));
  const roots = arg
    ? [arg.slice("--path=".length)]
    : SCAN_ROOTS.map((r) => join(repoRoot, r)).filter((p) => existsSync(p));

  const files: string[] = [];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    if (statSync(root).isDirectory()) walkFiles(root, files);
    else files.push(root);
  }

  let errorCount = 0;
  let warnCount = 0;
  for (const file of files) {
    const findings = scanFile(file);
    if (findings.length === 0) continue;
    const rel = relative(repoRoot, file);
    for (const f of findings) {
      if (f.level === "error") errorCount++;
      else warnCount++;
      const icon = f.level === "error" ? "✗" : "⚠";
      console.log(`${icon} ${rel}:${f.line} [${f.code}] ${f.message} — ${f.sample}`);
    }
  }

  console.log(`\n扫描 ${files.length} 个文件：${errorCount} error, ${warnCount} warn。`);
  if (errorCount > 0) {
    console.error("PII 扫描失败：发现疑似未脱敏真实数据（红线 #8）。");
    process.exit(1);
  }
}

// 仅在被直接执行时跑 CLI；被 import（如 smoke 测试）时不触发。
const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
