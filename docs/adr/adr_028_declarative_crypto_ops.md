# ADR-028：声明式加密算子——把摘要与确定性块加密收进 `compute` 封闭词表

- **状态**：**已接受（Accepted）** · 2026-07-29 owner 勾决（方向、首批算子清单、§2 语义、§7 细原语被拒 + 三层阶梯全部锁定）。
  **接受的是本文的契约面与算子语义决策**；**实现闭环仍受约束**：本文触碰红线 #1（凭证 / 凭证派生值）、#5（adapter 能力面表达力）、#6（契约承重墙），按 [AGENTS.md](../../AGENTS.md) §1，**两端 runtime / validator / golden 的实现与测试须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**——ADR 接受不豁免代码侧的人工安全签收（§6 清单仍须逐条过，与 ADR-023「已接受但实现须人工主导」同例）。
- **日期**：2026-07-29
- **依赖**：
  - [`adr_023_declarative_dataflow.md`](./adr_023_declarative_dataflow.md)（`bind`/`compute`/`inject` 数据流 + 封闭 op 词表 + §2.5 污点三约束——**本文扩其 `compute` 词表**）
  - [`adr_022_request_graph.md`](./adr_022_request_graph.md)（declarative / imperative 轴）
  - [`adr_017_sso_master_credential.md`](./adr_017_sso_master_credential.md)（§2.8「body 内嵌被签名票据」盲区——本文为其提供确定性块加密原语）
  - [`adr_001_contract.md`](./adr_001_contract.md)（§8 双跑 golden、manifest schema）
- **被依赖**：`contract/manifest.schema.json`（`compute[].op` 枚举 + `aes-cbc` params）；`tools/src/validator/dataflow.ts`（`OP_SIGNATURES` + D8/D9/D10）；两端 runtime（`server/src/runtime/broker/dataflow.ts` `evalOp` / `client/lib/core/broker/dataflow.dart`）；`docs/reference/declarative_dataflow_ops.md`；`contract/golden/broker/dataflow.json`。
- **适用范围**：ADR-023 声明式数据流 `compute` 阶段**新增算子的语义与契约面**。**不含**：`bind`/`inject`/拓扑执行模型（ADR-023 不变）、imperative（ADR-022）、凭证注入机制（ADR-009 不变）、随机化加密（见 §2.4 明确出范围）。

---

## 1. 背景（Context）

ADR-023 把「响应派生值 → 计算 → 注入下一请求」这条数据依赖链从 imperative 收回声明式：adapter 只**描述**（封闭 op 词表），broker **持值并原生执行**，adapter 全程不见句柄字节。当前封闭 `compute` 词表（`declarative_dataflow_ops.md`）只有**单向**的 `hmac-sha256` / `hkdf`，**缺两类真实登录 / 取数所需的算子**：

1. **裸摘要**（`md5` / `sha1` / `sha256`）：大量校本签名基串走 `md5(concat(...))` 形态，HMAC（keyed-MAC）表达不了无密钥摘要。
2. **确定性可逆块加密**（AES-CBC）：真实抓包证据——
   - 西电水电取数（`adapters_tests/XIDIAN/energy/meter.py`）：请求体 `AES-CBC` 加密，**固定 key/iv** `"1234567812345678"`。
   - 西电密码加密（`adapters_tests/XIDIAN/ids/login.py`）：`AES-CBC`，key=登录页 `#pwdEncryptSalt` 动态盐（属 `bind`），**IV 固定** `"xidianscriptsxdu"`，明文补固定前缀后 PKCS7。

缺这两类算子，上述场景只能落 imperative——给 adapter 开 `ctx.fetch` + body 透传见值的口子，在 DEPLOY 触发 official-only 门禁（ADR-002 §2.5/§2.6、ADR-009 §2 决策 7）与项目最高风险面（红线 #1）。**本 ADR 补齐算子，把这批场景收回 ADR-023「broker 持密钥并执行、adapter 只声明方案、全程不见值」模型。**

