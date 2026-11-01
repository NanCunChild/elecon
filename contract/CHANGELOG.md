# `contract/` 变更流水

## 2026-11-01 · ADR-048

`schedule.week` 新增显式 1.1：可选学校时间分段 `timeSegments` 与逐周七日课程数量 `weekPreviews`。保留 1.0 schema 快照和精确版本校验，旧包继续可用；新脚本声明 1.1，旧宿主拒绝未知版本。SDK 导出生成类型，包准入接受两种版本；V1 校验只接受 registry 明确列出的历史版本并按相应 schema 验证，未放开未知版本。

## 2026-11-01 · ADR-050

新增 `faculty.search` / `elecon.faculty.search` 1.0 及显式查询参数：姓名关键词、研究方向与有界分页，返回学校范围内教师 ID、公开简介及主页链接，保留来源和分页信息。同名教师不合并；不复用个人资料或通知契约，不预加载、不抓取全站。旧宿主拒绝未知 schema；学校包更新须重新确认新增官网网络范围与 digest。

## 2026-11-01 · ADR-047

新增 `card.qr` / `elecon.card.qr` 1.0：短时 PNG 图片、取得与停止显示时刻、可选用途；禁止 home 预加载/缓存。校园卡建议可由余额、流水或二维码独立提供。旧余额契约不变，二维码学校不伪造消费数据；旧宿主拒绝未知 schema。

- **2026-11-01 · 服务账号、消息窗口、扫码签到与 SDK 9（ADR-052）**
  - 新增 `forum.session`、`messages.session`、`messages.list`、`attendance.checkin` 及参数 schema，均 1.0；registry/TS/Dart/输出 validator 同步。前台执行，禁止 home/preload/持久缓存；不重解释 notice 或 attendance.summary。
  - SDK 9 `websocketOrigins` 与 `ctx.websocket`：精确 wss origin、固定 DNS/TLS、二进制有界窗口、无重定向/压缩/自动重连。与 HTTP 权限分别授权，旧 SDK 不变，旧宿主拒绝 SDK 9。
  - 基本包升至 0.18.0、增强包 0.1.0；新增来源需重新确认 digest。动态 Tab 只读可执行 provider。真实账号、协议在线兼容及人工安全签收未完成。

- **2026-11-01 · ADR-046（所有者废除 action 授权）**：移除新包 `manifest.actions` 与 SDK action 声明；Dart/TS 新包解析明确拒绝旧字段，已有安装仅保留原始内容/digest 并等待显式更新。普通 capability 使用通用 `ctx.fetch`，空调按钮触发一次控制后查询一次状态；不额外确认或自动重发。包格式及 SDK 其它 API 不变，西电本科包升至 0.15.0。V1 控制门不变。


- **2026-11-01 · ADR-045（所有者扫码接口授权）**：SDK 8 新增可选 `manifest.scanner` 与前台 `ctx.ui.scanQRCode()`，返回最多 4096 UTF-8 字节的 QR 文本或取消 null；受 digest、当前 Profile/学校、前台与调用预算约束。SDK 1–7 不接受 scanner 字段，旧宿主拒绝 SDK 8；SDK 8 继承原 homeTitle/home/actions/cards。未新增签到业务 capability 或绕过控制确认。

- **2026-11-01 · ADR-043 §2.2（所有者视觉修订要求）**：SDK 7 新增可选静态 `homeTitle`，允许受信学校包声明首页单行标题，名称缺省回退学校名；保留 package `name`、SDK 1–6 字段含义和现有能力权限。更新须重新确认 digest。标题不声明布局、数据时间或控制行为。

- **2026-10-31 · ADR-043（所有者确认落地）**：新增 SDK 6 可选 `cards` 静态展示建议，有限业务类型与 `defaultVariant`，按类型验证能力依赖、重复类型和已实现的呈现档位；用户布局优先，宿主拥有渲染。继承 SDK 5 action 与 SDK 4 home，不增加权限、业务输出或远程布局代码，旧 SDK 1–5 保持原行为；实际学校包不随之自动升级。

