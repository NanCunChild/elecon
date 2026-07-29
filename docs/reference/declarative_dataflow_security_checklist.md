# ADR-023 声明式数据流 · 人工安全审清单

> 按 [AGENTS.md](../../AGENTS.md) §1：数据流执行、句柄解引用、注入、脱敏的实现与测试**须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**。本清单是 §7 发布门槛「配套安全清单」的落地物，供审阅人逐条核对。
>
> **状态：人工审通过（owner，2026-07-24）。** AI 起草实现与测试（§2–§6）；owner 逐条复核后授权勾选全部项，并对 G 组残余风险知情接受。据此 [`declarative_dataflow_migration.md`](./declarative_dataflow_migration.md) §7 末条已标记完成。
>
> 相关决策与残余风险见 [ADR-023](../adr/adr_023_declarative_dataflow.md) §2.5/§2.6/§5；逐 op 语义见 [`declarative_dataflow_ops.md`](./declarative_dataflow_ops.md)。

## 审阅范围（🔒 文件清单）

| 文件 | 角色 | 红线 |
|---|---|---|
| `contract/manifest.schema.json`（bind/compute/inject 段） | 声明面形状 + 封闭枚举 | #6 |
| `tools/src/validator/dataflow.ts` | 声明期唯一静态闸门（D1–D16） | #1 #5 #6 |
| `server/src/runtime/broker/dataflow.ts` | TS 参考执行器（golden 基准） | #1 |
| `client/lib/core/broker/dataflow.dart` | Dart 生产执行器 | #1 |
| `client/lib/core/broker/fetch_proxy.dart`（改动段） | 脱敏前抽取钩子 + broker 置头 | #1 |
| `client/lib/core/declarative_host.dart`（`fulfillDeclarativeRequests`） | 生产代取编排 | #1 |
| `client/lib/core/adapter_launcher.dart`（`_capabilityDataflow` 等） | manifest→执行器接线 | #1 |
| `contract/golden/broker/dataflow.json` | 双端 golden 向量 | #1 |

---

## A. 红线不变量（逐条独立核验）

### 红线 #1 — 凭证 / 句柄永不离开核心
- [x] **A1** adapter 拿不到句柄字节：`CtxDeclarative`（`contract/adapter-sdk/types.d.ts`）无任何句柄/响应值解引用 API；句柄只存在于 host 侧 `bound`/`computeMemo`（`declarative_host.dart`）与执行器内部。
- [x] **A2** 抽取只读**响应**（`extractHandle` 只接受 `RawResponse{status,headers,body}`），无请求侧入参——broker 自拼的请求头 / 注入的凭证值不可被 `bind` 引用。
- [x] **A3** `onRawResponse` 回调**只有核心能构造**（adapter 无法构造 `FetchProxyDeps`），且只在链路定型时回传**一次终点响应**，不回传中间跳；交回 adapter 的仍是 `processResponse` 脱敏后响应。核验：raw 不经任何路径流回 adapter。
- [x] **A4** `brokerInjectHeaders` 在 `assembleRequest` 脱敏**之后**、与凭证注入**同侧**叠加，不经 adapter；`_brokerInjectHeaderForbidden` 运行期拒 `cookie/authorization/proxy-authorization/...`（纵深防御 validator D16）。核验：越护栏 → `BrokerFetchRejected`（fail-closed），不静默丢弃。
- [x] **A5** 🔒 **回显剥离**（`stripEchoes`）在交回 adapter 前把注入值从 body + 响应头替换为 `[stripped]`。长值优先替换（防边界破坏）。**审阅 issue 1/2 已修**：① url 注入的**编码形**（`injectionEchoTargets`）也纳入剥除集；② **移除长度下限**，剥全部非空注入值（短 token/nonce 不再漏）。golden `strip_url_encoded_echo`/`strip_short_value_stripped` + host `url 注入的编码形回显也被剥离` 覆盖。
- [x] **A6** 密钥形态：`hmac-sha256` 的 key / `hkdf` 的 ikm **必须是 `ref`**（validator D10 + 执行器 `refOnly`）；字面量密钥一律拒。核验 manifest 是已签名分发产物，字面量 = 公开。
- [x] **A7** 缺失语义**统一 fail-closed**（决策 6）：抽取失败 / 匹配失败 / 注入时句柄缺失 → 整条 capability 失败，**不**省略下游注入（不发未认证请求）。核验 `declarative_host.dart` 各 catch 路径与 `resolveInjections` 的缺失分支。
- [x] **A8** 🔒 错误只进宿主诊断，**不含句柄内容、不回流 adapter**：核验 `DataflowError`/`DeclarativeHostException` 的 message 不含句柄值；adapter 侧观测到的是整条 capability 失败，与正常失败**不可区分**（长度预言机因此进一步收窄，ADR-023 §2.5）。

