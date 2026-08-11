# 离线 YubiKey 签名密钥 Ceremony（runbook）

> 落实 [V1 ADR-002](../adr/archived/v1/adr_002_trust_model.md) §2.3「离线硬件密钥本地签名」与 [V1 ADR-018](../adr/archived/v1/adr_018_adapter_distribution.md) §2.3；V2 official 治理原则见 ADR-000 §3.3。
> **本文所有步骤由持 token 的 release owner 亲自执行。** 按 [`AGENTS.md`](../../CLAUDE.md) §1，密钥 ceremony 属承重路径，
> **不得由 AI 或任何自动化执行**——PIN / PUK / 管理密钥**绝不可**出现在 agent 上下文、shell 历史、CI 日志或本仓任何位置。

---

## 0. 这份 ceremony 在信任模型里的位置

| 产物 | 去向 | 是否信任锚 |
|---|---|---|
| **私钥** | 片上生成，**永不离开 YubiKey** | — |
| **裸 32B Ed25519 公钥** | 预埋进 App（多公钥 pin，ADR-002 §2.3） | ✅ **唯一信任锚** |
| **X.509 证书** | **不生成**——不需要 | ❌ 见下 |
| `keyId` | 写进 `signature.json`，对应 pin 的 active key id | — |

**证书：不需要生成**（2026-07-16 实机核验结论）。PIV/PKCS#11 是证书导向的标准，早期 `libykcs11`
按**槽位证书**枚举对象——槽位无证书则密钥不暴露，故一般教程都要求先建一张自签证书。
**但实测并非如此**：libykcs11 2.7.3 + 固件 5.7.4 走的是固件 5.3+ 的 **PIV metadata** 枚举，
槽位里**没有任何用户证书时密钥照样暴露**（见 §4 的实测记录）。故本 ceremony **不建证书**。

这让信任模型更干净：**没有证书 → 没有有效期、没有 X.509 链、🔒 Dart 加载器不必碰 ASN.1**
（红线 #4「加载器最小化」）。信任锚自始至终只有 App 预埋的裸 32B Ed25519 公钥。

---

## 1. 前置检查

Ed25519 需 **固件 ≥ 5.7.0**（PIV applet 在此版本才支持 Edwards 曲线）：

```bash
ykman info                       # 看 Firmware version
ykman piv info                   # 看 PIV version / PIN 重试次数 / 是否默认密钥
```

### 1.1 GPG 与 PIV 共存

若这把 token 同时用作 GPG 签名，`scdaemon` 默认用**内建 CCID 驱动直接抢 USB**，会导致 `pcscd`
看不到读卡器、PIV 工具全部 `Failed to connect`。让 scdaemon 改走 pcscd 由其仲裁共享：

```bash
echo 'disable-ccid' >> ~/.gnupg/scdaemon.conf
gpgconf --kill scdaemon
systemctl restart pcscd.service
gpg --card-status                # 应能看到卡
ykman piv info                   # 应同时可用
```

---

## 2. 硬化（生产密钥的前置条件，不可跳过）

出厂的 PIV **管理密钥 / PUK 都是公开默认值**。管理密钥默认 = 任何拿到卡的人都能覆写签名槽位。

> ⚠ **交互式执行**：以下命令**不要**带 `--pin` / `--new-management-key` 等参数——不带参数时 ykman 会隐藏回显地提示输入，
> 避免密钥进入 shell 历史。

```bash
# 管理密钥：随机生成并存于卡上、由 PIN 保护（此后 PIV 管理操作只需 PIN）
ykman piv access change-management-key --generate --protect --algorithm aes256

# PIN（默认 123456）与 PUK（默认 12345678）
ykman piv access change-pin
ykman piv access change-puk
```

`--protect` 的取舍：管理密钥存卡上后，掌握 PIN 者即可做管理操作（如覆写槽位）。这**不放大** ADR-002 §3 风险 2
既定的失陷面——该风险已假定「物理窃取 token 且破 PIN」即失陷，而彼时攻击者本就能直接 PIN+触碰出签；
覆写槽位只是 DoS，由 ≥2 把 token 兜底。换来的是不必额外托管一份 24 字节管理密钥。

改完复查，两条 WARNING 应消失：

```bash
ykman piv info
```

---

## 3. 片上生成签名密钥（slot 9c）

**为何是 9c**：PIV「Digital Signature」槽位，语义正确，且其 PIN policy 天然为 ALWAYS。
**`--pin-policy` / `--touch-policy` 在生成时即固化，事后不可改**——写错只能销毁重来，务必看清。