- **2026-10-31 · ADR-040（所有者已确认规格）**：新增 energy.meters、climate.devices/status/command；energy.usage 1.1 增加表标识、前次读数与抄表时刻，保留 1.0 输出校验；SDK 5 新增独立 action 声明。实现人工安全审阅与真机验收另行记录。

> **这是什么**：`contract/`（schema、`capability/registry.json`、`manifest.schema.json`）每一次新增或变更的 dated 记录。
> **权威关系**：**决策**的权威在 ADR 正文（治理规则见 [`adr_001_contract.md`](../docs/adr/adr_001_contract.md) §8）；**落地与安全签收**的权威在 [`docs/adr/README.md`](../docs/adr/README.md) 索引表。本文件只记「契约事实上被改成了什么、依据哪条 ADR」。
> **红线 #6 如何不被弱化**：每条记录**必须引用一个 ADR 编号**——记录的存在即证明该变更「先有 ADR」。无 ADR 引用的条目视为违规。
> **与 `docs/archive/` 的区别**：`docs/archive/` 存**已被取代、不再维护的历史快照**（只读）；本文件是**活的时序流水**，是当前契约版本号的解释来源（例如「为什么 registry 里 `notice.list` 是 1.1」）。
>
> 排序：**新的在上**。本文件的前三条于 2026-09-08 自 ADR-001 §8.1 原样迁入，内容未改，仅补记人工复核结论。

---

- **2026-10-30 · 首页缓存与登录收尾 SDK 4（ADR-038 / ADR-039）**
  - `elecon-script/1` 新增 SDK 4：manifest 可选 `home` 项声明能力、TTL、默认参数与预加载；宿主只缓存通过标准 schema 的成功输出，按学校/脚本/digest/参数隔离并记录真实 fetchedAt，复用已选择的 H/S/M 存储。
  - SDK 4 `browser.setBusy(boolean)` 控制固定宿主“正在登录”遮罩，保留取消；SDK 1/2/3 不获得此方法，旧宿主拒绝 SDK 4。后台刷新禁止交互表单/浏览器，不增加权限或业务输出字段。
  - 西电源码 0.13.0 / SDK 4，客户端 0.4.0+7；源码升级重新确认 digest。接入已存在的 `notice.detail`，不新增标准 capability/schema。

- **2026-10-30 · 可选卡号与脚本输入 SDK 3（ADR-036 / ADR-037）**
  - 所有者确认学校未提供卡号时不强制手填：`card.balance` / `card.transactions` 移除 cardNumber required，有值仍须为非空真实卡号。预公测按 ADR-001 §8 显式更正 1.0；生成 Dart/TS、客户端校验/解码/固定卡片同批更新，金额/流水要求不变。
  - `elecon-script/1` 支持 SDK 3，继承 SDK 2 完整凭据寻址，新增 `ctx.ui.requestInput` 固定表单（text/password/select）。用户取消返回 null，输入不自动保存/变更参数或重跑；宿主校验大小/结果、计数/并发/取消并净化输入日志。旧 SDK 1/2 不获得新 API，未知 SDK 拒绝。
  - 新客户端 0.3.0+6 配套西电源码 0.12.0/SDK 3；旧源码与 V1 签名包字节不变。移除首页按卡号/学号错误码猜测表单的补丁；校本脚本决定何时索要学号，无卡号余额/流水不索要输入。

- **2026-10-30 · 西电日期流水的来源说明校正（ADR-034 §3–§4 / ADR-035）**
  - `params.card.transactions.schema.json` 仅修改过期的 `$comment`：新西电脚本按参考源码使用日期窗口 JSON 接口与本地分页，不能再写“西电不支持 from/to / adapter 可忽略”。字段、format、capability/schema 版本与验证行为均不变。
  - 学校源码及长字符串桥接修复使用现有 SDK 2 能力，没有新增标准 capability、schema 字段或脚本权限；卡号必填与其它业务缺口单列评估，没有伪造来源或静默放宽契约。