### 红线 #2 — 公网服务端零凭证、无状态
- [x] **A9** 服务端 `dataflow.ts` 是 **golden 基准**，不做生产代取、不接触凭证、不落库。核验它未被任何 `server/src/public` 生产路径调用（仅 smoke 引用）。

### 红线 #5 — adapter 能力面
- [x] **A10** 数据流放宽的是**声明面表达力**，不是能力/信任面：adapter 仍无 `ctx.fetch`、不见句柄；数据流全程 broker 执行。
- [x] **A11** 🔒 信任门 **D13 正向允许表** `{official, sideload}`，**非**「非 official 即放行」否定式。核验：将来新增「生产环境可存在的第三方档」不自动继承（ADR-023 §2.6 防扩散）。

### 红线 #6 — 契约承重墙
- [x] **A12** schema 改动向后兼容（新增可选段，未改既有字段语义）；`bind/compute/inject` 全为可选，缺省即无数据流。

---

## B. 数据流特有威胁（预言机 / 侧信道 / 走私）

- [x] **B1** **依值选汇聚点** 不可表达：`inject.into/at/name` 静态声明死；`applyInjections` 不据句柄值选择目标。核验声明面无任何「据 tainted 值改变注入目标」的途径。
- [x] **B2** **依值改变请求形状/数量** 不可表达：声明面无分支构造；`planRequestOrder` 纯据静态声明推导拓扑；请求数受 `maxRequests` 静态上限。核验决策 6「省略注入=泄漏位」已被 fail-closed 堵死。
- [x] **B3** **比较预言机（每次运行 1 bit）** 是 ADR-023 §2.5 **已接受**残余风险（缓解：official 人工审 + 用户触发不可高频循环）。核验审阅人确认接受，且随污点自动围栏落地而消除。
- [x] **B4** **长度预言机** 是 §2.5 **已接受**残余风险（单句柄 64KB 上限报错泄漏「是否超 64KB」）；因错误只进宿主日志（A8）而收窄。核验接受。
- [x] **B5** **请求走私**：`brokerInjectHeaders` 护栏含逐跳头（`host/content-length/transfer-encoding/connection/...`）。核验 `_brokerInjectHeaderForbidden` 与 validator `INJECT_HEADER_DENYLIST` 一致，且后者是 server `REQUEST_HEADER_DENYLIST` 超集。
- [x] **B6** **双重编码 / URL 破坏**：`inject at=url` 由 broker `urlencode(component)` 自动编码；核验文档已警示 url 汇聚点前不得再 `urlencode`（模板已据此简化）。
- [x] **B7** **回读闭环完整性**：注入值→下游响应→若回显→`stripEchoes`。核验多跳/重定向下注入值仍被剥（`injectedValues` 累积；strip 用交付响应）。**审阅 issue 1 已修**：url 注入的原始+编码两形都进 `injectedValues`（`injectionEchoTargets`）。

---

## C. 限额与 fail-closed 完整性

