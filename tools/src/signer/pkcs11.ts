/**
 * 🔒🔒 YubiKey PIV / PKCS#11 硬件出签接线（ADR-002 §2.3、ADR-018 §2.3）。
 *
 * 本文件是 `HardwareEd25519Signer` 的**真实硬件实现**，取代 `UnwiredHardwareSigner` 的 fail-closed 占位。
 * 它是 signer 里唯一接触 PKCS#11 的地方——`YubiKeySignBackend` 只依赖 `HardwareEd25519Signer` 接缝，
 * 故本文件可替换（他牌 token / 他种 PKCS#11 模块）而不动签名管线。
 *
 * **私钥永不出硬件**：密钥由 `CKM_EC_EDWARDS_KEY_PAIR_GEN` **片上生成**（见 docs/runbook 签名 ceremony），
 * 本进程只送入待签字节、取回签名字节。C_Sign 期间硬件要求 **PIN + 物理触碰** = ADR-002 §2.3 的人工批准闸门。
 *
 * **本文件不含批准逻辑**：它无法"决定"签什么——决定权在持 token 者的 PIN 与手指。按 AGENTS.md §1，
 * 本文件属承重路径，须人工审阅；**密钥 ceremony（PIN/PUK/管理密钥/生成密钥）不得由自动化执行**。
 *
 * ⚠ **PKCS#11 版本落差**：`pkcs11js` 实现到 **PKCS#11 2.40**，而 Ed25519 相关机制/密钥类型是
 *   **3.0** 才引入的，故 `pkcs11js` **未导出**这些常量（`pkcs11js.CKM_EDDSA === undefined`）。
 *   下方按 PKCS#11 v3.0 规范显式定义——**不是笔误，删掉会静默变成 `undefined` 机制**。
 *   已在 YubiKey 5C NFC / 固件 5.7.4 / libykcs11 2.7.3 实机核验：机制表含 0x1057，
 *   flags = CKF_HW|CKF_SIGN|CKF_VERIFY（0x1902801）。Ed25519 需固件 **≥5.7.0**。
 *
 *   运行：cd tools && npx tsx src/signer/pkcs11.ts list        # 枚举令牌与密钥对象（无需 PIN）
 *         cd tools && npx tsx src/signer/pkcs11.ts selftest    # 🔒 出签自检（需 PIN + 触碰）
 */

import { createPublicKey, verify as edVerify, type KeyObject } from "node:crypto";
import { realpathSync } from "node:fs";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import type { HardwareEd25519Signer } from "./index.js";

// ---- PKCS#11 3.0 常量（pkcs11js 只到 2.40，未导出；值取自 PKCS#11 v3.0 §6.1） ----

/** Ed25519 签名机制（PKCS#11 3.0）。ykcs11 对 PIV Ed25519 槽位即用此机制。 */
export const CKM_EDDSA = 0x1057;
/** Edwards 曲线密钥对生成机制（PKCS#11 3.0）——片上生成用，ceremony 侧由 ykman 触发。 */
export const CKM_EC_EDWARDS_KEY_PAIR_GEN = 0x1055;

/** libykcs11 默认路径（Arch/Debian 的 yubico-piv-tool 包）。可用 ELECON_PKCS11_MODULE 覆盖。 */
const DEFAULT_MODULE = "/usr/lib/libykcs11.so";

/**
 * PIV 槽位 → ykcs11 的 `CKA_ID`（单字节）。ykcs11 把 PIV 槽位映射为连续 id：
 * 9a=1（PIV Authentication）/ 9c=2（**Digital Signature**）/ 9d=3（Key Management）/ 9e=4（Card Authentication）。
 * elecon official 签名用 **9c**：其 PIN policy 默认为 ALWAYS（每次签名都要 PIN），语义也正是"数字签名"。
 */
const PIV_SLOT_TO_CKA_ID: Record<string, number> = { "9a": 1, "9c": 2, "9d": 3, "9e": 4 };

/** elecon official 签名槽位（ADR-002 §2.3）。 */
export const ELECON_SIGNING_SLOT = "9c";

// ---- 惰性加载（pkcs11js 是 optionalDependency：只有离线签名机需要它） ----

/**
 * pkcs11js 是**可选依赖**——它是原生模块（node-gyp），而 CI / 普通开发机既无 YubiKey 也未必有
 * 构建工具链（且 npm 新版默认拦安装脚本）。故此处惰性导入并 fail-closed：
 * 缺它时其余 tools（validator/scanner/digest/验签）照常工作，只有硬件出签不可用。
 */