- **2026-10-29 · 脚本 SDK 2 与凭据完整地址（ADR-035 §2–§4）**
  - 包容器仍为 `elecon-script/1`；schema 明确支持 SDK 1/2，未知 SDK 拒绝。SDK 1 预览包保留原查找语义，新模板使用 SDK 2，迁移需同时提升脚本 version 并重新确认。
  - SDK 新增凭据 id/namespace/key 描述符，SDK 2 默认 namespace 为稳定脚本 id，可显式共享及访问 `@legacy`/`@preview1`；同校访问权限不变。
  - 凭据更新省略元数据时保留原值，expiresAt:null 显式清空；浏览器 Cookie 增加 SameSite 往返。异常结束同样等待已完成写入的保存，不回滚远端轮换。

- **2026-10-29 · 新受信源码脚本包 `elecon-script/1`（ADR-034 §2–§6）**
  - 新增 `script-package.schema.json`：源码包、SDK 版本、严格三段版本、域名 origin 与可选 IP/CIDR、页面权限、标准 capability/schema 对应关系；源码包仍须通过宿主的 1 MiB UTF-8 与 IP 语义校验。
  - 新增 `script-sdk/types.d.ts`：实际凭据 get/set/delete/list、显式 HTTP/多值 Set-Cookie、异步 DOM API。新路径不使用 V1 requestGraph/句柄/Masker，不改变 V1 契约。
  - 内容 digest 与显式安装授权、版本更新及身份范围遵循 ADR-034；新增静态 schema smoke 与真实客户端 QuickJS 回归，不以服务端执行新脚本。

- **2026-09-12 · masker 复核补丁：handle 过渡门 + `requestKey: null` 双端对齐 + validator RM17/RM18（ADR-026 §2.8/§2.7.1/§3）**
  - **改动**：`contract/golden/broker/masker-policy.json` 新增 parse 向量 `match_request_key_null_rejected`
    （显式 `null` ≠ 缺省，双端一致 fail-closed）。`response-masker.schema.json` 本身**未改**——schema 一直
    把 `requestKey` 定为 string，本次只是让 Dart 运行时解析器与 TS/schema 对齐。
  - **为何**：复核发现 Dart 解析器把 `requestKey: null` 当缺省接受（与 TS 分叉）；且 handle 目标规则在
    P1-08 前被运行时静默跳过（投影义务无执行方），属 fail-open。
  - **同批落地**：两端装配处对含 handle 规则的策略拒载（客户端 `planLaunch`、服务端 `runImperativeAdapter`
    → `masker_handle_unsupported`）；validator `RM17_handle_target_unsupported`（error）禁签、
    `RM18_header_source_server_unattested`（warn，服务端 header 源规则不可执行）；ADR-026 §2.8 文本
    校正为 `capability/method/urlScope` + 可选 `requestKey` 的实现口径。
  - **依据**：ADR-026 §2.8 / §2.7.1 / §3。🔒 触红线 #6；handle 过渡门随 P1-08 同批解除。

- **2026-09-12 · `bundleFormat` 断代 `elecon-bundle/2` → `/3`，`masker.json` 转为 official 强制（ADR-026 §2.7.1）**
  - **改动**：`contract/golden/bundle/loader.json` 重生成（`bundleFormat` = `elecon-bundle/3`，含真实 Ed25519 测试签名）；
    `contract/golden/broker/response-masker.json` 新增 3 例 P1-04 原始头基数向量；**新增**
    `contract/golden/broker/masker-policy.json`（`masker.json` 严格解析 26 例 + firewall ② 步选规则 11 例，两端双跑）。
    `response-masker.schema.json` 本身**未改**——断代表达的是「必须有这份文件」，不是「文件形状变了」。
  - **为何**：ADR-026 §2.7 要求 official bundle 必带 `masker.json` 且 host 加载时接入 delivery firewall；
    在此之前 validator 挂着无条件阻断 `RM0_host_gate_unavailable`，理由是「没有旧 host 可理解的拒载字段」。
    digest v2 落地后那个字段存在——就是 `bundleFormat`，两端严格相等。断代把「懂 `/2` 但没有 Masker
    运行时门的 host 会忽略 masker.json」这个**随时间关闭的窗口**换成一个常量。
  - **同批落地**：validator `RM0_host_gate_unavailable` 退役 → `RM0_policy_missing`（official 缺文件即 error，
    `rules: []` 合法）；两端新增 `masker-policy.ts` / `masker_policy.dart`；**客户端 `proxyFetch` 交付出口
    由裸 `processResponse` 改接 `deliverThroughFirewall`**；`planLaunch` 从已验签 blob 读取并解析 `masker.json`
    （缺失即拒载）；P1-04 响应头原始基数经传输层证明（ADR-026 §2.7.2，服务端 WHATWG fetch 不可证明 →
    header 源规则 fail-closed）。A 仓 5 份 adapter 补空规则 `masker.json` 并 bump 版本。
  - **依据**：ADR-026 §2.7.1（2026-09-10 owner 决策）、§2.7.2（P1-04）；ADR-018 §2.9.1 签名覆盖字段。
    🔒 触红线 #4/#6；破坏性 = 一次重签仪式（无外部持有者，不设双读，红线 #6 前期放宽）。
  - **仪式前的已知红**：入库 bootstrap 仍是 `/2`，故 `npm run bootstrap:verify -w tools` 在 `/3` 仪式完成前
    **必然失败**——这是断代的预期代价，也是「不忘记仪式」的硬门。客户端 `school_manifest_test` 改为
    显式 skip（它测的是已解析 manifest 与 policy 一致，不可解析的产物没有可测对象），不重复同一信号。