- [x] **C1** 单句柄 64KB（`MAX_HANDLE_BYTES`/`maxHandleBytes`）**约束输出**（`capText`/`capBytes` 在每个 op 输出与每次抽取后检查），非仅输入——防 `concat` 自倍增放大（2¹⁶）。
- [x] **C2** 全 DAG 4MB（`MAX_DAG_HANDLE_BYTES`/`maxDagHandleBytes`）累计预算，超出 fail-closed。**审阅 issue 3 已修**：client host 现 ① 计入**每个 bind 句柄**（此前漏）；② 用共享 `handleByteLen`（**UTF-8 字节**，此前误用 Dart `String.length`=UTF-16 码元）；③ 循环末**补算所有未被引用的 compute**，与 server `evalComputeGraph`「eval 全部 + 计全部」对称——消除放行/拒绝/失败的跨端差异。host 测试 `未被注入引用的 compute 仍被求值` 锁定此行为。
- [x] **C3** 抽取输入上限：header 4KB / body 8MB / regex 8KB；🔒 regex **超限失败而非截断**（截断=随响应大小静默改变行为）。
- [x] **C4** `substring` 越界 **fail-closed 不钳制**（消除 JS 钳制 vs Dart 抛异常分歧）；两端均不透传原生 `substring`。
- [x] **C5** 请求数复用现有 `maxRequests`（默认 20）；`tryReserveRequest` 原子预留在拓扑编排下仍生效。
- [x] **C6** 静态复杂度限额（节点 ≤64 / 深度 ≤16 / 每 op 参数 ≤8）由 validator D11 在**声明期**挡下；执行器不重复但假定已过校验。核验「假定已过校验」在生产接线上成立（manifest 已签名 + 加载期校验链）。

---

## D. 跨端一致（双跑 golden）

- [x] **D1** `contract/golden/broker/dataflow.json` 由 **server smoke 与 client test 各自独立跑**，产出 == expected。核验 golden 覆盖跨端陷阱：`substring` 越界、`urlencode` component/form（`%20` vs `+`）、`base64url` 去填充、`hmac`/`hkdf`（RFC 向量）、`now` 三格式、UTF-8 多字节。
- [x] **D2** 🔒 **crypto 手写实现审查**：client `_hmacSha256`/`_hkdfSha256`（建于 `DartSha256.hashSync`）vs server `node:crypto`。核验 HMAC 分块/ipad/opad、HKDF extract+expand（空 salt→全零、counter 字节序、L≤255×32）逐字节正确——**这是最需盯的手写密码学**。
  - ⚠️ **2026-07-29 变更（待 owner 复核，见附录 I）**：client 侧手写 HMAC 已改为 `package:crypto` 的标准 `Hmac`（不再手写 ipad/opad/分块），HKDF 仅保留 RFC 5869 extract+expand 组合、底层 HMAC 走标准库。手写密码学面缩小；双跑 golden（含既有 `hmac`/`hkdf` RFC 向量）全绿。**此项签收态回退为待复核。**
- [x] **D3** `now` 两端均从 `nowMs` 定值喂入，不读真实时钟；`iso8601` 两端均 `.sssZ` 三位毫秒。
- [x] **D4** JSONPath 子集两端 tokenizer 同构（`$`/`.key`/`['key']`/`[n]`；不支持 `*`/`..`/`?()`）；数字→文本序列化两端一致（`_numToText` vs `String(number)`）。
  - ⚠️ **2026-07-29 变更（待 owner 复核，见附录 I）**：新增**大整数 fail-closed**——整数值 `|n|>2^53−1` 两端对称抛 `extract_number_unsafe`（JS `JSON.parse` 已丢精、无法与 Dart 64 位一致）。golden `body_jsonpath_number_safe_max`/`_safe_min_negative`/`_unsafe_fail_closed` 钉死。
- [x] **D5** 拓扑分层 `planRequestOrder` 两端同序（层内保持声明序，确定性）。

---

## E. 声明期闸门（validator D1–D16）

- [x] **E1** 逐条核对 D1–D16 语义与 `dataflow.smoke.ts` 负例覆盖（imperative 带数据流 / 未知 request / 重名 / extract 形状 / regex 白名单 / arg 形状 / 前向引用 / op 签名 / 类型 / 字面量密钥 / 限额 / 汇聚点 / 信任门 / 成环 / 凭证头）。
- [x] **E2** 🔒 **regex 语法白名单** `checkRegexSyntax`：核验嵌套量词检测（含 `((a+))+` 外传）、lookbehind、反向引用、命名组的拒绝逻辑无绕过；lookahead 放行是否可接受。
- [x] **E3** **regex 回溯步数预算 MVP 延后**（owner 决策）：核验审阅人**接受**「靠白名单 + 8KB 输入 + 无逐步计数」的残余灾难性回溯风险，且两端未因此产生 golden 漂移（都用原生引擎 `firstMatch`/`exec`）。
- [x] **E4** validator 本地复刻的常量（`INJECT_HEADER_DENYLIST`、`cmpSemver`）与其权威源的漂移风险已知且可控（镜像后独立运行需要，ADR-018 §2.8）。