> **不是「打包 CyberChef」。** CyberChef 是 JS（forge/crypto-js），进不了 Dart 客户端；工作量是每个算子在 TS 与 Dart 里**逐字节一致**的形式化语义 + 双跑 golden，「打包」省不掉。CyberChef 仅作参数形状 / 语义的**参照**，不作依赖。对 adapter 作者这是**降低**门槛（声明 `op:"aes-cbc"` 远比写 imperative JS + 申请签名 + 见值简单）；重量落可信核心，成本随算子数量**线性增长**，故第一批**证据驱动、克制**。

---

## 2. 决策（Decision，草案）

### 2.1 首批算子（4 个，均 `bytes` 产出）

沿用 `declarative_dataflow_ops.md` §1 签名表格式。`args` 为句柄位（`ref` 或 `text` 字面量），`params` 为纯标量参数。

| op | args（位置、类型） | params | 输出 | 输出长度 |
|---|---|---|---|---|
| `md5` | `[0]=message`（`text\|bytes`） | — | `bytes` | 16 |
| `sha1` | `[0]=message`（`text\|bytes`） | — | `bytes` | 20 |
| `sha256` | `[0]=message`（`text\|bytes`） | — | `bytes` | 32 |
| `aes-cbc` | `[0]=key`（🔒 须 `ref`，`text\|bytes`）、`[1]=message`（`text\|bytes`）、`[2]=iv`（`text\|bytes`，字面量或 ref） | `padding ∈ {pkcs7, none}` | `bytes` | 密文（16 的倍数） |

- 均为 `bytes` 产出：接续 ADR-023 §0「`bytes` 只由 `hmac-sha256`/`hkdf` 产生」——本文把产生者扩到 `md5`/`sha1`/`sha256`/`aes-cbc`。**`base64`/`hex` 仍是唯一 `bytes → text` 通道**，无新增 `text → bytes` 解码（保持类型系统封闭，ADR-023 §0）。故 `bytes` 结果注入前须先过 `base64`/`hex`（validator D9 静态强制 inject 只收 text）。
- `text` 输入按 **UTF-8** 编码作为消息 / 密钥字节（ADR-023 既有的唯一隐式转换，两端一致）。
- **只加密，不解密**：`aes-cbc` 只做加密方向。解密留待真实需求（见 §5）。

### 2.2 🔒 密钥与语义钉死（防两端漂移 / 防明文密钥）

1. **`aes-cbc` 的 key 必须是 `ref`**（validator D10 扩展覆盖 args[0]）：manifest 是**已签名分发**的产物，写入字面量密钥等于公开。key 恒为 `bind` 派生（如登录页盐值）或 `compute` 派生句柄。`iv` **非机密**，允许字面量或 ref。
2. **AES 密钥是原始字节，不是 passphrase**：key 字节**原样**作 AES 密钥，**绝不**走 OpenSSL `EVP_BytesToKey` / passphrase KDF（crypto-js 对字符串 key 的默认行为）。校本页面几乎都用 `CryptoJS.enc.Utf8.parse(key)` 即原始字节模式——adapter 作者须确认目标站点确为原始密钥。**此点是最大跨端 / 逆向陷阱，逐 op golden 必覆盖。**
3. **变体按 key 字节长度推断**：16/24/32 字节 → AES-128/192/256-CBC；其余长度**运行期 fail-closed**。与 crypto-js「按 key 长度定变体」一致，避免再加一个易漂移的 `variant` param。
4. **IV 必须恰 16 字节**，否则 fail-closed。
5. **padding 必填、无默认**（同 `hex.case`，避免两端默认漂移）：
   - `pkcs7`：标准 PKCS#7 填充（消息为块整数倍时**补整块** 0x10×16，标准行为）。
   - `none`：消息长度须为 16 的整数倍，否则 fail-closed；不加填充。