- **2026-09-12 · `catalog.schema.json`：entry `url` 删除（ADR-018 §2.5.1 第二步）**
  - **改动**：`entries[].url` 从 schema 移除；`additionalProperties:false` 下再出现即 K0 拒绝。
  - **为何现在**：2026-09-11 条目预告「下一次仪式后删除」。seq 9 仪式已于 2026-09-12 签出不含 `url` 的 catalog 并入库
    （整改清单 §2.10），入库产物已无任何携带 `url` 的已签 catalog，暂留可选的唯一理由消失。
  - **同批落地**：`client/lib/core/loader/catalog.dart` 容忍集去 `url`（再见到按未知字段 fail-closed，测试改为拒绝用例）；
    `tools/src/catalog/validate.ts` K3 退役（smoke 6b 改为 K0 拒）。A 仓 vendor 由 `mirror-adapters.yml` 自动跟随。
  - **依据**：ADR-018 §2.5.1（2026-09-11 修订，实现 owner 2026-09-12 签收）。🔒 触红线 #6 契约；删字段是收紧而非放宽。

- **2026-09-11 · `catalog.schema.json`：entry `url` 弃用（从 required 移除），catalog 只描述文件、不描述端点（ADR-018 §2.5.1）**
  - **改动**：`entries[].url` 从 `required` 移除并标记弃用（description 注明）；`additionalProperties:false` 不变，字段暂留为可选。
    顶层与 `entries` / `digest` 的 description 改写为「以 digest 内容寻址，路径恒为 `bundles/<digest>.json.gz`、相对客户端自持 base」。
  - **为何**：`url` 在签名字节里，把端点域名绑进了 catalog——换域名/上镜像/指向本地端点都要重签，而字节来源本不参与信任裁定
    （digest 重算 + Ed25519 验签才是锚）。ADR-018 §2.5.1 决定 catalog 不再描述端点，base URL 由客户端自持。
  - **为何暂留可选而非直接删除**：线上/bootstrap 的 catalog（sequence 8）已签且含 `url`；删字段会令其不合 schema，只为此重签不值一次
    YubiKey 仪式。留可选 = 旧 catalog 仍合法、新 catalog 不再写入。**下一次仪式（已预定 masker `/3` 断代，catalog ≥ 9）后删除**。
  - **同批落地**：`tools/src/catalog/validate.ts`（`url?` + K3 弃用 warn）、`tools/src/release/package.ts`（不写 url、移除 `--base-url`）、
    catalog golden 重生成（entries 无 url）、`client/lib/core/loader/catalog.dart`（解析时忽略 url）、`loader.dart` / `distribution_http.dart`
    （`fetchBundle(digest)`，按 digest 拼路径 + 形态门）、`adapter_service.dart`（自持 base + DEV `ELECON_DISTRIBUTION_BASE_URL` 覆盖）。
    tools smoke 19/19、client `flutter test` DEPLOY 859 / DEV 868 通过。
  - **依据**：ADR-018 §2.5.1（2026-09-11 修订）。🔒 触红线 #4 加载路径与 #6 契约，实现须人工复核签收。

