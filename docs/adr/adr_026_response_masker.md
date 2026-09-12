# ADR-026：Broker 响应凭证收割与投影（Response Masker）

- **状态**：已接受（2026-07-30）。本文将原 Deferred 议题重构为正式方案；Broker、契约、签名 bundle 与正式 adapter 的各阶段实现仍须人工安全复核。
- **日期**：2026-07-27；2026-07-30 重写职责与迁移方向；2026-08-07 接受 selector miss 语义与 mandatory policy gate
- **适用范围**：Broker 从学校响应中提取非标准凭证敏感值、在核心内建立受控引用，并向 declarative / imperative adapter 交付投影响应。
- **触及红线**：#1、#5、#6、#10。凭证收割、存储、句柄、注入、响应投影和签名发布均属人工主导的承重路径，AI 不得独自闭环。
- **依赖**：[`ADR-000`](./adr_000_abstract.md)（可信核心与凭证边界）、[`ADR-009`](./adr_009_fetch_credential.md)（响应脱敏）、[`ADR-012`](./adr_012_credential_store.md)（凭证存储）、[`ADR-018`](./adr_018_adapter_distribution.md)（签名 bundle 与发布门）、[`ADR-023`](./adr_023_declarative_dataflow.md)（不透明句柄）、[`ADR-029`](./adr_029_named_and_body_credentials.md)（命名 header / body 注入）。
- **工程说明**：[`docs/reference/response_masker_plan.md`](../reference/response_masker_plan.md)。  
- **JSON 定位 / 重复键 / DEV 诊断决议**：[`docs/reference/response_masker_json_locator.md`](../reference/response_masker_json_locator.md)（B1 拍板，2026-07-31）。

本文接受后，显式修订 ADR-009 §2 第 5 条的 body 透传边界：普通业务 body 仍可在投影后交给 adapter；经 official 审核分类的 credential-equivalent 不再属于可接受透传风险，必须由本文机制收割或删除。未知、漏报字段仍属于 §2.6/§5.2 的供应链残余风险。

本文同时修订 ADR-018 的 bundle 内容说明：official adapter 的 `masker.json` 是 mandatory、受 host/version gate 约束的签名运行时文件；其 `rules` 可为空。现有 signer 已覆盖 `.json`，但加载、校验和发布治理仍须按本文补齐。

## 1. 背景

学校协议并不总把会话材料放在标准 `Set-Cookie`、`Authorization` 或 OAuth 回调中。真实接口可能把可鉴权、重放或延续会话的值放在：

- `ETag`、自定义响应头；
- JSON 固定字段；
- HTML 属性、脚本变量或文本片段；
- URL、Base64、hex 或校本编码结构。

现有 imperative adapter 可以从完整 body 中用正则或 JSON 解析自行取得这些值，再拼入后续请求。这虽然能适配混乱协议，却让 adapter 同时承担了凭证识别、取值、生命周期、注入和业务归一化，扩大了凭证可见面，也使 declarative 迁移无法完成。

仅在 adapter 交付前替换字符串也不够。若 adapter 的后续请求仍依赖该值，单纯 Masker 会破坏流程，迫使 adapter 绕过它重新取值。因此本 ADR 不再把 Masker 定义为可有可无的后置过滤器，而把它定义为一个完整的 **Broker 响应凭证收割与投影层**：核心先取得并托管值，再删除 adapter 响应中的原值，后续由 Broker 受控注入。

## 2. 决策

### 2.1 定位：功能边界优先，安全收益随之成立

Response Masker 承担三项不可拆分的职责：

1. **Capture（收割）**：按 official 人工审核确认的签名策略，从原始响应中提取凭证敏感值。
2. **Commit（托管）**：把值写入 Credential Store、建立 request-local opaque handle，或在确认无需后续使用时直接丢弃。
3. **Project（投影）**：从交给 adapter 的响应中删除或替换原值，并清理失效的实体元数据。

其首要必要性是功能分层：adapter 负责学校业务数据归一化，核心负责凭证生命周期和后续注入。adapter 不再需要从未过滤 body 中正则提取凭证。减少凭证暴露是该分层带来的直接安全收益，而不是唯一立项理由。

目标态下，除 `Set-Cookie`、redirect/query harvest 等已有通用结构化收割器外，**所有经人工分类、来自网络响应并供后续认证或请求使用的非标准凭证敏感值都必须进入本层**；正式 adapter 不保留自行取值的平行路径。