6. **摘要无参数、逐字节标准**：`md5`/`sha1`/`sha256` 为 RFC 标准摘要，输出定长原始字节（配 `hex`/`base64` 转文本）。

### 2.3 确定性不变量（本文能进封闭词表的前提）

ADR-023 §2.4 / ops.md §5：`random`/`uuid` **永久禁止**（破双跑 golden）。本批 4 个算子**全部确定性**：摘要天然确定；`aes-cbc` 在「相同 key + iv + message + padding」下密文唯一（IV 由 adapter 声明的字面量或句柄提供，**绝非运行期随机生成**）。因此本批**不引入任何随机源**，双跑 golden 成立。

### 2.4 明确出范围：随机化加密永久排除（除非 broker 定值喂入）

**随机 IV / 随机填充的加密进不了封闭词表**，与 `random`/`uuid` 同理：

- ❌ **随机 IV 的 AES**、**RSA-OAEP**、**RSA-PKCS#1 v1.5 加密**（填充随机）、滑块验证码 AES（随机 nonce）。这些留在 **WebView / imperative** 地盘（ADR-016 / ADR-009），不塞进封闭词表。
- ✅ 本文的固定 IV AES-CBC、裸摘要是确定性的，可进。RSA-PKCS#1 v1.5 **签名**（确定性）、AES-ECB、DES/3DES 亦确定性，**但不进首批**（§5）。

> **将来若确需随机 IV/nonce**：设计一个**由 broker 定值喂入的确定性 nonce 通道**（类比 `now` 复用 `AdapterRunInput.nowMs`：宿主喂定值、双跑可复现），而非放开 `random`。这是独立设计问题，本 ADR 不做，仅标记为可扩展。

### 2.5 安全承重墙：继承 ADR-023 §2.5 污点三约束，不新开面

本批算子只是 `compute` 阶段的新纯函数，**不改变** ADR-023 的数据流执行模型与污点闸门：

1. **摘要（md5/sha1/sha256）= 单向**，与既有 `hmac-sha256` 同形，对秘密值取摘要再注入不引入新回读面。
2. **`aes-cbc` = 可逆，加密 tainted 明文并注入 = 凭证派生流**，落 ADR-023 §2.5 MVP 允许项，靠 **broker 回显剥离（`stripEchoes`）+ official 人工审**兜底。静态 DAG（无分支）+ 静态汇聚点（`inject.into/at/name` 声明死）在语法上排除「依秘密值选择发不发请求 / 注入到哪」，故 MVP 期免费成立的两条格式约束对新算子同样成立。
3. **已接受的残余风险（继承，不新增）**：
   - **长度预言机**：AES 密文长度（PKCS7 向上取整到块）泄漏明文长度的块粒度信息——归入 ADR-023 §2.5 已接受的长度预言机类，不新开面。
   - **比较预言机（每次运行 1 bit）**：同既有，official 人工审 + 用户触发（无法高频循环）缓解。
   - **变体按 key 长度推断**：key 长度非法 → 整条 capability fail-closed，与正常失败不可区分（错误只进宿主日志，ADR-023 决策 6）；adapter 观测不到具体变体。
4. **key 须 ref（§2.2 第 1 条）**封死 manifest 明文密钥面。

### 2.6 信任门：沿用 ADR-023 §2.6，不新增

新算子只是**声明面表达力**扩展，**不给 adapter 加任何标识符 / 网络 / 见值能力**——数据流全程仍由 broker 执行，句柄不进 adapter。故信任门沿用 ADR-023 §2.6：`official` 与（结构上仅存在于 DEV 构建的）`sideload` 同权，validator D13 正向允许表不变。`adapter-policy`（check-adapters）**无需改**（新 op 不引入任何 `FORBIDDEN_NAMES`）。

---

## 3. 落地性（挂现有 seam，非新造）

对齐计划文件 `declaractive-cyberchef-adapters-buzzing-nest.md`：