```bash
cd /path/to/elecon
ykman piv keys generate \
  --algorithm ED25519 \
  --pin-policy ALWAYS \
  --touch-policy ALWAYS \
  9c ./elecon-official-ncc-1.pub.pem
```

- `ED25519` → 走 `CKM_EC_EDWARDS_KEY_PAIR_GEN` **片上生成**：私钥从不存在于硬件之外（强于"生成后导入"）。
- `--touch-policy ALWAYS` → **每一次签名都要物理触碰**。这是 ADR-002 §2.3 的人工批准闸门：
  本机即便被攻陷，攻击者也无法静默批量出签。
- 输出的 `.pub.pem` 只是公钥，不敏感。

### 3.1 立即复核策略（**不可跳过**）

`--pin-policy` / `--touch-policy` **在生成时固化、事后不可改**。漏写不会报错，只会静默留下一把
**不满足 ADR 批准闸门**的密钥——必须当场看一眼：

```bash
ykman piv keys info 9c
```

四行都要对上：

```
Algorithm:              ED25519
Origin:                 GENERATED     ← 片上生成（非导入）
PIN required for use:   ALWAYS
Touch required for use: ALWAYS        ← 漏写 --touch-policy 时这里会是 NEVER
```

> ⚠ `Touch: NEVER` 时，PIN 一经 PKCS#11 会话登录即驻留进程内存、ykcs11 会在每次 `C_Sign` 前自动重发
> VERIFY —— **被攻陷的本机可静默批量出签**，ADR-002 §2.3「签名窗口 = 需人在场触碰硬件」不再成立。
> `PIN=ALWAYS` 挡不住这个，**触碰才是真闸门**。发现不对：立刻重新生成（策略不可改）。
> 2026-07-16 首次 ceremony 即在此踩坑，密钥已作废重生成。

---

## 4. 证书：不生成（实测记录）

一般 PIV 教程会让你在此 `ykman piv certificates generate` 一张自签证书，理由是 `libykcs11`
按槽位证书枚举对象。**2026-07-16 在本项目硬件上实测，这个前提不成立**：

| 实测 | 结果 |
|---|---|
| 9c 已生成密钥、**未建任何证书**，跑 `pkcs11.ts list` | 密钥**正常出现**：`CKA_ID=2 \| Ed25519(CKK_EC_EDWARDS)` |
| `ykman piv certificates export 9c -` | `ERROR: No certificate found`（确无用户证书） |
| `p11tool --list-all-certs` | 有一张 `X.509 Certificate for PIV **Attestation 9c**`（id=02）—— libykcs11 **合成**的 attestation 证书，非槽位证书 |

结论：libykcs11 2.7.3 + 固件 5.7.4 走 **PIV metadata**（固件 5.3+）枚举，不依赖槽位证书。
**故不建证书** —— 少一步 ceremony，且信任模型里彻底没有 X.509（见 §0）。

> 那张 attestation 证书由 YubiKey **出厂密钥**签发，可向第三方**密码学证明**此私钥系片上生成、
> 从未存在于硬件之外（与 `Origin: GENERATED` 互证）。我们**不拿它做信任判定**，但它是个免费的审计物证。

> 若将来换用旧固件 / 旧 libykcs11 而 `list` 看不到密钥，那就是回到了「按证书枚举」的老行为——
> 届时补一张自签证书即可（`ykman piv certificates generate --subject "CN=<keyId>" --valid-days 7300 9c <pub.pem>`），
> **它仍然只是管道产物，不改变信任锚**。

---

## 5. 🔒 硬件出签自检

证明「片上私钥 → PKCS#11 `CKM_EDDSA` → 裸 64B → node 验签通过」整条链路成立：

```bash
cd tools && npx tsx src/signer/pkcs11.ts selftest --serial=<你的序列号> --key-id=elecon-official-ncc-1
```

会提示输入 PIN（隐藏回显），然后要求触碰。预期输出：

```
签名长度 : 64 字节 ✅ 裸 64B
公钥(裸32B): <64 hex>
node 验签  : ✅ 通过
```

`签名长度` 必须是 **64**。若不是，说明拿到的是封装格式（如 OpenPGP packet）而非裸签名，
与核心验签不兼容——见 ADR-002 §4 实现注意。

---

## 6. 公钥导出与预埋

```bash
cd tools && npx tsx src/signer/pkcs11.ts pubkey --serial=<你的序列号>
```