### 2.2 人工签名是分类信任锚，不是原值可见许可

系统不尝试用字段名、熵、词表或通用正则自动证明某值是凭证。字段分类来自 official adapter 的社区规范审查、fixture 证据、人工安全复核和离线签名门。

official 签名表示维护者认可该 adapter 代码与响应策略的组合，不表示 adapter 代码应获得核心持有的全部原值。Broker 仍按最小权限执行签名策略：核心读取值，adapter 只看到完成投影后的业务响应。

### 2.3 三类处理目标

每条 capture 规则必须静态声明唯一目标，不得由 adapter 在运行时决定：

| 目标 | 核心形态 | 生命周期 | 典型用途 |
|---|---|---|---|
| `credential` | Credential Store 中的具名 credential ref | 跨执行，遵循更新、失效、撤销策略 | session/token 刷新后供后续 capability 注入 |
| `handle` | Broker opaque handle | 单次 capability 执行 | ADR-023 跨请求提取、计算与注入 |
| `redact` | 不保存 | 当前响应 | 只需阻止交付的敏感回显或一次性材料 |

`credential` 的名称、类型和 scope 必须来自已签名 manifest 的既有声明；Masker 规则不能动态创建凭证名、扩大 scope 或自行决定持久化位置。`handle` 只能流向静态声明的注入汇聚点，adapter 不得解引用。

**规范推荐（A1，2026-07-31）：`redact` 语义为「仅投影、不托管、不注入」——命中值既不写 Credential Store 也不建 handle。若某敏感值后续不需要参与认证或请求，adapter 作者应优先用 `redact` 而非 `handle`，以最小化核心对该值的留存与接触面。预期 `redact` 用例应少于 `handle`；本推荐须落入 adapter 贡献规范。**

首期持久 `credential` capture **仅允许 client-direct**，沿用 ADR-012 §2.6 的 canonical store 边界。TS Broker 仍需实现同语义 Capture / Project 以保证双端确定性，也可持有 execution-local handle，但 public 不处理私密响应，campus-relay 在其凭证零落盘与回传方案另行接受前不得持久化 capture 值。

凭证的取得端点不要求与后续 injection scope 相同。已验签 `masker.json` 中“固定 source URL scope -> 既有 credential ref”的绑定本身就是 acquisition 授权：source scope 必须是 manifest `network.allow` 的子集，destination ref 必须已存在；它只能更新该 ref，不能改变该 ref 的 injection scope。若未来需要多个独立 policy pack，再另行拆出 acquisition scope 契约，不在首期 manifest 重复声明。

### 2.4 统一且不可绕过的响应事务

declarative、imperative 与 **actuator（[ADR-030](./adr_030_actuator_capabilities.md)，2026-08-05 已接受）三入口**必须经过同一个 Broker delivery firewall——**三种情况都需统一防火墙收口**，任一入口都不得各自直接构造 adapter-visible 响应：

```text
adapter request declaration / ctx.fetch / action entry
  -> Broker 注入决策与 Transport
  -> Cookie / redirect / query 等结构化核心处理
  -> Response Credential Policy 匹配
  -> Capture：从原始响应提取值
  -> Validate：类型、数量、大小、scope、目标与生命周期
  -> Project：删除/替换 adapter-visible 响应中的原值
  -> Commit：原子提交 credential / opaque handle
  -> dataflow 回显剥离
  -> adapter
```

Capture、Validate、Project 和 Commit 是一个交付事务。selector 缺失按 §2.5 只令该规则 miss；命中规则的任何步骤失败时响应不得进入 adapter。不得出现“凭证已经写入但投影失败仍交付原 body”或“投影成功但句柄缺失后继续发未认证请求”的半完成状态。

首期每个响应事务最多更新 **一个持久 credential ref**；所有 handle 先在 execution-local staging generation 中完成预算校验，不直接修改活动表。实现先准备投影响应与 staged handles，再执行一次安全存储原子替换，成功后以不可失败的内存 swap 激活 handles。安全存储写入后若进程崩溃，允许出现“新 credential 已保存但本次响应未交付”的安全侧偏差；不得出现原响应泄漏或部分持久凭证集合。若未来单响应必须原子更新多个持久 ref，须先为 Credential Store 增加 generation/CAS 与崩溃恢复设计，不能放宽本文语义。