- **契约 schema**：`contract/manifest.schema.json` 的 `compute[].op` 枚举加 4 项；`aes-cbc` 的 `padding` 枚举。纯新增、向后兼容（红线 #6）。
- **validator**：`tools/src/validator/dataflow.ts` 的 `OP_SIGNATURES` 加 4 项签名；`aes-cbc` 的 args[0]（key）进 `refOnly`（复用现有 D10 机制）。iv 为普通 arg（可字面量可 ref）。
- **两端 runtime（🔒 逐字节对齐）**：`server/.../dataflow.ts` `evalOp`（`node:crypto` `createHash`/`createCipheriv`）为 golden 基准；`client/.../dataflow.dart` 生产实现（`package:crypto` 摘要 + `pointycastle` AES-CBC），**须与 TS 逐字节一致**（block mode / PKCS7 / IV / 原始密钥是主要踩坑面，参照 `urlencode`/`substring` 的跨端教训）。
- **算子事实来源**：`docs/reference/declarative_dataflow_ops.md` §1/§2/§5。
- **golden 向量**：`contract/golden/broker/dataflow.json` 每 op ≥1 条双端向量（含 AES-128/256 + pkcs7/none + iv 长度负例 + 原始密钥用例）。

---

## 4. 取舍（Consequences）

**收益**
- 西电水电取数、body 签名等一批场景从 imperative 收回声明式：broker 持密钥并加密、adapter 只声明方案，不必开 `ctx.fetch` + 见值（触红线 #1 的最高风险面）。
- 对 adapter 作者门槛**下降**；对可信核心是**受控**的复杂度增量（每 op 双端实现 + golden + 人工安审）。

**代价 / 已知约束**
- 每个新算子 = 两端逐字节实现 + golden + 🔒 人工安审，成本随算子数量线性增长——故须克制、证据驱动。
- AES 的原始密钥 vs passphrase、变体推断、PKCS7 补整块等跨端陷阱须逐 op golden 钉死。
- 承重路径实现不得 AI 独自闭环（AGENTS.md §1）。

---

## 5. 首批不含（记录，避免反复重提）

| 缺席项 | 理由 |
|---|---|
| `sha512` | 无真实抓包证据；出现即按 §2.1 表格式补入 |
| `aes-ecb` / `des` / `3des` | 确定性、可后补，但首批无证据；ECB 语义弱、优先不鼓励 |
| `aes-cbc` **解密** | 首批只加密（登录 / 取数是「构造密文发出」）；解密留待真实需求 |
| `rsa-sign-pkcs1`（确定性签名） | 需私钥 = 凭证派生 `ref`，留待 ADR-017 §2.8 mint 盲区有具体方案时一并裁定 |
| 随机 IV AES / RSA-OAEP / RSA-PKCS#1 加密 | §2.4：随机化破双跑 golden，**永久排除**（除非 broker 定值喂入 nonce 通道），留 WebView / imperative |
| `text → bytes` 解码 op | ADR-023 §0：会打开 `bytes` 第二来源，破坏类型系统封闭性；无真实需求 |

---

## 6. 待人工复核清单（本 ADR 接受前）

1. §2.2 AES 语义（原始密钥、变体推断、IV 16 字节、PKCS7 补整块、`none` 需块整数倍）逐条确认，并核对西电真实抓包（`adapters_tests/XIDIAN/energy/meter.py`、`ids/login.py`）行为一致。
2. §2.5 确认新算子不越出 ADR-023 §2.5 已接受的污点残余风险边界（无新回读 / 无新汇聚点侧信道）。
3. `contract/golden/broker/dataflow.json` 双端向量覆盖度（变体 / padding / 负例）。
4. `declarative_dataflow_security_checklist.md` 增可逆加密专项条目。

---

## 7. 决策记录 · 被拒方案：细粒度加密原语（owner 2026-07-29）

**评估问题**：是否把加密算子拆成更小原语（裸 AES 分组置换、CBC 链接、XOR、填充分离），让 adapter **元素组合**加密，以适配某些学校**魔改**的加密过程？