async function loadPkcs11(): Promise<typeof import("pkcs11js")> {
  try {
    type Mod = typeof import("pkcs11js");
    const ns = (await import("pkcs11js")) as unknown as Mod & { default?: Mod };
    // ⚠ pkcs11js 是 **CJS**，而常量（CKF_*/CKA_*/CKO_*/CKU_*）是**动态赋值**到 module.exports 的——
    //   Node 的 cjs-module-lexer 静态分析不到，故 ESM 命名空间只暴露 3 个命名导出（PKCS11/错误类），
    //   **所有常量都是 undefined**。必须取 default（= module.exports）。
    //   症状很隐蔽：`ns.CKF_SERIAL_SESSION` → undefined → C_OpenSession 报
    //   "Argument 1 has wrong type. Should be a Number"，看着像参数写错，其实是常量没拿到。
    return ns.default ?? ns;
  } catch (err) {
    throw new Error(
      `🔒 pkcs11js 不可用（硬件出签需要它）：${(err as Error).message}\n` +
        `  它是 optionalDependency + 原生模块。离线签名机上需构建：\n` +
        `    cd $(npm root)/pkcs11js && npx node-gyp rebuild\n` +
        `  非签名机无需它——validator / scanner / digest / 验签均不依赖。`,
    );
  }
}

export interface Pkcs11Options {
  /** PKCS#11 模块路径（默认 libykcs11.so；ELECON_PKCS11_MODULE 可覆盖）。 */
  module?: string;
  /** 令牌序列号——**多把 token 时必须指定**，避免签错卡（ADR-002 §3 风险 2：≥2 把 token）。 */
  serial?: string;
  /** PIV 槽位（默认 9c）。 */
  pivSlot?: string;
}

function modulePath(o: Pkcs11Options): string {
  return o.module ?? process.env["ELECON_PKCS11_MODULE"] ?? DEFAULT_MODULE;
}

export interface TokenInfo {
  slotId: Buffer;
  label: string;
  serial: string;
  model: string;
}

export interface KeyObjectInfo {
  label: string;
  ckaId: number;
  keyType: number;
  /**
   * 该 CKA_ID 是否存在**任何** CKO_CERTIFICATE 对象。**注意**：libykcs11 会合成 attestation 证书，
   * 故此值为 true 不代表槽位有用户证书，也与"密钥能否被枚举"无关（见 `listKeys` 注释）。纯诊断用。
   */
  hasCertificate: boolean;
}

/** 枚举当前接入的 PKCS#11 令牌（无需 PIN）。 */
export async function listTokens(o: Pkcs11Options = {}): Promise<TokenInfo[]> {
  const pkcs11js = await loadPkcs11();
  const m = new pkcs11js.PKCS11();
  m.load(modulePath(o));
  m.C_Initialize();
  try {
    return m.C_GetSlotList(true).map((slotId) => {
      const t = m.C_GetTokenInfo(slotId);
      return {
        slotId,
        label: t.label.toString().trim(),
        serial: t.serialNumber.toString().trim(),
        model: t.model.toString().trim(),
      };
    });
  } finally {
    m.C_Finalize();
  }
}

/**
 * 枚举槽位上的**公钥/证书对象**（无需 PIN——私钥对象是 CKA_PRIVATE，需登录才可见）。
 *
 * **证书与枚举的关系**（2026-07-16 实机核验，勿凭常识改）：网上多数 PIV 教程称 libykcs11
 * 按**槽位证书**枚举、无证书则密钥不暴露。在 libykcs11 2.7.3 + 固件 5.7.4 上**实测不成立**——
 * 它走固件 5.3+ 的 **PIV metadata** 枚举，槽位无任何用户证书时密钥照样暴露。
 * 故 ceremony **不建证书**（docs/reference/signing_ceremony.md §4）。
 *
 * ⚠ `hasCertificate` 为 true **不代表槽位有用户证书**：libykcs11 会为每个密钥合成一张
 *   *attestation* 证书（label 形如 `X.509 Certificate for PIV Attestation 9c`）。它由 YubiKey
 *   出厂密钥签发、可证明私钥系片上生成，但**不是 elecon 的信任锚**——信任锚只有 App 预埋的
 *   裸 32B Ed25519 公钥（ADR-002 §2.3 多公钥 pin），🔒 加载器不做任何 X.509 链校验。
 */