日志不得包含原值、命中片段、原始 body、带敏感 query 的 URL 或可推导凭证长度的信息。

**开发者溯源诊断（2026-07-31）**：允许在宿主诊断中输出**结构定位**（错误码、规则 id、JSONPath / header **名**、重复键的 key **名**），但永不输出材料原值。该详细诊断**预备挂在 [ADR-024](./adr_024_build_profile_trust.md) 的 DEV 信任 profile** 上（编译期 flag，与优化等级解绑），**不**绑定传统 `kDebugMode`。DEPLOY 仅保留稳定错误码级摘要。字段白名单与接线节奏见 [`response_masker_json_locator.md`](../reference/response_masker_json_locator.md) §3。

### 2.5 selector miss 与 fail-closed 边界

2026-08-07 owner 决定不在规则上增加 `optional` / `required` 字段。每条 selector 缺失（header 无命中、JSON key 不存在或数组下标越界）即该规则 **miss 并跳过**；mixed hit/miss 合法，只有命中规则参与 Capture / Project / Commit。所有规则 miss 或 `rules: []` 时，正常交付已经过 Broker 通用脱敏的原响应，`captured=[]`，不写 Credential Store，既有 credential 保持不变。

miss 只覆盖“路径在正确容器中确实不存在”。以下情况仍 fail-closed：

- header 多命中或其他数量异常；
- JSON 路径导航期望 object / array、实际容器类型不符（稳定码 `capture_type_mismatch`，不得归为 `capture_not_found` 或被 miss 吞掉）；
- **JSON 对象内重复键**（路径导航层级上同名键出现 ≥2 次）：fail-closed（建议码 `capture_duplicate_key`）；**不**提供 first/last 选择器，**不**重命名消歧——畸形载荷责任在学校侧，见 [`response_masker_json_locator.md`](../reference/response_masker_json_locator.md) §2；
- JSON / JSONPath 解析错误、错误容器类型、非标量或 `null`；
- 类型、大小、深度、扫描预算、scope 或目标校验失败；
- 投影、Credential Store 或 opaque handle 提交失败：fail-closed；
- Masker 内部异常：fail-closed；
- 命中载体格式变化并触发上述解析、类型或校验错误：等待 adapter 代码与响应策略在同一签名 bundle 中原子更新。

owner 明示接受 selector miss 形成的存在性 oracle：adapter 可从投影后响应差异推知已登记字段是否存在，但仍不得获得命中值。不得用 miss 结果在核心内改变认证是否注入或是否发送请求；它只决定本响应中对应规则是否 Capture / Project / Commit。

### 2.6 对不配合 adapter 的边界

本层能强制保护的是 **已登记响应策略命中的值**：adapter 无法读取 Masker 前的响应，无法关闭规则，也无法把已收割值从核心读回。

本层不能从任意 body 中完备判断所有秘密。若 official adapter 作者故意不登记某个非标准凭证字段，坚持把它伪装成普通业务字段并从投影响应中自行正则提取，Broker 无法仅靠通用运行时识别其语义；这不是 selector 技术可以解决的问题。

selector miss 还扩大了一项明确接受的字段漂移残余风险：学校把已登记字段改名或新增未登记字段时，旧规则可能全部 miss，新字段会作为普通业务字段进入 adapter。该风险不靠运行时猜测字段语义消除，而由 official 审核、脱敏 fixture / observation 回放、同 bundle 更新及发现后的拒签或吊销承接。

该威胁由 official 供应链治理承接：

- 社区规范禁止 adapter 自行提取、保存、日志记录或注入凭证敏感值；
- scanner 检测 token/session/cookie、认证 header、跨请求值传递和高风险正则等候选模式，只作审查触发器，不作自动分类证明；
- 人工审查原始协议证据、脱敏 fixture、代码、响应策略和后续注入闭环；
- 离线签名者只签署完成闭环检查的 bundle；
- 发现绕过后拒签或吊销，不以 Masker 的存在替代人工责任。

换言之，签名门负责“分类是否诚实、完整”，Broker 负责“已签分类是否被不可绕过地执行”。两者共同组成边界，任何一方都不能替代另一方。

### 2.7 配置与 adapter 原子发布

