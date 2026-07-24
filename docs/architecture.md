# Elecon 项目总架构档案

- **文档性质**：结构说明与当前实现状态档案
- **文档版本**：0.1
- **盘点日期**：2026-07-24
- **适用分支**：`refactor/request-graph-migration`
- **维护原则**：本文说明“系统现在由什么组成、如何运行、边界在哪里、当前最大工作是什么”；架构决策仍以对应 ADR 为准，实施细节以代码和测试为准。

本文不是 ADR 的替代物。ADR 记录为什么做出决策，本文记录决策落地后系统的结构、调用关系和现实状态。

## 1. 一页摘要

Elecon 是一个面向学生的校园信息聚合平台。系统把经常变化的学校接口适配逻辑放进可热替换的 QuickJS adapter，把凭证、网络请求、请求策略、脱敏和运行时安全收敛进可信核心，把 UI 与学校接口解耦到标准 schema。

最重要的四条边界是：

```text
UI       只消费标准 schema，不接触学校原始接口和凭证
Adapter  负责学校特有的清洗、归一化和派生，不持有凭证
Broker   决定请求能否发出、是否注入凭证、如何脱敏
Transport 只负责可信核心已经组装好的请求实际出网
```

端到端结构：

```text
Flutter UI
  -> SessionController
  -> AdapterService / AdapterLoader
  -> 签名 bundle + manifest 校验
  -> capability.requestGraph 分派
       |-- declarative: Core/Broker 先取数，adapter 只解析
       `-- imperative: adapter 通过受限 ctx.fetch 请求，Broker 代发
  -> QuickJS adapter
  -> 标准 elecon schema
  -> typed / generic UI card
```

私密请求的当前实际路径是客户端直连：

```text
Client Core/Broker -> DirectTransport -> 学校接口
```

公网服务端当前主要分发签名 adapter 产物，不应保存凭证或代取私密数据。`server/src/campus/` 是校内授权中继接口骨架，当前不可用。

## 2. 架构目标与不变量

### 2.1 目标

- 学校接口变化时优先替换 adapter，不要求应用重新发版。
- 将凭证和高信任能力限制在不可绕过的 Core/Broker 中。
- 让公网组件保持哑、无状态、无凭证。
- 让 adapter 与 UI 通过稳定的标准 schema 连接。
- 让 adapter 在后台运行，不阻塞 UI 线程。
- 保持 client/server 使用同一套 adapter 逻辑和尽可能一致的 QuickJS 语义。

### 2.2 不变量

以下是阅读或修改代码时必须持续检查的架构承重墙：

1. cookie、token、Authorization 等凭证只存在可信核心。
2. adapter 不能获得凭证值、带凭证 URL、`Set-Cookie` 或中间重定向票据。
3. `server/src/public/` 不保存凭证、不保存私密数据。
4. release 产物剔除侧载入口；dev/debug 才允许开发侧载。
5. release 下第三方或侧载 adapter 的 capability 必须是 declarative requestGraph。
6. adapter 不直接联网；imperative adapter 只能通过宿主暴露的 `ctx.fetch` 出网。
7. adapter 不渲染 UI；UI 不执行 adapter 内部逻辑。
8. `contract/` 是契约承重墙，schema 和 manifest 改动必须遵循对应 ADR。
9. adapter、Core 和 UI 不得提交真实学生数据、真实 cookie 或 token。

## 3. 分层与职责

### 3.1 UI 层

位置：

```text
client/lib/main.dart
client/lib/ui/
client/lib/session/session_controller.dart
client/lib/catalog/schools.dart
```

职责：

- 管理页面、会话状态、loading/error/empty 状态。
- 根据 capability 请求数据，不了解学校原始接口。
- 将标准 schema 解码为 typed model 或 generic section。
- 决定布局、组件、颜色、排序和交互。

当前首页路径：

```text
client/lib/ui/home/home_page.dart
  -> campus_snapshot_loader.dart
  -> SessionController.runCapability()
  -> schema_decode.dart
  -> CampusSnapshot
  -> ScheduleCard / GradesCard / NoticeCard / GenericSectionCard