export async function listKeys(o: Pkcs11Options = {}): Promise<KeyObjectInfo[]> {
  const pkcs11js = await loadPkcs11();
  const m = new pkcs11js.PKCS11();
  m.load(modulePath(o));
  m.C_Initialize();
  try {
    const slot = pickSlot(m, o);
    const session = m.C_OpenSession(slot, pkcs11js.CKF_SERIAL_SESSION);
    try {
      const certIds = new Set(
        findObjects(m, session, [{ type: pkcs11js.CKA_CLASS, value: pkcs11js.CKO_CERTIFICATE }]).map((h) =>
          readCkaIdByte(m, pkcs11js, session, h),
        ),
      );
      return findObjects(m, session, [{ type: pkcs11js.CKA_CLASS, value: pkcs11js.CKO_PUBLIC_KEY }]).map(
        (h) => {
          const attrs = m.C_GetAttributeValue(session, h, [
            { type: pkcs11js.CKA_LABEL },
            { type: pkcs11js.CKA_ID },
            { type: pkcs11js.CKA_KEY_TYPE },
          ]);
          const ckaId = attrByte(attrs, 1, "CKA_ID");
          return {
            label: attrBytes(attrs, 0, "CKA_LABEL").toString().trim(),
            ckaId,
            keyType: attrByte(attrs, 2, "CKA_KEY_TYPE"),
            hasCertificate: certIds.has(ckaId),
          };
        },
      );
    } finally {
      m.C_CloseSession(session);
    }
  } finally {
    m.C_Finalize();
  }
}

// ---- 内部工具 ----

type P11 = InstanceType<typeof import("pkcs11js").PKCS11>;
type P11Mod = typeof import("pkcs11js");

function pickSlot(m: P11, o: Pkcs11Options): Buffer {
  const slots = m.C_GetSlotList(true);
  if (slots.length === 0)
    throw new Error("🔒 未发现任何 PKCS#11 令牌（YubiKey 是否插入？pcscd 是否在跑？）。");
  if (o.serial === undefined) {
    if (slots.length > 1) {
      const found = slots.map((s) => m.C_GetTokenInfo(s).serialNumber.toString().trim()).join(", ");
      throw new Error(
        `🔒 接入了多把令牌（序列号：${found}）——必须用 serial 显式指定，避免签错卡（fail-closed）。`,
      );
    }
    return slots[0] as Buffer;
  }
  for (const s of slots) {
    if (m.C_GetTokenInfo(s).serialNumber.toString().trim() === o.serial) return s;
  }
  throw new Error(`🔒 未找到序列号为 ${o.serial} 的令牌（fail-closed）。`);
}

function findObjects(m: P11, session: Buffer, template: unknown[]): Buffer[] {
  m.C_FindObjectsInit(session, template as never);
  const out: Buffer[] = [];
  try {
    for (;;) {
      const h = m.C_FindObjects(session);
      if (h === null) break;
      out.push(h as unknown as Buffer);
    }
  } finally {
    m.C_FindObjectsFinal(session);
  }
  return out;
}

/**
 * 取属性字节串；缺失/非字节串即 **fail-closed**。
 * 不用 `attrs[i]?.value as Buffer`——那个 cast 会把 undefined 掩盖成远处一个莫名的 TypeError；
 * 在 🔒 路径上，读不到属性必须是显式、可诊断的失败。
 */
function attrBytes(attrs: { value?: unknown }[], i: number, what: string): Buffer {
  const v = attrs[i]?.value;
  if (!Buffer.isBuffer(v) || v.length === 0) {
    throw new Error(`🔒 PKCS#11 属性 ${what} 缺失或非字节串（fail-closed）。`);
  }
  return v;
}

/** 取属性首字节（CKA_ID / CKA_KEY_TYPE 这类单字节枚举）。 */
function attrByte(attrs: { value?: unknown }[], i: number, what: string): number {
  return attrBytes(attrs, i, what).readUInt8(0);
}

function readCkaIdByte(m: P11, pkcs11js: P11Mod, session: Buffer, h: Buffer): number {
  const a = m.C_GetAttributeValue(session, h as never, [{ type: pkcs11js.CKA_ID }]);
  return attrByte(a, 0, "CKA_ID");
}