响应策略放在独立且 mandatory 的 `masker.json`，与 `manifest.json`、adapter 代码一起进入 bundle digest 和 official 签名。`rules: []` 合法，表示该版本没有非标准响应凭证规则，但不能用缺少文件表达同一状态。选择独立文件是为了保持 capability manifest 聚焦能力声明，同时允许策略随学校接口热更新。

不保留“缺文件等价空规则”的旧 bundle 兼容。owner 确认现有 official adapter 数量有限，将在新 host gate 启用前手工补齐 `masker.json` 并重新签发；未迁移 bundle 由新 host 拒载，旧 host 则由最低 host/version gate 阻止采纳新 bundle。

运行时加载 official adapter 时，policy、delivery sink、Credential Store 或 host/version gate 任一缺失，adapter 均须拒载；空规则不放宽这些依赖。**P0-01 digest 路径绑定已于 2026-09-09 两端落地**（digest 覆盖 `path`/`size`/`sha256`、拒绝重复路径、blob 集合精确相等，签名已能证明被加载字节确属 `masker.json`）；**P1-04 已于 2026-09-12 落地**（§2.7.2）。**门禁本身已于 2026-09-12 接线**（§2.7.1 落地表），剩余前置只余**一次 `/3` 重签仪式**——在那之前入库 bootstrap 仍是 `/2`，新 host 拒载它，这正是断代的预期代价。

发布门必须验证：

- 每个 active credential observation 均闭合到 capture 规则、核心目标和投影测试；
- adapter 是否仍包含自行提取或传递同一敏感值的逻辑；
- 与上一 official 版本相比，规则删除、scope 放宽和目标生命周期变化均有显式人工复核；
- request URL、`network.allow`、credential scope、bind selector 或认证流程变化会触发响应策略复审；
- catalog 原子指向完整 bundle digest；
- 已确认泄漏或不兼容的旧版本通过 revocation / `minVersion` 禁止回退。

签名保证代码与策略不可被分开篡改；validator、policy diff 和人工签署清单保证“应有规则不能无声消失”。

#### 2.7.1 「最低 host/version gate」的实现形式 = `bundleFormat` 断代（2026-09-10 owner 决策；**2026-09-12 已落地**）

本节此前反复引用的「最低 host/version gate」一直**没有实现形式**，validator 因此挂着一条无条件阻断
`RM0_host_gate_unavailable`：只要 adapter 根存在 `masker.json`，即使策略本身合法也拒绝签发，理由是
「当前尚无旧 host 可理解的拒载字段」。

**digest v2 落地后该理由不再成立**——那个字段存在，它就是 `bundleFormat`，两端都做**严格相等**判定。
故 owner 裁定：**该 gate 不另行发明，就用 `bundleFormat` 断代表达**。

- **`masker.json` 转为强制的那一跳，`bundleFormat` 从 `elecon-bundle/2` 断代到 `elecon-bundle/3`**，
  与移除 `RM0_host_gate_unavailable`、接线 loader/runtime 门**同批落地，不得拆开**。
- 断代之后，任何不认识 `/3` 的 host（含**懂 v2 但不认 masker** 的 host）一律拒载，
  「旧 host 采纳新 bundle 却忽略 `masker.json`」在结构上不可能发生。
- **为何非断代不可**：`/2` 的严格相等只挡得住 v1 host，挡不住「懂 `/2`、但没有 masker 运行时门」的 host。
  这种 host 现在**一个都不存在**（v2 代码尚未发版），但第一次 v2 发版后就会存在——断代把这个
  **随时间关闭的窗口**换成一个**常量**，不必再靠排期保证安全。
- **代价**：一次格式断代。按 ADR-002 §2.3 / ADR-018 §2.9.1 第 8 项的同一论证（无外部持有者、
  不设双读、不新增兼容层），代价 = 一次重签仪式；且本项目仍处「前期可破坏性更新」阶段（红线 #6 放宽）。
- 契约改动（`bundleFormat` 是 ADR-018 §2.9.1 的签名覆盖字段），须在 [`contract/CHANGELOG.md`](../../contract/CHANGELOG.md)
  记一条，并同批更新 ADR-018 §2.9.1 与两端常量。

**落地（2026-09-12，同一批次，未拆开）**：