- **2026-09-09 · `elecon.gpa.summary` 1.0 → 1.1：绩点尺度 + 全字段 description（ADR-001 §3.5 优先级规则）**
  - **改动**：
    1. `elecon.gpa.summary` 新增可选 `gradePointScale`（枚举同 `elecon.grades.list`）——**官方 GPA 此前没有量纲**：只有一个 `gpa: number`，UI 无从判断 3.71 是 4.0 制还是 5.0 制的。
    2. 该 schema 原本除 `updatedAt` 外**全部字段无 description**，本次补齐 8 处（顺带削减 description gate 的 367 处欠账）。
    3. `elecon.grades.list` 的 `gradePointScale` description 改写（内容语义不变，见下）。
    4. registry 级联 `gpa.summary` 的 `emits.schemaVersion` → `1.1`；codegen Dart/TS 重跑；schema golden 增 `gradePointScale` 正例与 enum 负例。
  - **为何**：ADR-001 §3.5 此前只写了一句「`gpa.summary` 存在时优先」，没有说清**为什么有两个 GPA**、以及两者同时可见时怎么办。本次把它展开为显式规则：**学校官方 GPA（`gpa.summary`，adapter 只读不算）** 与 **交互式聚合 GPA（本体按当前筛选算）** 是两个数、两个所有者、互不替代；官方数存在即权威，本体不得覆盖；两者同现必须用**不同标签**。既然官方数要独立展示，它就必须自带量纲——故补 `gradePointScale`。
  - **为何是 MINOR**：仅新增一个可选字段 + 补 description，不删字段、不改既有类型、不收紧约束；旧 1.0 数据在 1.1 下仍合法。
  - **description 改写（`grades.list.gradePointScale`，非结构变更）**：补三条此前隐含未言明的约束——① 该字段**只界定量纲、不保证跨校可比**（同称 4.0 制的两校换算表可能完全不同），故不得据此做跨校排名；② `other`（知道制式但不在枚举内）与 `unknown`（无法判断）**信号不同**，前者提示扩枚举、后者提示 adapter 待改进；③ 数据横跨学校改制时**不得任选其一**，应声明 `other` 让本体降级。
  - **消费方新增义务（本体侧）**：`gpa.summary` 可用即作为权威展示；本体自算值只在「无官方数」或「用户施加了筛选」时出现，且**必须换标签**（绝不允许两个不同的数都叫 GPA）。两路都对 `gradePointScale` fail-closed。官方数的尺度取自 `gpa.summary` 自身，**不得借用** `grades.list` 的——两者可能覆盖不同范围。
  - **依据**：ADR-001 §3.5（2026-09-09 修订，新增优先级规则表）。
  - **本仓内已同批完成**：schema、registry、codegen、schema golden 正负例、客户端（`GpaSummary` 解码 / `CampusSnapshot.gpaSummary` / `GradesCard` 官方优先 + 本机聚合改标签「均绩 … 本机计算」/ `GradesSection` 取 `gpa.summary` 作可选增强，失败不影响成绩单）、3 个新增 widget 测试锁死优先级与 fail-closed。
  - **未同批（外部仓）**：`elecon-adapters` 目前**无任何 adapter 声明 `gpa.summary`**，故本次无阻塞性外部联动。将来实现该能力的 adapter 须直接按 `1.1` 声明并给出 `gradePointScale`。