```

UI 不是任意 Widget Tree 的 Server-Driven UI。服务端或 adapter 不能下发任意控件、颜色、CSS 或布局。

### 3.2 Contract / Schema 层

位置：

```text
contract/schema/
contract/capability/registry.json
contract/manifest.schema.json
contract/catalog.schema.json
contract/generated/dart/lib/
contract/generated/ts/
```

职责：

- 定义 capability 的输入、输出和 manifest 形状。
- 定义 adapter 到 UI 的标准数据结构。
- 为 validator、运行时、Dart UI 类型和 TypeScript 类型提供共同事实来源。

典型 schema：

```text
notice.list.schema.json
grades.list.schema.json
schedule.week.schema.json
exam.list.schema.json
classroom.available.schema.json
```

数据 envelope 的逻辑结构为：

```text
schema
schemaVersion
source: schoolId / adapterId / adapterVersion / origin
freshness: fetchedAt / ttlSeconds / stale
```

代码版本与数据新鲜度必须分开处理：adapter/UI 代码使用版本号，数据使用 TTL 和 freshness。

### 3.3 Adapter 层

位置：

```text
adapters/_stdlib/
adapters/school-xidian/
adapters/school-xjt/
adapters/school-helloworld/
```

每个 adapter bundle 的结构通常是：

```text
manifest.json
index.js
README.md
fixtures/
```

入口由 `manifest.runtime.entry` 指定，当前入口为 `index.js`，并通过：

```js
export const capabilities = { ... };
```

暴露 capability handler。

Adapter 的功能面可以很重：HTML 解析、字段清洗、日期归一、单位转换、校本派生、多接口结果拼装都应优先封装在这里。Adapter 的能力面必须很窄：无凭证、无任意网络、无渲染、无跨源权限。

当前正式 adapter：

| Adapter | Capability | requestGraph | 作用 |
|---|---|---|---|
| `school-xidian` | `notice.list` | `declarative` | 解析宿主代取的通知页面 |
| `school-xjt` | `notice.list` | `imperative` | 处理动态 challenge、cookie 和通知页 |
| `school-helloworld` | `app.announcement` | `imperative` | 测试运行时通路 |

`adapters_tests/` 中的旧学校代码是研究或历史测试资料，不是当前正式运行时入口。

### 3.4 Core / Adapter Runtime 层

客户端主要位置：

```text
client/lib/core/adapter_service.dart
client/lib/core/adapter_loader.dart
client/lib/core/adapter_launcher.dart
client/lib/core/adapter_runtime.dart
client/lib/core/declarative_host.dart
```

服务端主要位置：

```text
server/src/runtime/sandbox.ts
server/src/runtime/trusted-context.ts
```

职责：

- 下载、缓存、验签、校验 digest、检查吊销和版本。
- 从已验证 bundle 中读取权威 manifest。
- 只运行 manifest 声明的 capability。
- 按 capability 的 `requestGraph` 分派 declarative 或 imperative。
- 将 adapter 放入 QuickJS 沙箱，并限制宿主函数。
- 在后台运行 adapter，执行资源、请求和响应大小限制。
- 在成功执行后处理允许的 cookie harvest。

生产入口是 `client/lib/core/adapter_launcher.dart` 的：

```text
planLaunch(result)
  -> 校验 official trust
  -> 校验 source digest 与凭据 digest 绑定
  -> 从 bundle manifest 建立 BrokerManifestView
  -> 读取 capabilities / requestGraph / requests / dataflow

runLoadedAdapter(...)
  -> 检查 capability 是否被 manifest 声明
  -> 按 requestGraph 分派
```

### 3.5 Broker 层

客户端：

```text
client/lib/core/broker/
```

服务端：

```text
server/src/runtime/broker/
```

Broker 是可信核心中的唯一请求和凭证中介。它不是普通 HTTP helper，而是安全策略的执行点。

### 3.6 Transport 层

客户端：

```text
client/lib/core/transport/direct.dart
```

服务端：

```text
server/src/runtime/transport/direct.ts
```

Transport 只接受 Broker 已经组装好的 `TransportRequest`，实际与目标站点建立连接。它不决定 capability、credential scope、schema 或 UI。

当前首选路径是 `DirectTransport`。系统 VPN 和 app tunnel 是可替换的后续传输形态，不应将凭证策略下沉到 Transport。

### 3.7 服务端 public / campus

公网服务端：

```text
server/src/public/index.ts
```

只提供：

```text
/catalog.json.gz
/revocation.json
/bundles/<digest>.json.gz
```

校内中继：

```text
server/src/campus/index.ts
```

当前 `relayFetch()` 仍为未实现骨架。因此不要把 campus relay 当作当前可运行的私密数据链路。

## 4. Adapter 加载与执行

完整客户端调用链：

```text
UI
  -> SessionController.runCapability(capability)
  -> AdapterService.run()
  -> AdapterLoader.loadAdapter(adapterId)
  -> 验证 catalog / bundle / digest / signature / revocation
  -> planLaunch(LoadResult)
  -> runLoadedAdapter()
  -> QuickJS sandbox
  -> schema 校验与返回