| 项 | 落点 |
|---|---|
| `bundleFormat` → `elecon-bundle/3` | `tools/src/bundle/envelope.ts`、`client/lib/core/loader/bundle.dart`、A 仓 `scripts/build-bundle.mjs`、`contract/golden/bundle/loader.json`（重生成） |
| 移除无条件阻断 | validator 的 `RM0_host_gate_unavailable` 退役；改为 **`RM0_policy_missing`**——official 缺根目录 `masker.json` 即 error（`rules: []` 合法，缺文件 ≠ 空规则） |
| 策略装配（② Policy 匹配） | 新 `masker-policy.ts` / `masker_policy.dart`：已验签 `masker.json` 的严格解析 + 按 (capability, method, 最终 URL, requestKey) 选规则；由 `contract/golden/broker/masker-policy.json` 双端钉死 |
| loader / runtime 门 | 客户端 `planLaunch` 从已验签 blob 读 `masker.json`（缺失 / 不可解析即拒载），`runLoadedAdapter` 再守落库 sink；服务端 `runImperativeAdapter` 对 official 缺装配报 `masker_policy_missing` |
| firewall 接线 | **客户端 `proxyFetch` 的交付出口由裸 `processResponse` 改为 `deliverThroughFirewall`**（此前只有服务端接了），imperative 与 declarative 两入口共用同一 choke point |
| P1-04 原始头基数 | 见下方「§2.7.2」 |

仍**不在**本次：actuator 入口接线（随 ADR-030 / P1-12）、handle 目标的 Commit 事务（P1-08）、
Credential Store 真实原子性 / generation swap（C2）。

**handle 目标的过渡门（2026-09-12 复核补记）**：handle 规则的**投影义务**（§3）在 P1-08 前没有
运行时执行方（dataflow `bind` 只提取、不投影）。为避免「签名策略被静默跳过」的 fail-open，两端
装配处（客户端 `planLaunch`、服务端 `runImperativeAdapter`）对含 handle 规则的策略**拒载**，
validator 以 **`RM17_handle_target_unsupported`（error）禁签**；`selectMaskerRules` 仍按契约
不把 handle 规则交给纯引擎。P1-08 落地后，本门与 RM17 同批解除（改为 bind 单次执行 + staged
handle + 投影响应）。

#### 2.7.2 响应头原始基数（P1-04）与两端能力差（2026-09-12）

`capture.exactly: 1` 要求「该头在响应里恰好出现一次」。但两端的 HTTP 栈都会在 Masker 读到之前
把同名头**折叠**成 `"a, b"`——于是「两个 token 头」与「一个含逗号的头」不可区分，把折叠值当单值
凭证收割就是在歧义上开口（checklist B4）。故基数改由**传输层证明**：

- `TransportResponse.repeatedHeaders`：折叠**前**记录的、出现 ≥2 次的头名；
- `TransportResponse.headerCardinalityAttested`：传输层**能否**证明基数。

判定分两层：纯引擎判「已知重复」→ `capture_ambiguous`；firewall 判「无从得知」→
`header_cardinality_unattested`。两者都 fail-closed，都不落库。

**两端能力差（已知、已记录）**：客户端 Dart `HttpHeaders.forEach` 逐名给出 `List<String>`，
**可证明**（`attested = true`）；服务端 WHATWG `fetch` 的 `Headers` 除 `getSetCookie()` 外没有原始
多值出口，**不可证明**（恒 `false`），故 header 源规则在服务端运行时一律 fail-closed。
这不是漂移而是**显式的能力声明**：两端对同一份 `repeatedHeaders` 的判定逐字一致，差的只是谁能
提供它。要让服务端也能跑 header 源规则，须换传输实现（ADR-003 范畴）或引入可读原始头的 HTTP
客户端（红线 #9），**届时另开 ADR**；在那之前服务端 runtime 只跑 json 源规则。

### 2.8 封闭 selector 与动作

策略只允许封闭、可跨端确定执行的 selector 和动作，不开放任意代码或自定义 replacement：

- header：大小写不敏感的固定头名，投影时删除整个头；
- JSON：受限 JSONPath，只命中标量；
- text/script：受限线性安全正则和固定 capture group；
- HTML：待真实案例和 Dart/TS probe 证明可控后再加入，不作为首期前置能力。

body 命中值使用核心固定 sentinel，建议为 `__ELECON_MASKED__`。body 改写后删除不再可信的 `Content-Length`、`Content-Encoding`、`ETag` 等实体元数据；具体字节、charset 和编码语义由共享 golden 钉死。

**实施决议（2026-07-31 owner 拍板，随纯引擎阶段落实）：**