/** PIV 槽位 → CKA_ID，未知槽位 fail-closed。 */
function ckaIdOf(o: Pkcs11Options): number {
  const slot = o.pivSlot ?? ELECON_SIGNING_SLOT;
  const id = PIV_SLOT_TO_CKA_ID[slot];
  if (id === undefined) {
    throw new Error(`🔒 未知 PIV 槽位：${slot}（支持 ${Object.keys(PIV_SLOT_TO_CKA_ID).join("/")}）。`);
  }
  return id;
}

/** 从会话读指定 CKA_ID 的公钥（CKA_EC_POINT → 裸 32B → SPKI KeyObject）。 */
function readPublicKeyFromSession(m: P11, pkcs11js: P11Mod, session: Buffer, ckaId: number): KeyObject {
  const pubs = findObjects(m, session, [
    { type: pkcs11js.CKA_CLASS, value: pkcs11js.CKO_PUBLIC_KEY },
    { type: pkcs11js.CKA_ID, value: Buffer.from([ckaId]) },
  ]);
  const pub = pubs[0];
  if (pub === undefined) throw new Error(`🔒 CKA_ID=${ckaId} 无公钥对象（fail-closed）。`);
  const attrs = m.C_GetAttributeValue(session, pub as never, [{ type: pkcs11js.CKA_EC_POINT }]);
  const ecPoint = attrBytes(attrs, 0, "CKA_EC_POINT");
  // CKA_EC_POINT 是 DER OCTET STRING 包着的裸 32B 公钥；剥掉 DER 头（裸 32B 时直接用）。
  // 长度不足 32 交给 rawEd25519ToKeyObject 的守卫拒掉，别在这里静默补零。
  const raw = ecPoint.length === 32 ? ecPoint : ecPoint.subarray(ecPoint.length - 32);
  return rawEd25519ToKeyObject(raw);
}

/**
 * 读槽位公钥 —— **无需 PIN**（公钥对象非 CKA_PRIVATE，无需 C_Login）。
 *
 * 这意味着「导出公钥」不必是 ceremony 的独立步骤，也不必保管 `ykman piv keys generate` 落下的
 * `.pub.pem`：**信任锚可随时从令牌本身重新读出**，且这一步不接触任何秘密。
 */
export async function readSlotPublicKey(o: Pkcs11Options = {}): Promise<KeyObject> {
  const pkcs11js = await loadPkcs11();
  const m = new pkcs11js.PKCS11();
  m.load(modulePath(o));
  m.C_Initialize();
  try {
    const slot = pickSlot(m, o);
    const session = m.C_OpenSession(slot, pkcs11js.CKF_SERIAL_SESSION);
    try {
      return readPublicKeyFromSession(m, pkcs11js, session, ckaIdOf(o));
    } finally {
      m.C_CloseSession(session);
    }
  } finally {
    m.C_Finalize();
  }
}

/** 从 TTY 隐藏读取 PIN——**绝不经 argv / 环境变量**（会进 shell 历史、ps、CI 日志）。 */
export async function promptPin(prompt = "YubiKey PIV PIN: "): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stderr, terminal: true });
  // 关回显：readline 的 _writeToOutput 覆写是隐藏输入的惯用手法。
  const asMutable = rl as unknown as { _writeToOutput?: (s: string) => void };
  const original = asMutable._writeToOutput?.bind(rl);
  asMutable._writeToOutput = (s: string): void => {
    if (s.includes(prompt) || s.trim() === "") original?.(s);
  };
  try {
    return await new Promise<string>((resolve) => {
      rl.question(prompt, (answer) => {
        process.stderr.write("\n");
        resolve(answer);
      });
    });
  } finally {
    rl.close();
  }
}

// ---- 硬件签名器 ----

/**
 * 🔒 YubiKey PIV / PKCS#11 的 `HardwareEd25519Signer` 实现。
 *
 * 每次 {@link signEd25519} → 一次 `C_Sign(CKM_EDDSA)` → 硬件**要求物理触碰**（若槽位 touch policy=always）
 * 且 PIN policy=always 时每次都校验 PIN。**这是 ADR-002 §2.3 人工批准闸门的落点**：即便本机被攻陷，
 * 攻击者也无法静默批量出签（每一签都要人在场按一下）。
 *
 * 残余风险（ADR-002 §3 风险 2）：被攻陷的**本机**可在你触碰的瞬间替换待签载荷（"所见非所签"）。
 * 缓解靠 ceremony 纪律——签前本地重算 digest 并与 CI 产出的 unsigned bundle 比对（ADR-002 §4 工作流）。
 *
 * PIN 只驻留本对象内存；用毕调用 {@link close}。
 */