```

加载阶段和运行阶段必须分开理解：

```text
加载阶段：确定“哪些字节、哪个 manifest、哪个 trust tier 可以执行”
运行阶段：确定“这个 capability 可以请求什么、是否注入凭证、输出什么 schema”
```

`planLaunch()` 是 source 与 official credential 绑定的关键点。执行源必须来自已验证 bundle，不能由调用者另外传入一份源码替换。

## 5. Broker 详细模型

### 5.1 Broker 组件

| 文件 | 主要职责 |
|---|---|
| `inject_policy` | allow 校验、scope 匹配、passthrough/inject/reject 决策 |
| `ports` | `CredentialResolver`、`Transport` 等可信依赖接口 |
| `assemble` | 净化 adapter 请求头、叠加凭证、合并 cookie |
| `fetch_proxy` | 串起完整请求、重定向、Set-Cookie 捕获和响应处理 |
| `cookie_jar` | per-execution origin cookie 与 ephemeral cookie |
| `harvest` | 将允许的 origin cookie 收割回凭证库 |
| `header_sanitize` | 请求头和响应头安全净化 |
| `redirect` | 手动重定向、逐跳 allow/scope 检查 |
| `dataflow` | declarative 的 bind/compute/inject |

### 5.2 Imperative `ctx.fetch` 的逐步动作

代码入口：

```text
server/src/runtime/broker/fetch-proxy.ts
client/lib/core/broker/fetch_proxy.dart
```

每次 adapter 调用 `ctx.fetch(url, init)`：

```text
1. decideInjection(currentUrl, manifest view)
   - URL 不在 network.allow：reject
   - URL 在 allow 且命中 credential scope：inject(ref, via)
   - URL 在 allow 但未命中 scope：passthrough

2. 若为 inject，调用 CredentialResolver.get(ref)

3. CookieJar.selectForSend(currentUrl)

4. assembleRequest()
   - 删除 adapter 自带 Cookie / Authorization / Proxy-Authorization
   - 叠加 Broker 决定的凭证
   - 合并允许发送的 cookie

5. Transport.fetch()

6. CookieJar.captureSetCookie()
   - Set-Cookie 进入核心 jar
   - 不进入 adapter response headers

7. decideRedirect()
   - 每跳重新检查 allow
   - 每跳重新决定凭证
   - 最多有限跳数
   - 中间 Location 不交 adapter

8. processResponse()
   - 删除 Set-Cookie、Authorization、Location
   - 返回 status、允许的 headers 和 body
```

重定向使用手动跟随，不应由 Transport 自动跟随，因为核心必须在每一跳重新执行 allow、凭证和 cookie 策略。

### 5.3 凭证注入边界

凭证明文的合法流动范围：

```text
CredentialStore / CredentialResolver
  -> assembleRequest
  -> TransportRequest
  -> Transport
  -> 学校接口
```

凭证不应流入：

```text
QuickJS adapter
responses map
UI
public server
schema data
日志和错误消息
```

`decideInjection()` 本身不读取凭证值，只产生策略结果。真实读取发生在 Broker 已确定 URL 合法且确实需要注入之后。

### 5.4 Cookie 的两区模型

```text
origin cookie 区
  -> 接收站点 Set-Cookie
  -> 后续请求发送
  -> 成功执行后可按 manifest harvest

ephemeral cookie 区
  -> adapter 通过 ctx.setEphemeralCookie 写入
  -> 仅当前 execution 有效
  -> 不 harvest
  -> execution 结束丢弃
```

Cookie 的 domain/path/source 等内部元数据不交给 adapter。

## 6. Declarative 与 Imperative

### 6.1 Declarative

Declarative adapter 没有网络 API。宿主根据 manifest 中的静态 `requests[]` 取数，然后把脱敏后的响应交给同步 adapter 解析：

```text
manifest.requests[]
  -> fulfillDeclarativeRequests()
  -> Broker / Transport 取数
  -> responses[key]
  -> runDeclarativeAdapter()