- **A2 实体头清理触发条件**：只剥「因 body 改写而失真」的实体头（`Content-Length` / `Content-Encoding` / `ETag`），保留 `Content-Type`；**仅 header 删除、body 未改写时不 strip 任何实体头**。
- **A3 明文边界（写入本 ADR 与 Transport 接口）**：Masker **只在传输层解码之后的 UTF-8 明文 body 上运行，绝不猜测编码**。`Content-Encoding` 解压与字符集解码属传输层职责；**非法 / 非 UTF-8 body 在传输层→Broker 边界 fail-closed 拒交付**，不得把原始字节交给 Masker 或 adapter。
- **A4 sentinel 定值**：固定为 `__ELECON_MASKED__`（不再是「建议」）。
- **B1 JSON 定位（详文）**：body 投影用手写源码定位 + 按位剪接，**不**改树重序列化；跨端漂移靠共享 golden 限制。**重复键 fail-closed**；开发者结构诊断挂 ADR-024 **DEV** profile。完整决议见 [`response_masker_json_locator.md`](../reference/response_masker_json_locator.md)。

**实施决议（2026-08-05 owner 拍板，随 C1 firewall 接线落实）：**

- **Policy 匹配契约（§2.4 ② 步细化，就近修订本 ADR 而非新增 ADR；2026-09-12 校正为实现口径）**：
  `masker.json` 顶层为 `{schemaVersion, rules[]}`，**每条规则自带 `match` 块**（不是「顶层条目数组 + 每条的 rules」）。
  `match` 按下列封闭维度选出适用规则集，**全部为 AND**，`capability` / `method` / `urlScope` 必填，`requestKey` 可选：
  - `capability`：manifest 权威能力集内的 capability id；
  - `method`：`GET | POST`，比较时大写归一；
  - `urlScope`：与 `network.allow` 同形的 glob，对本响应的**最终跳 URL**匹配（须为 `network.allow` 子集，validator RM5）；
  - `requestKey`：declarative 逻辑请求 key；imperative `ctx.fetch` 无 key，带此维度的规则在 imperative 入口永不命中。

  匹配由 **Broker（firewall ② 步）** 解析裁定，**纯引擎 `applyResponseMasker` 只吃已选定的 `rules[]`**、绝不含 match 判定（保持引擎无 I/O、可跨端 golden）。命中的规则按策略序取并集后交引擎，规则内既有的数量 / 目标 / overlap 校验不变。match 维度、glob 语义与并集次序由共享 golden 跨端钉死（`contract/golden/broker/masker-policy.json`）；`match` 语法进 `masker.json` schema + validator（step 2 契约），受 host/version gate 约束。**首期只接 imperative 入口**（`fetch-proxy` 每次 `ctx.fetch` 已强制经 firewall，见 checklist C1）；客户端 declarative 入口已接入，actuator 入口的接线为后续人工主导步。**`handle` 目标规则不进纯引擎**（由 ADR-023 dataflow bind 承接）；**P1-08 落地前**两端装配处对含 handle 规则的策略 fail-closed 拒载（无投影执行方，见 §3），validator 以 `RM17` 禁签——不得静默跳过投影义务。

- **注入凭证回显 = 不做反射检测，交 Masker 承担**：Broker 注入的凭证若被 origin 回显进响应，**不**在 firewall 做「注入值 → 全 body 反射扫描剥离」（`stripEchoes` 式 blanket sweep）——短密文误报 + 大 body 成本，与 B1-a「不做运行期全 body sweep」同理。回显位置由 **adapter 作者显式声明 `redact` 规则**、经 Masker 投影兜底；发布前主捕获同样靠 D3 replay + D6 门 + 人审。**[ADR-023](./adr_023_declarative_dataflow.md) §2.5 已相应修订（2026-08-05）**：原「注入值回显必做剥离」推翻为「靠 Masker `redact` 声明式承接」，并新增残余风险 #3（作者漏声明 redact → 读回，接受）。**尚待（代码，人工主导）**：firewall ⑦ 的 `injectedValues` / `stripEchoes` blanket 剥离退役 —— 属红线 #1 承重代码移除，与其测试一并须人工审，暂保留不破坏现有 smoke。