export class YubiKeyPkcs11Signer implements HardwareEd25519Signer {
  readonly keyId: string;
  #opts: Pkcs11Options;
  #pin: string;
  #pkcs11js: P11Mod | null = null;
  #m: P11 | null = null;
  #session: Buffer | null = null;

  /**
   * @param keyId elecon 的密钥标识（写进 `signature.json`，对应核心预埋 pin 的 active key id）——
   *              **与 PKCS#11 的 CKA_ID 无关**，别混淆。
   * @param pin   PIV PIN。请用 {@link promptPin} 取，勿从 argv/env 传。
   */
  constructor(keyId: string, pin: string, opts: Pkcs11Options = {}) {
    this.keyId = keyId;
    this.#pin = pin;
    this.#opts = opts;
  }

  async #ensureSession(): Promise<{ m: P11; pkcs11js: P11Mod; session: Buffer }> {
    if (this.#m !== null && this.#session !== null && this.#pkcs11js !== null) {
      return { m: this.#m, pkcs11js: this.#pkcs11js, session: this.#session };
    }
    const pkcs11js = await loadPkcs11();
    const m = new pkcs11js.PKCS11();
    m.load(modulePath(this.#opts));
    m.C_Initialize();
    const slot = pickSlot(m, this.#opts);
    const session = m.C_OpenSession(slot, pkcs11js.CKF_SERIAL_SESSION | pkcs11js.CKF_RW_SESSION);
    m.C_Login(session, pkcs11js.CKU_USER, this.#pin);
    this.#pkcs11js = pkcs11js;
    this.#m = m;
    this.#session = session;
    return { m, pkcs11js, session };
  }

  /** 对 data 做原始 Ed25519 签名，返回**裸 64 字节**（ADR-002 §4：非 OpenPGP packet 封装）。 */
  async signEd25519(data: Buffer): Promise<Buffer> {
    const { m, pkcs11js, session } = await this.#ensureSession();
    const ckaId = ckaIdOf(this.#opts);
    const keys = findObjects(m, session, [
      { type: pkcs11js.CKA_CLASS, value: pkcs11js.CKO_PRIVATE_KEY },
      { type: pkcs11js.CKA_ID, value: Buffer.from([ckaId]) },
    ]);
    const key = keys[0];
    if (key === undefined) {
      throw new Error(
        `🔒 PIV 槽位 ${this.#opts.pivSlot ?? ELECON_SIGNING_SLOT} 无私钥对象（fail-closed）。\n` +
          `  常见原因：该槽位未生成密钥；或旧固件/旧 libykcs11 回退到「按证书枚举」而槽位无证书。\n` +
          `  见 docs/reference/signing_ceremony.md。`,
      );
    }
    m.C_SignInit(session, { mechanism: CKM_EDDSA }, key as never);
    process.stderr.write("👆 请触碰 YubiKey 以完成签名…\n");
    const sig = m.C_Sign(session, data, Buffer.alloc(64));
    // 防御性：把"裸 64 字节"的约定钉在最靠近硬件处（YubiKeySignBackend 亦有同样校验，纵深防御）。
    if (sig.length !== 64) {
      throw new Error(`🔒 Ed25519 签名须为裸 64 字节，硬件返回 ${sig.length} 字节（fail-closed）。`);
    }
    return Buffer.from(sig);
  }

  /** 读取槽位公钥（SPKI DER → KeyObject）——供签后自验。复用已登录会话。 */
  async readPublicKey(): Promise<KeyObject> {
    const { m, pkcs11js, session } = await this.#ensureSession();
    return readPublicKeyFromSession(m, pkcs11js, session, ckaIdOf(this.#opts));
  }

  close(): void {
    try {
      if (this.#m !== null && this.#session !== null) {
        this.#m.C_Logout(this.#session);
        this.#m.C_CloseSession(this.#session);
      }
      this.#m?.C_Finalize();
    } catch {
      /* 关闭期错误不掩盖主流程错误 */
    }
    this.#pin = "";
    this.#m = null;
    this.#session = null;
  }
}

/**
 * 裸 32 字节 Ed25519 公钥 → node KeyObject。
 * 手工拼 SPKI：`30 2a 30 05 06 03 2b 65 70 03 21 00 || raw32`（RFC 8410 id-Ed25519 = 1.3.101.112）。
 * **这就是 elecon 的信任锚形态**——App 预埋的是这 32 字节，不是证书（ADR-002 §2.3）。
 */
export function rawEd25519ToKeyObject(raw32: Buffer): KeyObject {
  if (raw32.length !== 32) throw new Error(`Ed25519 公钥须为 32 字节，得 ${raw32.length}。`);
  const spki = Buffer.concat([
    Buffer.from([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]),
    raw32,
  ]);
  return createPublicKey({ key: spki, format: "der", type: "spki" });
}

/** KeyObject → 裸 32 字节（SPKI DER 尾部即公钥）。用于导出预埋 pin 的公钥形态。 */
export function keyObjectToRawEd25519(key: KeyObject): Buffer {
  const der = key.export({ format: "der", type: "spki" });
  return der.subarray(der.length - 32);
}

// ---- CLI ----

async function main(): Promise<void> {
  const cmd = process.argv[2];
  const serialArg = process.argv.find((a) => a.startsWith("--serial="))?.slice(9);
  const opts: Pkcs11Options = serialArg !== undefined ? { serial: serialArg } : {};

  if (cmd === "list") {
    const tokens = await listTokens(opts);
    if (tokens.length === 0) {
      console.log("未发现令牌（YubiKey 插了吗？pcscd 在跑吗？）");
      process.exitCode = 1;
      return;
    }
    for (const t of tokens) console.log(`令牌: ${t.label} | 序列号 ${t.serial} | 型号 ${t.model}`);
    const keys = await listKeys(opts);
    if (keys.length === 0) {
      console.log("\n槽位内无公钥对象——PIV 尚未生成密钥。");
      return;
    }
    console.log("");
    for (const k of keys) {
      const kind = k.keyType === 0x40 ? "Ed25519(CKK_EC_EDWARDS)" : `keyType=0x${k.keyType.toString(16)}`;
      // 证书列纯诊断：libykcs11 会合成 attestation 证书，"有"不代表槽位有用户证书。
      console.log(
        `密钥: CKA_ID=${k.ckaId} | ${kind} | 证书对象=${k.hasCertificate ? "有" : "无"} | ${k.label}`,
      );
    }
    return;
  }

  if (cmd === "pubkey") {
    // 导出信任锚形态 —— **无需 PIN、不接触任何秘密**。
    const pub = await readSlotPublicKey(opts);
    const raw = keyObjectToRawEd25519(pub);
    console.log(`裸 32B (hex)   : ${raw.toString("hex")}`);
    console.log(`裸 32B (base64): ${raw.toString("base64")}`);
    console.log("");
    console.log(pub.export({ format: "pem", type: "spki" }).toString().trim());
    return;
  }

  if (cmd === "selftest") {
    // 🔒 出签自检：片上私钥签一段固定字节 → 用槽位公钥验 → 证明整条硬件链路成立。
    // 不碰任何 adapter、不产出可分发签名——纯链路验证。
    const keyId = process.argv.find((a) => a.startsWith("--key-id="))?.slice(9) ?? "yubikey-selftest";
    const pin = await promptPin();
    const signer = new YubiKeyPkcs11Signer(keyId, pin, opts);
    try {
      const pub = await signer.readPublicKey();
      const data = Buffer.from("elecon hardware signer selftest", "utf-8");
      const sig = await signer.signEd25519(data);
      const ok = edVerify(null, data, pub, sig);
      console.log(`\n签名长度 : ${sig.length} 字节 ${sig.length === 64 ? "✅ 裸 64B" : "❌"}`);
      console.log(`公钥(裸32B): ${keyObjectToRawEd25519(pub).toString("hex")}`);
      console.log(`node 验签  : ${ok ? "✅ 通过" : "❌ 失败"}`);
      if (!ok || sig.length !== 64) process.exitCode = 1;
    } finally {
      signer.close();
    }
    return;
  }

  console.log("用法：");
  console.log(
    "  npx tsx src/signer/pkcs11.ts list [--serial=<n>]                 # 枚举令牌/密钥（无需 PIN）",
  );
  console.log(
    "  npx tsx src/signer/pkcs11.ts pubkey [--serial=<n>]               # 导出裸 32B 信任锚（无需 PIN）",
  );
  console.log(
    "  npx tsx src/signer/pkcs11.ts selftest [--serial=<n>] [--key-id=] # 🔒 出签自检（PIN + 触碰）",
  );
  process.exitCode = 2;
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  await main();
}