```

当前生产接线：

```text
client/lib/core/adapter_launcher.dart
client/lib/core/declarative_host.dart
client/lib/core/broker/fetch_proxy.dart
```

`school-xidian` 是当前正式 declarative 示例。

### 6.2 Imperative

Imperative adapter 可以根据前一个响应决定后续动作，但所有网络仍必须经过宿主 Broker：

```text
QuickJS adapter
  -> ctx.fetch()
  -> host function
  -> proxyFetch()
  -> Broker
  -> Transport
  -> 脱敏 Response
  -> QuickJS adapter
```

`school-xjt` 保留 imperative 是有意设计：challenge 响应决定后续请求，且存在不可枚举的 browser fingerprint 和动态 cookie 行为。

### 6.3 ADR-023 数据流

固定拓扑的 declarative 请求可以使用：

```text
bind     从核心内部 raw response 提取不透明句柄
compute  在核心内部执行封闭算子
inject   将句柄注入静态 URL 或 header 汇聚点
```

运行顺序：

```text
请求依赖 DAG
  -> 拓扑排序
  -> URL 参数展开
  -> bind/compute/inject
  -> 最终 URL 上重新做 credential policy 检查
  -> proxyFetch
  -> raw response 仅供核心 bind
  -> stripEchoes
  -> responses[key]
  -> adapter
```

Adapter 看不到：

```text
HandleValue
bind 变量
compute 结果
注入后的值
raw response
注入值在 response 中的回显
```

当前 Dart 生产执行器是：

```text
client/lib/core/broker/dataflow.dart
client/lib/core/declarative_host.dart
```

服务端：

```text
server/src/runtime/broker/dataflow.ts
```

服务端 TS 当前定位是跨端语义参考和 golden 执行器，不是公网生产代取器。

## 7. 标准数据流与 UI 消费

以通知为例：

```text
学校 HTML / JSON
  -> Broker/Transport 获取
  -> adapter 解析和归一化
  -> elecon.notice.list envelope
  -> runtime 输出校验
  -> SessionController
  -> schema_decode.dart
  -> NoticeList / CampusSnapshot
  -> NoticeCard