- **A3 明文判定落地（§2.8 A3 的运行期实现）**：真实判定已接入传输层——`transport/direct.ts` 按 `Content-Type` charset（缺省 / `utf-8` / `ascii` 系）以 `fatal` UTF-8 解码验字节，非 UTF-8 charset 或非法字节 → `decodeOk=false`（**绝不猜测转码**），经 `TransportResponse.decodeOk` 传至 firewall ① 步，`false` 即 `body_not_plaintext` fail-closed。封堵旧「非 UTF-8 乱码仍交付」限制。跨端 Dart transport 镜像与 golden 为后续人工步。

### 2.9 空调操作示例

聚好联空调可作为命名 header credential 的小型闭环：

```text
假设登录/绑定响应中的非标准 token
  -> Masker capture 到 manifest 已声明的 aircon-session
  -> Credential Store 按 gxkt.juhaolian.cn scope 托管
  -> token 从交付响应删除
  -> adapter 只解析设备和状态业务字段
  -> climate.status 经只读 capability；climate.command 经专用 action 入口
  -> Broker 注入 x-access-token
```

若 ADR-029 被接受，对应 manifest credential 可声明为：

```json
"aircon-session": {
  "scope": ["https://gxkt.juhaolian.cn/*"],
  "type": "header",
  "headerName": "x-access-token"
}
```

Masker 规则只能把已匹配值提交到 `aircon-session`，不能在规则中重定义 header 名或扩大 scope。若 ADR-030 被接受，`climate.command` 仍受其中的用户手势、单次 mutation、禁重试和结果核验约束；Masker 不授予物理副作用能力。该流程只是候选小例子，不声称当前已验证聚好联实际从某个固定响应字段返回 token。

## 3. 与 ADR-023 的关系

ADR-023 负责 declarative capability 内 request-local 的提取、计算和静态注入；本 ADR 负责 declarative / imperative 共用的响应凭证分类、核心托管和 adapter-visible projection。

两者复用 selector、句柄类型、资源限额和注入 seam，但不合并为同一个 ADR：

- 需要跨请求但不持久化的普通值继续由 ADR-023 `bind` 提取。若该 bind 被人工分类为 credential-sensitive，`masker.json` 只引用既有 `bind[].var` 并增加投影义务；Broker 在 Capture 阶段执行该 bind **一次**，同时产出 staged handle 和投影响应，不复制 selector、不重复计量；
- 需要跨执行保存的值进入 Credential Store，不属于 ADR-023；
- imperative 响应同样必须投影，不属于 ADR-023 适用范围；
- ADR-023 产生敏感 bind 的源响应也必须投影，不能只剥离下游注入回显。

ADR-023 当前“中间值从不进 adapter”的叙述与源响应交付实现之间存在缺口。本 ADR 实施前必须由人工修订并测试该基础路径，不能把它留作隐含假设。

**C0 处置（2026-08-03）**：ADR-023 §4「从不进 adapter」已精确化——该保证严格成立于 broker 内部计算句柄与下游回显剥离；**credential-sensitive `bind` 的源响应须由本 ADR delivery firewall 投影后交付**，非 dataflow 执行器单独兑现（ADR-023 §4 精确边界 + §3 落地步骤 ⑦）。文档缺口已闭合；**「测试」部分随 C1 delivery firewall 接线落地**（firewall 交付事务须含「源响应投影后再交付」的 raw→delivered 用例），在 firewall 骨架标为 seam，接线时钉死。

## 4. 大重构与迁移决策

本 ADR 采用一次明确的能力迁移，不长期保留“adapter 自行取凭证”和“核心收割”两套正式路径：

1. 盘点所有 adapter、探针和 fixture 中从 header/body/URL 正则或 JSON 提取 token、session、code、openid、client id 等跨请求材料的逻辑。
2. 人工分类：普通业务数据、持久 credential、request-local handle、仅需 redact 的敏感值。
3. 为后三类建立 observation、`masker.json` 规则、核心目标和 raw-to-delivered replay。
4. 把后续请求改为 Broker credential injection 或 ADR-023 opaque handle injection。
5. 删除 adapter 对原值的读取、保存、正则匹配、日志和手工请求拼装。
6. 双端 Broker、validator、签名发布门和 scanner 全部就绪后，再迁移正式 adapter。
7. 全量迁移和人工签收完成后，发布门拒绝新增已知的 adapter-side credential extraction 模式；真实协议例外必须重新开安全评审，不得以兼容旧代码为由永久旁路。