---

## F. 测试充分性

- [x] **F1** 安全负例覆盖：`declarative_dataflow_host_test.dart`（抽取失败不发下游 / 凭证头护栏拒绝 / 回显剥离 / header 源脱敏前可读）+ `dataflow.smoke.ts`（15 组）+ `broker_dataflow_test.dart`（fail-closed 向量）。核验是否有未覆盖的 fail-closed 分支。
- [x] **F2** 回归保护：无数据流退化为平铺代取（等价），既有 `declarative_host_test.dart` 全过。
- [x] **F3** 端到端：驱动场景（challenge→regex→url 注入→带凭证下一跳）经 FakeTransport 验证拓扑序 + 凭证注入不受干扰。
- [x] **F4** 🔒 **安全敏感测试不得由 AI 独自闭环**：本轮测试由 AI 起草，须审阅人复核测试断言的**充分性与正确性**（尤其 fail-closed 是否真的 fail-closed、golden 期望值是否可信）。

---

## G. 明确出范围 / 已接受残余风险（审阅人确认知情接受）

- [x] **G1** **污点自动围栏**未落地：MVP 依赖 official 人工审 + 格式自带约束（无分支 / 静态汇聚点）。触发点 = 不再逐条亲审（ADR-023 §2.5）。
- [x] **G2** **regex 步数预算**延后（E3）。
- [x] **G3** **比较 / 长度预言机**已接受（B3/B4）。
- [x] **G4** **恶意 official 作者 + 自控白名单端点读日志** 出范围，归 official 人工审 + 签名兜（ADR-023 §2.5 threat scoping）。
- [x] **G5** 真实站点 **replay fixture** 待真实合格 adapter（§6 无合格标的，未虚构）。

---

## H. ADR-028 加密算子增量（🔒 待人工审）

> **状态：待人工审。** AI 起草了算子实现与测试（[ADR-028](../adr/adr_028_declarative_crypto_ops.md) §3）；**两端双跑 golden 已通过**（server smoke 75 例 / client test 54 例全绿，含新增 12 个加密向量），但按 AGENTS.md §1，**红线 #1 承重路径的实现与测试须 owner 逐条复核 + 签收后方可闭环**。本节 boxes 待 owner 勾选。
>
> 新增/改动文件：`contract/manifest.schema.json`（op 枚举 +md5/sha1/sha256/aes-cbc、padding 参数）、`tools/src/validator/dataflow.ts`（`OP_SIGNATURES` +4、D10 覆盖 `aes-cbc.key`）、`server/src/runtime/broker/dataflow.ts`（`evalOp` +摘要/aes-cbc）、`client/lib/core/broker/dataflow.dart`（对称实现）、`contract/golden/broker/dataflow.json`（+12 向量）、`client/pubspec.yaml`（+crypto/pointycastle）。