```

adapter 和 UI 的唯一正式耦合点是：

```text
emits.schema + schemaVersion + data shape
```

学校 URL、页面结构、登录流程和 challenge 细节不应进入 UI。

## 8. 当前重构状态

### 8.1 ADR-022：`mode` 到 capability `requestGraph`

已落地内容：

- 删除旧的顶层 `mode` 运行时分派。
- 每个 capability 必须声明 `requestGraph`。
- `declarative` 使用宿主代取和同步解析。
- `imperative` 使用受限 `ctx.fetch`。
- validator 已加入 declarative/imperative 的互斥规则。
- 模板目录已区分：

```text
adapters/_template/declarative/
```

主要位置：

```text
contract/manifest.schema.json
client/lib/core/adapter_launcher.dart
client/lib/core/adapter_runtime.dart
server/src/runtime/sandbox.ts
adapters/*/manifest.json
```

### 8.2 ADR-023：声明式跨请求数据流

已落地内容：

- manifest 增加 `bind`、`compute`、`inject`。
- validator 已实现 D1-D16 结构和组合约束。
- server 有 TS 参考执行器和 golden。
- client 有 Dart 执行器和 golden。
- client 已接入 `fulfillDeclarativeRequests()` 生产路径。
- 注入值在 adapter 可见前执行回显剥除。

尚未完成内容：

- 人工安全审查和 owner 签收。
- 全部安全清单逐项确认。
- 自动 taint 围栏。
- regex 回溯步数预算。
- 足够的真实站点 replay fixture。
- 对服务端参考执行器“只能用于测试、不得进入生产代取路径”的人工确认。

### 8.3 ADR-024：构建信任 profile

目标是将优化等级与侧载入口分离：

```text
DEPLOY -> release 产物无侧载入口
DEV    -> debug-only 侧载入口、独立标识和警告
```

该轨道与 requestGraph/dataflow 轨道并行，必须单独检查 release gate 是否机械有效。

## 9. 当前最大工作项

当前最大的工作不是继续增加 adapter 功能，而是完成可信核心和声明式数据流的人工安全闭环。

优先级建议：

### P0：完成 Broker / Dataflow 安全签收

重点审查：

1. `onRawResponse` 是否始终只由 Core 构造，且 raw response 不进入 QuickJS。
2. `bind`、`compute`、`inject` 的句柄流是否能绕过静态 DAG 限制。
3. URL 和 header 注入后是否始终重新执行 credential scope 判断。
4. `stripEchoes` 是否覆盖所有 adapter 可见响应面。
5. 错误、日志和诊断信息是否可能包含凭证或句柄值。
6. declarative 与 imperative 是否都能取消 in-flight 请求。
7. 请求数、body 大小、单请求超时和累计网络预算是否真正 fail-closed。

对应文件：

```text
client/lib/core/declarative_host.dart
client/lib/core/broker/dataflow.dart
client/lib/core/broker/fetch_proxy.dart
server/src/runtime/broker/dataflow.ts
server/src/runtime/broker/fetch-proxy.ts
docs/reference/declarative_dataflow_security_checklist.md
```

### P1：完成可信运行时生产接线

需要确认：

- official bundle 验签、吊销、digest 绑定和 capability gate 的完整入口。
- 生产 CredentialStore 的真实安全存储装配。
- public server 不会意外进入私密代取路径。
- campus relay 若要启用，必须先完成独立的安全和授权设计。

对应文件：

```text
client/lib/core/adapter_service.dart
client/lib/core/adapter_loader.dart
server/src/runtime/trusted-context.ts
server/src/runtime/credential/store.ts
server/src/public/index.ts
server/src/campus/index.ts
```

### P2：完成运行时限额和脱敏缺口

当前需要重点验证或补齐：

- 累计网络时间超过预算时主动取消正在进行的请求。
- declarative 路径传入并使用统一取消 token。
- response body 的 token pattern audit 是否需要落地。
- cookie 的过期属性是否需要在 jar 中保留。
- `ResolvedCredential.via` 与注入决策类型是否需要额外一致性校验。

### P3：真实 adapter 与 schema 业务覆盖

在 Core 安全闭环后，再增加真实 capability：

- 成绩、课表、考试、空教室、一卡通、图书馆等标准 schema。
- 每个学校特有的归一化和派生逻辑继续放入 adapter。
- 只有固定拓扑、可静态声明的流程才迁移到 declarative。
- 动态 challenge、动态拓扑和不可枚举环境计算保留 imperative。

## 10. 阅读代码的推荐顺序

新架构师或程序员建议按以下顺序建立上下文：

1. 阅读 `AGENTS.md` 和本文，先理解不变量与实际状态。
2. 阅读 `docs/adr/adr_000_abstract.md`，理解总体取舍。
3. 阅读 `docs/adr/adr_009_fetch_credential.md`，理解 imperative Broker 和凭证边界。
4. 阅读 `docs/adr/adr_022_request_graph.md`，理解 declarative/imperative 分派。
5. 阅读 `docs/adr/adr_023_declarative_dataflow.md`，理解 bind/compute/inject。
6. 从 `client/lib/core/adapter_launcher.dart` 进入生产执行路径。
7. 继续读 `client/lib/core/declarative_host.dart` 或 `client/lib/core/adapter_runtime.dart`。
8. 重点读 `client/lib/core/broker/fetch_proxy.dart` 和同目录纯函数。
9. 对照 `server/src/runtime/broker/` 的 TS 实现和 smoke/golden。
10. 最后读 `adapters/school-xidian/index.js` 与 `adapters/school-xjt/index.js`，观察两种 requestGraph 的真实差异。

## 11. 权威来源关系

发生冲突时按以下顺序处理：

```text
1. 代码、测试和实际构建产物：当前实现事实
2. 本架构档案：结构说明和状态汇总
3. 对应 ADR：设计决策和不可擅自改变的边界
4. reference 文档：实施计划、迁移清单和操作说明
```

其中“代码优先”不意味着可以绕过 ADR 修改核心或契约。若当前实现与 ADR 不一致，应先记录差异并按规则补充决策或人工安全审查。

本文只负责导航和结构梳理；新增 schema、修改 manifest 契约、修改 Broker、凭证、Transport、签名或 release trust 逻辑时，仍必须遵守对应 ADR 和 `docs/rules/`。