- **2026-09-08 · `elecon.grades.list` 1.0 → 1.1：绩点尺度与派生来源（ADR-001 §3.5 修订）**
  - **改动**：
    1. 列表级新增可选 `gradePointScale`（枚举 `4.0` / `4.3` / `4.5` / `5.0` / `other` / `unknown`）——声明本次成绩里 `gradePoint` 所用的**校本计分尺度**。
    2. item 级新增可选 `gradePointSource`（枚举 `source` / `adapter-derived` / `unknown`）——区分该绩点是**学校来源直接给出**还是**adapter 按校本换算规则派生**。
    3. `gradePoint` 字段 description 相应改写（不再断言「学校来源直接提供」）。
    4. registry 级联 `grades.list` 的 `emits.schemaVersion` → `1.1`；`adapters/_template/{declarative,imperative}` manifest 同步；codegen Dart/TS 重跑。
  - **为何**：ADR-001 §3.5 原文在同一段里先给判据「校本特有的派生 → adapter；跨校统一的派生 → 本体」，又把 `gradePoint` 判给 UI 计算——**自相矛盾**。分数→绩点的换算表是校本的（各校甚至各院系不同，尺度有 4.0/4.3/4.5/5.0），按判据属 adapter。矛盾的根源是一个词承担了两件事：**课程级 `gradePoint`（校本换算）归 adapter**，**GPA 聚合（加权平均/排序/跨学期对比）归本体**。本次改动把这一拆分落到契约上：adapter 派生不再是「擅自推算」的禁止项，而是**可声明、可审计**的交付物。
  - **为何是 MINOR**：仅新增两个可选字段 + 改写一处 description，不删字段、不改既有类型、不收紧约束；旧 1.0 数据在 1.1 下仍合法。
  - **消费方新增义务（本体侧）**：`gpa.summary` 存在时优先采用学校侧汇总；否则本体自行计算，且**当 `gradePointScale` 缺失、为 `unknown`/`other`，或跨数据源尺度不一致时不得展示 GPA**（fail-closed，而非展示一个尺度不明的数）。
  - **依据**：ADR-001（2026-09-08 修订，§3.5 判据改写 + §8 治理规则）。
  - **联动升级文档**（§8 要求）：[`docs/reference/gradepoint_ownership_landing.md`](../docs/reference/gradepoint_ownership_landing.md) —— 含业务动机、预期结果、逐项外层联动清单与验证结果。
  - **本仓内已同批完成**：schema、registry、codegen、`adapters/_template` 两套（manifest + index.js + fixtures）、客户端 GPA fail-closed 与解码、schema golden 正负例、客户端回归。
  - **未同批（外部仓，见联动文档 §4.1）**：`elecon-adapters` 的 `school-xidian` / `school-thu` manifest 仍写 `elecon.grades.list@1.0`，须同步 `1.1`，否则 `C2_emits_mismatch` 拒签发、运行时查不到 validator 而 fail-closed。

- **2026-07-22 · `classroom.available` 1.0 → 1.1 + 新增 `classroom.buildings`（ADR-019）**
  - **改动**：
    1. **`elecon.params.classroom.available` / `elecon.classroom.available` → 1.1**：双时间轴（`date`/`week`/`term`/`weekday` + 节次 `sectionStart`/`sectionEnd` + 墙钟 `start`/`end`）；楼/室过滤 `building`/`buildingId`/`room`/`roomId`；`onlyAvailable`；emits 增 `sections[]`（`maxItems:24`）、`status` 枚举追加 `partial`、`timeZone`（IANA，adapter 声明）、`floor` 等。`items[].building`+`room` 仍 required 且 `minLength:1`，未知填 `"-"`。
    2. **新增伴生 capability `classroom.buildings@1.0`**（discovery）：params 可选 `campus`/`term`；emits `items[]` required `building`。
    3. registry 级联 `schemaVersion`；codegen Dart/TS 同步。
  - **为何是 MINOR**：仅新增可选字段 + 枚举扩展（放宽消费方须按 ADR-001 §3.4 对未知枚举兜底 `unknown`）+ 新 capability；不删字段、不改既有类型；旧 1.0 数据在 1.1 下仍合法。
  - **依据**：[ADR-019](../docs/adr/adr_019_classroom_available.md)（2026-07-22 Accepted）。