迁移是大重构，但应按可审的小 PR 落地：先契约和纯函数，再统一 delivery firewall，再 Credential Store / handle 接线，再逐 adapter 迁移，最后启用发布闸门。任何阶段都不得由 AI 独自完成凭证路径安全签收。

## 5. 安全保证与残余风险

### 5.1 接受后的保证

- 已签名策略命中的凭证值只存在于可信核心；
- adapter 不能读取 Masker 前响应、关闭规则或解引用核心 handle；
- 已登记且命中的字段按策略收割和投影；命中规则失败不会降级为原 body 交付；
- adapter、策略与版本治理原子发布；
- 后续注入继续受 credential scope、静态汇聚点和 action policy 约束。

### 5.2 明示残余风险

- 人工审核、fixture 和 observation 可能同时漏掉一个实际凭证字段；
- 恶意或有缺陷的 official adapter 可能把未登记秘密伪装成业务字段自行解析；
- 学校可能新增尚未被人工分类的凭证载体；
- 字段改名可能令规则 miss，未登记的新字段因而进入 adapter；
- selector 是否命中会向 adapter 暴露有限的存在性 oracle；
- selector 或跨端实现缺陷可能导致 capability 拒绝服务；
- 签署者可能错误批准不完整策略。

前两类不能靠通用 Masker 完备消除，由社区规范、scanner、人工审查、签名责任和吊销治理缓解。本文不把 official 签名描述为数学证明，也不以无法完备识别未知秘密为由放弃对已知秘密的强制隔离。

## 6. 契约与实现范围

接受后预计至少涉及：

- `contract/response-masker.schema.json` 与共享 golden；
- mandatory `masker.json`（允许空 `rules`）的 capture target、selector、cardinality 和资源限额；
- tools validator、policy diff、scanner 与 fixture observation 闭环；
- adapter bundle include、digest、验签后加载和旧版本吊销；
- Dart / TS 对称 Capture / Project 纯函数；
- Broker 统一且不可绕过的 delivery firewall；
- Credential Store 事务提交与 ADR-023 opaque handle 接线；
- raw Transport -> Broker -> adapter replay；
- adapter 全量迁移与发布安全清单。

旧客户端遇到要求 Masker 的 bundle 时必须经 host/version gate 拒载，不能忽略 `masker.json` 后继续运行。official adapter 即使无规则也必须携带 `masker.json`；policy / sink / store / host gate 任一缺失均拒载。**loader 接线已于 2026-09-12 完成**（§2.7.1 落地表，含 P1-04 §2.7.2）；「最低 host/version gate」的实现形式 = `bundleFormat` 断代到 `elecon-bundle/3`。**剩余唯一前置是一次 `/3` 重签仪式**（YubiKey，owner）。

## 7. 实施阶段必须落实

1. ~~mandatory `masker.json` schema（空 `rules` 合法）与 bundle 最低 host/version gate~~ —— **2026-09-12 已落地**：`bundleFormat` 从 `elecon-bundle/2` 断代到 `/3`（§2.7.1），与移除 `RM0_host_gate_unavailable`（改为 `RM0_policy_missing`）、两端 loader/runtime/firewall 接线同批。**余一次重签仪式**。
2. `credential` capture 的覆盖、过期、撤销、来源和原子提交语义。
3. `handle` 与 ADR-023 bind 的统一或映射方式，及源响应投影修订。
4. selector miss / mixed / all-miss、类型不匹配、多次命中、非法 body、字符编码和实体头清理语义。
5. `redact` 与其他目标使用同一 miss 语义，不增加 optional / required 字段。
6. policy diff、规则删除 waiver、release ledger 和旧版本吊销流程。
7. adapter-side credential extraction scanner 的告警规则与人工处置标准。
8. 首批迁移清单及至少一个脱敏真实案例；空调可以作为命名 header 注入的小例子，但不得使用真实 token、IMEI 或学生数据。

## 8. 决策结果

**Accepted（2026-07-30；2026-08-07 owner 补充决策）。** Response Masker 是 Broker 的响应凭证收割与投影层，不是 fail-open 的附加字符串过滤器。selector 缺失按 §2.5 作为 rule miss，其他错误仍 fail-closed；实现按 §4 的大重构迁移，并在各阶段落实 §7 的工程与治理要求。不保留 adapter 自行读取已分类凭证的长期兼容路径，也不因本次契约与纯引擎落地声称关闭任何 loader / 运行时 P0。