**无需 PIN**（公钥对象非 `CKA_PRIVATE`），这一步不接触任何秘密。输出的 **裸 32B（hex）** 就是要预埋进
App 的信任锚，按 ADR-002 §2.3「多公钥预埋 + 分批启用」登记为一条 pin（active 或 dormant）。

> 因为公钥可随时从令牌重新读出，§3 里 `keys generate` 落下的 `.pub.pem` **不必长期保管**。
> 想交叉验证可用另一实现独立读一次：`ykman piv keys export 9c -`（两者应逐字节一致）。

> ≥2 把 token：对每把 token 重复 §2–§6，各自独立密钥、`keyId` 递增（`elecon-official-ncc-1`、`-2`…），
> **全部公钥一次性预埋**，丢一把即晋升 dormant（晋升一律随发版，不热推）。

---

## 7. 发布台账（审计替代品）

离线签名没有云端逐次日志（ADR-002 §3 风险 2 残余风险 b），改用 **git 跟踪的发布台账**。
每次 official 签名后追加一条并提交：

| 字段 | 说明 |
|---|---|
| `adapterId` / `adapterVersion` | 被签对象身份（取自 bundle 内 manifest，非人工填写） |
| `sourceCommit` | 已审 adapter 源码的完整 40 位 git commit；不得用分支或 tag 代替 |
| `bundleDigest` / `policy` | 规范化 bundle 摘要；是否含 `masker.json` 及其签名载荷内字节摘要 |
| `catalogSequence` / `revocationSequence` | 本次出签所用的防回滚序号 |
| `signedAt` / `keyId` | 实际签署时间与所用 token |
| `signer` / `reviewReference` | 实际触碰人，以及独立复核的 PR / issue / 审计记录引用 |

机器可读台账为 [`release/adapter-release-ledger.json`](../../release/adapter-release-ledger.json)，格式与命令见
[`adapter_release.md`](./adapter_release.md) §7。历史事实不完整时必须保留 `status: "incomplete"` 并逐项列入
`missingFacts`，不得从产物时间、git author 或文档作者推断签署人/复核人。

---

## 8. 签名工作流（每次发布）

ADR-002 §4：CI / 审查沙箱只产出 **unsigned bundle + digest**，签名不在任何自动化上。

**完整命令、端点 D 布局、bootstrap 派生见 [`adapter_release.md`](./adapter_release.md)**（含 `school-xidian@0.3.0` 实例）。摘要：

1. A 域产出 unsigned bundle 与其 digest（`elecon-adapters`：`npm run bundle`）。
2. **本地重算 digest 并与 A 比对**——`npx tsx src/signer/index.ts digest --adapter=<dir>`。
   > 这一步是对「本机被攻陷 → 触碰瞬间替换载荷（所见非所签）」的唯一防线（ADR-002 §3 风险 2）。
   > 别跳过，也别只看 CI 的输出——要在你**即将触碰的这台机器上**算一遍。
3. PIN + 触碰：`tools` 下 `npm run release:package -- …` → 签 bundle + catalog + revocation，写出 dist 树。
4. 上传 dist 到端点 D（`https://elecon.xidian.one/adapters/`）；可选 `bootstrap:sync`。
5. 从 signed dist 提取台账草稿，人工补入本次 source commit / 签署 / 复核事实并验证（§7）→ 提交。

---

## 9. 出错了怎么办

| 症状 | 原因 / 处置 |
|---|---|
| `Failed to connect to YubiKey` | scdaemon 抢了 CCID → §1.1 |
| `ykman piv keys info 9c` 显示 `Touch: NEVER` | 生成时漏了 `--touch-policy ALWAYS`。**策略不可改 → 必须重新生成**（§3.1） |
| `list` 看不到 9c 密钥 | 若为旧固件/旧 libykcs11，可能回退到「按证书枚举」→ 补一张自签证书（§4 末） |
| `selftest` 不提示触碰就出签 | 触碰策略没生效 → 查 §3.1，这把密钥不满足 ADR-002 §2.3 闸门 |
| `selftest` 报签名非 64 字节 | 拿到了封装格式签名，不可用于 elecon 验签 |
| PIN 输错 | 默认 3 次重试，耗尽需用 PUK 解锁（`ykman piv access unblock-pin`） |
| PUK 也锁死 | **PIV applet 只能 reset，槽位密钥全毁** → 换用备用 token，吊销该 keyId |
| 想推倒重来（仅限未分发的彩排密钥） | `ykman piv reset` —— **会清空整个 PIV applet**，生产密钥慎用 |
