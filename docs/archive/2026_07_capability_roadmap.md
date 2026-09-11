# 能力接入路线图（2026-07-27 快照）

> **归档（2026-09-11）**：本文是 2026-07-27 的能力接入路线图快照（其「状态漂移」一节已全部过时：bootstrap / dist / 外部仓现已统一为 sequence 8 · xidian 0.4.1），已停止维护、**不是权威**。当前决策看 `docs/adr/`，
> 执行与签收状态看 [`docs/planning/2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md)。
> 文内提到的版本号、序号与「仍待做」项以那两处为准。


> 本文源自一次只读评估；2026-07-29 已按最新实现更新状态，用于统一「一卡通 OpenID / 图书馆 / 物联网空调 / validator C8」几条线的推进顺序与前置条件。
> 它**不是** ADR，不裁定架构；涉及契约或核心的每一步仍以对应 ADR 为准。文中判断以评估当日代码为准，实现推进时请重新核对。

## 1. 总体判断

项目目前处于基础设施型 Alpha / 0.1 阶段：

- Adapter 契约、QuickJS 双端运行时、Broker、凭证存储、WebView 登录、签名分发、吊销、bootstrap 等基础链路已基本成形。
- Xidian 公开通知已产品闭环；课表、成绩、考试、空教室已有 adapter 与 fixture/smoke，但缺完整 UI、真实账号持续验收和最新版正式签名发布。
- 尚不能称为完整校园聚合产品：正式首页仍主要只消费 `notice.list`（见 `client/lib/ui/home/campus_snapshot_loader.dart`）。
- 私密数据仍只能客户端直连；`server/src/campus` 目前是 501 stub，不能依赖校内中继。
- Android 路径最成熟；iOS 首版按 ADR-010 仍是 declarative-only，imperative 能力上线前需重做 App Store 合规评估（见 `docs/adr/adr_010_ios_appstore.md`）。

需要留意的状态漂移：

- `README.md` 已更新到当前基础设施状态；后续以本路线图和各 ADR 的状态字段为准。
- 核心已改为通过 `adapters.pin` 按 commit 拉取独立 `elecon-adapters` 仓库，不再使用子模块。
- bootstrap 仍是已签名 Xidian 0.3.0，`dist-full` 是 0.3.1，外部仓开发态已进入 0.4.0；待人工打包发版后统一。

## 2. 当前能力盘点

| 能力 | 现在能否开始接入 | 现在能否称为可用 |
|---|---|---|
| 西电一卡通 OpenID | 已进入 adapter + fake transport smoke | 真机字段校准和正式签名发布前不宣称可用 |
| 图书馆只读借阅 | 可以 | 不可以，Xidian 认证与 body 注入未闭环 |
| 完整图书馆（含写操作） | 可规划 | 不可以，需新增 mutation 契约与 ADR |
| 物联网空调控制 | 探针已定位；ADR-029/030 已接受 | 不可直接上线，命名 Header 待人工安全签收，Body 注入和副作用执行闸门仍未闭环 |
| 更智能的 imperative 凭证引用 | 可以 | 需拆成 validator bugfix + 独立 ADR 两步 |

## 3. 一卡通 OpenID（ADR-020）

已确认的对象是西电一卡通 URL query 中的 `openid`。ADR-020 已完整裁定（见 `docs/adr/adr_020_url_query_credential.md`）：

- `openid` 是可重放凭证，不是普通业务参数。
- 只允许可信核心收割、保存和注入；adapter 不得读取或自行拼接。
- Manifest 声明 `type: "query"` 与 `queryParam: "openid"`。
- Broker 在每次请求和重定向中处理注入、收割与 URL 脱敏。

落地清单（本轮 PR 已覆盖大部分）：Manifest schema 增 `query` 枚举 + `queryParam`；validator Q1–Q3；Dart/TS Broker 的 query harvest/inject；Xidian `card-session` 由临时 cookie 改为 query。

**结论**：可直接进入实现，无需再开 ADR；但在真机验收前不宣称一卡通 OpenID 已接通。该实现触碰契约与凭证核心，必须人工主导安全审查，不能只改 adapter。

## 4. 完整图书馆

现有契约已覆盖 `library.loans` / `library.seats` / `library.booking`（见 `contract/capability/registry.json`）。只读借阅 schema 已含到期时间、续借次数、逾期与费用等字段，因此展示当前借阅本身不需要新 schema。

真正的阻塞是 Xidian 图书馆认证：登录结果中的 `token` / `userId` 来自 HTML/JS body，后续请求注入 `application/x-www-form-urlencoded` body。当前 Broker 只支持 cookie/header，ADR-023 声明式注入也只支持 URL/header，不支持 form body。让 imperative adapter 自读 token 再拼 body 会直接违反红线 #1「凭证永不离开核心」。ADR-020 亦明确排除图书馆 form-body token。

建议拆三层：

1. **只读**：借阅、座位、预约状态，复用现有 capability。
2. **写操作**：续借、创建/取消预约，需新增独立 mutation capability，不得塞进 `library.loans`。
3. **新领域**：历史记录、馆藏检索等 registry 未覆盖的，按真实接口另开契约 ADR。

前置需要一个聚焦的 **body credential ADR**：从响应 body 收割 token/userId；form-field 或受限 JSON 字段注入；固定 method/URL/字段名；adapter 只能引用不透明句柄；日志/fixture/错误信息脱敏；写操作禁止自动重试并提供明确用户确认。

## 5. 物联网空调

底层 `ctx.fetch` 机制上已能发送带 method/headers/body 的 HTTPS 请求，官方 imperative adapter 确实「能发包」。但现有体系主要按读取数据设计，不能直接暴露成空调控制：registry 无 actuator capability；无「必须用户手势触发」的核心证明；无副作用请求的确认/幂等/防重放/禁自动重试规则；Broker 当前会跟随重定向，307/308 可能重放 body；无固定 body 模板与用户参数绑定；无标准控制结果 schema；iOS 首版不允许 imperative。

建议不要做泛化的 `url.send`，而是收敛为：`climate.devices` / `climate.status` / `climate.command`。`climate.command` 只接受有限业务参数（`deviceId` / `powerOn`·`powerOff` / `temperature` / `mode` / `fan`）。固定 HTTPS URL 必须来自已签名 manifest，UI 不能传任意 URL；凭证、签名密钥、tokenized URL 只能由 Broker 注入。

专项 ADR 至少应规定：只能由明确用户操作触发，禁后台刷新/自动执行；每次关键操作显示确认；不自动重试，超时显示「状态未知」而非假定失败；禁跨 origin 重定向（MVP 最好完全禁控制请求重定向）；精确 HTTPS origin/path 白名单；设备 token / 签名密钥 / 用户身份参数全部视为凭证；核心生成幂等键或明确学校接口自身幂等语义；MVP 的 DEPLOY 入口始终 official-only（catalog / 本地导入同门禁），DEV-Sideload 可全能力调试；Android 先行，iOS 待 imperative 合规复评或优先建设 declarative action graph。

**结论**：架构能够承载；ADR-030 已于 2026-07-31 接受，但在补齐 contract/核心闸门前，不能只写一个 imperative adapter 直接上线。现有探针要求 `x-access-token`；ADR-029 的命名 Header 生产接线及双端 runtime CH1–CH3 已落地，仍须人工安全签收。

## 6. Xidian C8（validator mixed-mode 误报）

当前 C8 是 validator 的 mixed-mode false positive：Xidian `notice.list` 是无凭证 declarative，课表/成绩/考试/空教室是 imperative，按 URL scope 隐式使用 `ehall-session`。C8 只统计 declarative `requests[].credential`，却用这个集合检查全部顶层 credentials，于是错误警告 `ehall-session` 未使用。它只是 warning，不阻断校验，也不是凭证泄漏。

**第一步（本轮 PR 已含）——修 C8**：存在 imperative capability 时无法静态断言顶层 credential 未使用，mixed-mode 不应产生 unused 警告；纯 declarative manifest 仍保留 unused warning；declarative 引用不存在 credential 仍保持 error。属 validator bugfix，不改契约/核心，不需 ADR。

**第二步——capability 级 `credentialRefs`（需 ADR）**：为每个 imperative capability 显式声明可用的 credential ref，而非看到整个 adapter 的所有 credential scope。关键语义：先按全部顶层 credentials 找 URL 最具体匹配，再检查该 ref 是否在当前 capability 的 `credentialRefs` 中；命中但未授权必须 `credential_not_permitted`，不能退化成无凭证 passthrough；每个 redirect hop 重新检查；只收割当前 capability 获准的 durable credential；QuickJS 不增加任何读取凭证的 API。该改动会动 `contract/manifest.schema.json`、Dart/TS Broker、launcher 与 adapter manifest，必须先开 ADR，并处理旧客户端忽略新字段的兼容（host/version gate，或明确旧客户端只保持 legacy 权限、不宣称具备 capability 隔离）。

## 7. 建议推进顺序

1. 修复 C8 mixed-mode warning，补 validator 回归测试。
2. 按已接受的 ADR-020 落地 query credential，接通 Xidian 一卡通。
3. 起草 capability 级 `credentialRefs` ADR，收窄 imperative 最小权限。
4. 起草 body/form credential 注入 ADR，为图书馆与空调签名请求提供共同基础。
5. 先实现图书馆只读能力，再为续借、预约创建/取消建立 mutation capability。
6. 起草 climate actuator ADR，先做 Android official-only 的固定 HTTPS endpoint。
7. 补 UI：课表、成绩、考试、空教室、一卡通、图书馆、设备控制入口。
8. 用脱敏测试账号做 Android/iOS 真机验收；真实凭证与学生数据不得进入 fixture。
9. 正式签名发布 Xidian 0.3.1 或后续版本，统一主仓旧 adapter、bootstrap 与外部 adapter 的状态说明。
10. 最后处理 campus relay、备用签名密钥、iOS 正式签名 / App Store、OHOS 与多校正式目录。

**近期里程碑**：先完成 C8 修复 + ADR-020 OpenID + Xidian 一卡通闭环，再启动图书馆 body 凭证 ADR；空调与图书馆 mutation 共用一套「用户主动副作用能力」原则，但保持不同 capability。