- **2026-06-16 · `elecon.notice.list` 1.0 → 1.1**（依据 ADR-001；**人工复核完成 2026-08-22 · owner NanCunChild**）
  - **改动**：`publishedAt` 由 `required` 移出，成为可选字段（schema 内容不变，仅放宽必填约束）。级联 `capability/registry.json` 与 emit 它的 manifest（school-xidian / school-xjt）的 `emits.schemaVersion` 同步至 `1.1`。
  - **为何是 MINOR 而非 MAJOR**：ADR-001 §8 把"收紧约束"列为破坏性，本改动是其**反向（放宽）**。ADR-001 §3.4「缺失语义」本就要求消费方普遍处理"字段缺失 = 该校不提供"，故把 `publishedAt` 改为可选**不超出消费方既有义务**，旧数据（含 `publishedAt`）在 1.1 下仍合法 → 向后兼容，记 MINOR。
  - **本次遇到的情况**：首个 imperative adapter（school-xjt 教务通知）逆向中，源站通知日期偶为不可解析格式；旧 `normalizeDate` 不可解析时回退空串 `""`，而 `""` 不是合法 `date-time`，会被 ajv 拒。改为不可解析时**省略 `publishedAt`**（语义 = 该条目未提供可信日期），与 ADR-001 §3.4 一致。
  - **是否可能引入未知问题（风险）**：
    1. **消费方（UI/SDUI）**：若某处实现假设 `publishedAt` 必存（如直接排序/格式化），缺失时可能报错或排序错位。缓解：UI 须遵 ADR-001 §3.4 处理缺失；按时间排序时对无日期项定义稳定兜底位次。
    2. **新旧版本并存**：1.0 与 1.1 同时在网（不同 adapter/缓存）时，宿主以 envelope `schemaVersion` 解读；1.1 消费方需容忍缺省，1.0 数据天然满足。
    3. **一致性外溢**：其他域 schema 可能存在同类"过紧 required"（如把可能缺失的字段标必填），本次只动 notice.list，未做全面审计——留作后续核对，不在本改动范围。
    4. **校验盲区**：`tools/` 校验器目前不对 params schema 做加载校验，emits 版本一致性（C2）已覆盖本次级联；fixtures 仍含 `publishedAt`，1.1 下照常通过。

- **2026-06-16 · 新增 `elecon.card.transactions` emits schema + 5 个 `params.*` 草案 schema（补 registry 悬空引用）**（依据 ADR-001；**人工复核完成 2026-08-22 · owner NanCunChild**）
  - **改动**：补齐 `capability/registry.json` 早已声明却**无定义文件**的 schema——
    1. **`elecon.card.transactions@1.0`（emits，稳定面）**：money 模型镜像 `card.balance`（`amountMinor` + `currency`），增 `direction`（debit/credit）区分收支；`amountMinor` 加 `minimum:0`（交易额恒非负，收支由 `direction` 表达，区别于 `card.balance` 可为负的余额，已在 schema `$comment` 注明）。
    2. **5 个 `params.*` 草案 schema**：`grades.list` / `schedule.week` / `card.transactions` / `notice.list` / `generic.section`，消除 registry 悬空 `params` 引用。均带 `$comment: 草案`。
  - **范围**：仅新增 `contract/schema/` 文件；未改 `registry.json`、未新增/改 capability id、未改任何既有 schema 语义。registry 的 `$schema` 错误指向已拆至 #48 单独修复。
  - **草案（draft）状态约定**：上述 5 个 `params.*` 在经本 ADR **正式确认（"转正"）前不属稳定契约面**——adapter / UI 不得将其当稳定依赖。**草案期内其形状可自由调整（增删字段、改约束）而不触发 ADR-001 §8 的 MAJOR/MINOR 版本治理**；版本治理仅自该 schema 转正后生效。此约定为契约早期高频迭代（按真实接口反复校准）留出空间，同时不削弱红线 #6——草案明标、不被依赖、转正须在本文件补记。
  - **待人工确认的设计点（草案期跟进，非阻塞本次补齐）**：
    1. `params.schedule.week.week` 设为 `required` 是否需核心侧配套「当前教学周」能力（否则消费方无从得知传第几周）；
     2. `params.card.transactions` 的 `from`/`to` 与 `page`/`size`：已知学校（XIDIAN）流水接口仅支持分页（`pageNo`/`pageSize`）、不支持日期范围，故 `from`/`to` 设可选以适配跨校差异，由 adapter 归一化映射。