**决策：不拆。** 保持**粗粒度标准算法算子**（§2.1），细原语明确**排除**。魔改场景的归宿是 §2.4 预留的 QuickJS hermetic 纯函数逃生门（ADR-023 §2.4），不是细原语。

### 7.1 三层阶梯（细原语是被刻意跳过的那层）

| 层 | 工具 | 覆盖 | 何时建 |
|---|---|---|---|
| 1 | 粗标准算子 `aes-cbc` / `sha256` | 标准学校（西电即是） | **本 ADR（已落地）** |
| 2 | 证据驱动的**命名复合算子** / param 变体 | 常见小魔改（如 AES 后字节反转） | 出现真实重复案例，按 §2.1 表格式补入 |
| ~~1.5~~ | ~~细原语 XOR / 分组置换 / 填充分离~~ | ~~—~~ | **被拒**（见 §7.2） |
| 3 | QuickJS hermetic 纯函数 compute 节点 | **任意**魔改加密 | ADR-023 §2.4 触发条件 = 举出封闭词表表达不了且非命令式的真实案例 |

### 7.2 拒绝细原语的三条理由（叠加 = 最坏中间地带）

1. **可复现性变差，不是变好。** 标准 `aes-cbc` 直接映射 `node:crypto` / pointycastle 的高层 API，共享同一份 NIST/RFC 且有**外部权威测试向量**，两端天然一致。拆成「裸 AES 分组 + 手写 CBC + XOR」= 在两种语言里**各自重实现加密内部、且无外部向量可对**，正确性自定义、漂移风险全压己方（`urlencode`/`substring` 跨端踩坑的放大版）。
2. **炸开污点侧信道面。** ADR-023 §2.5「adapter 不见值」闸门的前提是 `compute` 算子**粗粒度、一次性、无依值分支**。细原语相反：`XOR(tainted, 选定值)` 是逐位套值预言机的经典构件；逐分组操作 + 观察成败 = 每次运行泄漏更多 bit；分组数依明文长度 → 需**循环/迭代**，直接破 ADR-023 §2.4「固定 DAG、无依值控制流」前提。粗算子**约束**组合，细原语**放开**组合，而组合面由 adapter 作者写、仅人工审。
3. **单算子更可审 ≠ 整体更可审。** 危险在**组合**：得审每一种组合是否预言机 gadget，组合面无穷。这正是封闭词表要防的（ADR-023 §2.4：任意计算不走词表扩张）。

### 7.3 魔改的正确归宿 = QJS 逃生门，非细原语

学校的魔改加密（双重 AES、字节反转、自制流密码、怪填充）= **任意但确定性的计算**。ADR-023 §2.4 已为此预留 **QuickJS hermetic 纯函数**：复用现有双端 QJS、删 `Date`/`random` 即得确定性纯函数、复用现有 golden 与限额、零新依赖。它是**一个更大的单审计盒**，把魔改逻辑**关起来**，而**不**在声明式污点模型里散布可自由拼接的细粒度 crypto gadget。**触发条件**：举出粗算子 + 命名复合算子（tier 1/2）都表达不了、且非命令式（非动态拓扑、值须对 adapter 不可见）的真实魔改案例——届时按 ADR-023 §2.4 加一个 QJS compute 节点，无需新基础设施。

**细原语正是"最坏中间地带"**：兼具 tier 1/2 的复现成本 + 逼近 tier 3 的侧信道风险，却**没有** tier 3 的单盒隔离。故排除。

### 7.4 必要性 / 可复现性小结（回应评估初衷）

- **必要性**：当前**无证据**。已抓包学校（西电）用标准 AES-CBC + 标准摘要，粗算子已覆盖。现在建细原语违反「证据驱动、克制」。
- **可复现性**：细原语**更差**（无外部向量、重实现内部）；粗算子 + 必要时 QJS 盒子都优于细原语。