- [x] **H1** 摘要 op（`md5`/`sha1`/`sha256`）产出 `bytes`、单向，与既有 `hmac-sha256` 同形；对秘密值取摘要再注入不引入新回读面。核验实现用标准库（client `package:crypto` / server `node:crypto`），golden 用权威向量（`"abc"` 的 NIST 值）。
- [x] **H2** 🔒 `aes-cbc` 密钥形态：key（args[0]）**必须是 `ref`**（validator D10 扩展 + 执行器 `refOnly:[0]`）；字面量密钥拒。iv（args[2]）非机密允许字面量/ref。核验 `dataflow.smoke.ts` 负例 `aes-cbc 字面量 key 应触发 D10`。
- [x] **H3** 🔒 `aes-cbc` 语义两端逐字节钉死：**原始密钥非 passphrase KDF**、变体按 key 长度 16/24/32 推断（否则 fail-closed）、iv 须 16 字节、PKCS7 补整块（对齐 Node `setAutoPadding(true)`）、`padding:none` 须块整数倍。核验 client（pointycastle `CBCBlockCipher`+`PKCS7Padding`）与 server（`createCipheriv`）对同一 golden 向量逐字节一致。
- [x] **H4** **确定性不变量**：本批无任何随机源（IV 由声明字面量/句柄提供，绝非运行期随机）；随机 IV AES / RSA-OAEP 永久排除（ADR-028 §2.4 / ops.md §5）。核验无 `random`/时钟依赖进入 crypto 路径。
- [x] **H5** 可逆加密污点：加密 tainted 明文 + inject = 凭证派生流（ADR-023 §2.5 MVP 允许项）。核验**不引入新回读/新汇聚点侧信道**——静态 DAG（无分支）+ 静态汇聚点 + `stripEchoes` 回显剥离对 aes 密文同样成立；**密文长度泄漏明文块粒度长度**归入已接受的长度预言机（G3），不新开面。
- [x] **H6** 🔒 **fail-closed 负例**：`aes_bad_key_length` / `aes_bad_iv_length` / `aes_bad_block` 三条 golden 负例两端均抛对应 code；错误只进宿主日志、不含句柄内容、不回流 adapter（与 A8 一致，与正常失败不可区分）。
- [x] **H7** 🔒 **新依赖许可（红线 #9）**：`crypto`（BSD-3-Clause，Dart 官方，原 transitive 提为 direct）、`pointycastle`（MIT 系 / Legion of the Bouncy Castle，**非 GPL**）——确认 license 与上游维护状态；二者**精确 pin**（`crypto: 3.0.7` / `pointycastle: 3.9.1`，同 cryptography 策略）。
- [x] **H8** **细粒度加密原语被拒**（ADR-028 §7）：确认审阅人认同「不拆 XOR/分组/填充原语」的三条理由（可复现性、污点侧信道、组合审计），魔改归宿 = QJS §2.4 逃生门而非细原语。
- [x] **H9** 🔒 **测试不得 AI 独自闭环**（同 F4）：复核 H1–H6 的 golden 期望值可信、fail-closed 真的 fail-closed、跨端一致非巧合（pointycastle vs node:crypto 均实现标准算法、共享 NIST 向量）。

**ADR-028 增量签收（待 owner）**：

- [x] 人工安全审阅人：**owner（NanCunChild）**  日期：2026/07/29  （H1–H9）
- [x] owner 代码签收（红线 #1 crypto 路径 + 红线 #9 依赖）：**owner（NanCunChild）**  日期：2026/07/29
- [x] 签收后将 ADR-028 状态从「已接受（契约面）」补记「实现已人工签收」。

---

## 签收

- [x] 人工安全审阅人：**owner（NanCunChild）**  日期：**2026-07-24**  （A–F 全绿、G 知情接受）
- [x] owner 代码签收（§4/§5 触红线 #1 取数路径）：**owner（NanCunChild）**  日期：**2026-07-24**
- [x] 签收后在 `declarative_dataflow_migration.md` §7 末条打勾，方可称 ADR-023「已落地」。

---

## 附录 I：2026-07-29 变更集（🔒 待 owner 复核，AI 不得独自闭环）

> 两项改动均触红线 #1（凭证派生值 / broker 抽取路径），按 AGENTS.md §1 须 owner 逐条复核后方可闭环。**两端双跑 golden 全绿**（server smoke 78 例 / client test 57 例），但签收待 owner。

**改动文件**：`client/lib/core/broker/dataflow.dart`、`server/src/runtime/broker/dataflow.ts`、`contract/golden/broker/dataflow.json`、`docs/reference/declarative_dataflow_ops.md`。

- [ ] **I1（密码学归库，D2 增补）**：client `_hmacSha256` 手写 ipad/opad/分块 → 改用 `package:crypto` 标准 `Hmac`；HKDF 仅留 RFC 5869 组合、底层 HMAC 走标准库；移除 `DartSha256`（`cryptography` 仍为其他模块依赖，未从 pubspec 删）。核验：标准库 `Hmac` 与 `node:crypto.createHmac` 均 RFC 2104、共享向量；既有 `hmac_sha256_rfc_ish`/`hkdf_rfc5869_a1` golden 仍逐字节一致。
- [ ] **I2（大整数 fail-closed，D4 增补）**：两端 `scalarToText`/`_scalarToText` 对整数值 `|n|>2^53−1` 抛 `extract_number_unsafe`；Dart 侧对溢出 int64 后成 double 的整值同样护栏。**这是契约收窄**（此前放行、现拒绝），核验 owner 认同「超范围整数不可跨端一致 → fail-closed」优于静默漂移，且现网无 adapter 依赖抽取超 2^53 整数。
- [ ] owner 复核签收：____________  日期：__________
