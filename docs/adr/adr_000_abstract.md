# ADR-000：V2 总体架构与责任模型

- **状态**：已接受（Accepted）
- **日期**：2026-08-11
- **适用范围**：V2 全项目
- **历史背景**：V1 ADR 已冻结于 [`archived/v1/`](./archived/v1/README.md)

---

## 1. 背景

elecon 面向学生聚合校园信息。学校接口差异大、变化快、认证流程不统一，而项目可投入的维护人力有限。系统必须让社区作者能够用熟悉、直接的方式编写和更新学校 adapter，否则 adapter 生态无法扩张，热替换架构也失去意义。

V1 试图让 adapter 永远看不到凭证及其等价物。为覆盖跨请求认证流程，项目逐步建立了声明式 request graph、`bind/compute/inject`、不透明句柄、封闭计算词表、Broker 自动凭证注入和 Response Masker。

这套模型具有安全价值，但产生了三个结构性问题：

1. **开发复杂**：作者需要学习项目私有的数据流语言，而不是直接编写普通异步 JavaScript。
2. **覆盖不完整**：动态分页、响应分支、反爬挑战、校本签名和未知认证流程无法被有限声明式模型完整表达；扩充词表会持续制造跨端实现和文档负担。
3. **责任错位**：流程决策逐渐从 adapter 作者转移到核心，用户也无法选择接受更高风险以运行自己信任的代码。

V2 以最大化 adapter 的灵活性、开发便捷性和社区供给为首要目标。项目不再追求用核心机制阻止受信 adapter 接触凭证，而是重新划分权力与责任：

> 用户决定信任哪些 adapter；adapter 作者决定学校流程如何执行；官方平台负责严格审核、来源治理和高效率分发；宿主只保留少数不可绕过的执行与网络边界。

---

## 2. 目标

V2 优先优化：

1. adapter 作者使用普通异步 JavaScript 完成请求、认证、计算和解析；
2. 学校流程变化可通过 adapter 更新解决，不要求扩充核心私有 DSL；
3. 用户可运行官方 adapter，也可在充分知情后选择本地代码；
4. 官方平台可以扩展到大量 adapter，同时保持严格、高效、可追溯的审核；
5. 公网服务端继续不接触用户凭证和私密数据；
6. 核心边界数量减少，并且每条边界都能由运行时明确强制。

V2 不以阻止受信 adapter 泄漏、篡改或误用凭证为目标。

---

## 3. 权力与责任

### 3.1 用户

用户拥有最终执行决定权：

- official adapter 由项目审核并自动受信，不逐项请求用户授权；
- 支持本地导入的平台允许用户按 bundle digest 整体信任 local unsigned adapter；
- digest 变化视为新代码，必须重新选择信任；
- MVP 不实现用户自签或“信任某签名者”的自动继承，后者保留为未来能力；
- 用户可撤销本地 digest trust、禁用或删除 adapter。

用户信任 local unsigned adapter，表示接受该 adapter 读取、修改、删除或泄漏应用内全部凭证和私密 adapter 数据的风险。项目必须提供准确、显著的风险说明，但不以风险为由替用户禁止该选择。

### 3.2 adapter 作者

adapter 作者获得流程决定权：

- 自行读取所需凭证；
- 自行构造请求、处理重定向可见信息和协议中间值；
- 自行实现动态分支、循环、分页、签名、挑战应答和校本计算；
- 自行解析私密响应并输出标准 schema；
- 按 Credential Store API 写回、更新或删除凭证。

相应地，作者承担更高责任：

- 不窃取、泄漏或滥用凭证和学生数据；
- 不把真实凭证、学生数据或未脱敏响应提交到源码、fixture、日志或 issue；
- 准确声明网络出口和 adapter 行为；
- 对依赖、更新和学校协议变化负责；
- 接受 official 审核、持续扫描、问题整改和必要时的吊销。

### 3.3 官方平台

official 表示项目对特定 adapter 字节进行了严格审核和背书。official adapter 自动获得执行信任和完整 adapter 能力，不向用户逐项弹出凭证、网络、登录、SSO 或 actuator 确认。

官方平台负责：

- 维护公开、明确、可执行的审核标准；
- 验证 bundle identity、来源、依赖、网络声明和 fixture；
- 对代码和更新执行确定性静态检查、fixture replay、行为观察和威胁分析；
- 由人工完成最终安全与质量把关；
- 使用离线签名、catalog、sequence、兼容门和吊销治理 exact bytes；
- 对已发布 adapter 持续复审，并快速吊销确认有害的版本。

签名证明来源、完整性和官方背书，不证明代码不存在缺陷或恶意行为。

---

## 4. LLM 辅助审核

官方平台计划使用 LLM 扩大 adapter 审核吞吐量。LLM 可用于：

- 解释混淆或复杂控制流；
- 标记凭证读取、日志、编码和可疑外传路径；
- 比较 manifest 网络声明与实际请求；
- 分析依赖、动态分支、时间触发和异常路径；
- 对更新版本生成权限、行为和风险 diff；
- 汇总 deterministic scanner、fixture replay 和人工观察证据；
- 为人工 reviewer 生成检查清单和重点路径。

LLM 不是信任根，也不是最终签署者。审核流水线必须满足：

- LLM 无官方签名密钥、无真实用户凭证、无生产 Credential Store；
- 只使用脱敏或合成 fixture；
- 将 adapter 源码、文档和响应全部视为不可信输入，防止提示注入影响审核控制面；
- 保存模型、版本、提示模板、输入 digest、输出和人工裁定，保证审核可追溯；
- LLM 结论只能产生 finding，不能自动放行、签名或压制 deterministic gate；
- 最终 official 签署必须由人工 reviewer 明确批准 exact bundle digest；
- 高风险或模型意见冲突时升级人工深审，不以多数模型投票替代责任主体。

LLM 的目标是提高发现率和审核效率，不提供“已证明安全”的承诺。

---

## 5. 强制边界

### 5.1 执行准入

未受信 adapter 永不执行：

- official 必须通过官方验签、身份绑定、吊销和兼容门；
- local unsigned 的安装界面必须先展示风险和 exact bundle digest；用户点击确认接受前，只允许 bounded unpack、digest、manifest/schema 校验和静态分析，不得创建 adapter runtime 或执行任何 bundle 代码；确认后才能保存 digest trust；
- manifest 自报、adapter ID 相同、文件名相同或无效签名都不能产生或继承信任；
- iOS MVP 只运行 official adapter。即使导入代码存在，也必须由 loader/runtime 强制 official-only，不能只隐藏 UI 入口。

### 5.2 QuickJS 隔离

adapter 只在背景 QuickJS isolate 中异步运行，不获得：

- Node/Dart 模块；
- raw socket；
- WebView；
- 原生 FFI；
- 任意文件系统或进程能力；
- UI 线程同步执行能力。

宿主继续强制执行时间、内存、请求数和响应大小预算。

### 5.3 宿主唯一网络出口

所有 adapter 网络请求必须经过宿主 API。宿主强制：

- scheme、origin、path 和 method；
- 重定向逐跳复核；
- loopback、link-local、私网地址和 DNS 解析策略；
- 请求体、响应体、超时、取消和并发预算；
- transport 选择和 TLS 边界。

manifest 必须声明 adapter 可能访问的全部网络目标；声明同时用于用户风险展示、official 审核和宿主运行时 fail-closed 上限。

网络门限制 adapter 可以连接的位置和消耗的资源，不是内容 DLP。受信 adapter 可以把凭证或私密数据编码进获准请求，宿主不承诺识别或阻止这种行为。

### 5.4 Credential Store

受信 adapter 可读写全部 Credential Store。Store 使用结构化复合键避免不同 profile、学校、账户、服务和凭证名称发生无意重名；不得继续仅以全局裸字符串 `session`、`token` 等寻址。

复合键只解决命名和误覆盖，不构成受信 adapter 之间的机密性或完整性隔离。精确键结构、并发和原子写语义由后继 ADR 固定。

### 5.5 公网与私密数据

- `server/src/public` 保持零凭证、无私密数据持久化；
- `server/src/public` 不执行任何 adapter；
- 私密和认证数据只在用户设备上经 direct、系统 VPN 或 official transport/app-tunnel 访问学校；项目不提供校内授权中继；
- official 审核环境只使用测试账号、脱敏 fixture 或合成凭证；
- 不得因 adapter 获得凭证而把用户凭证上传到官方平台。

### 5.6 Transport

adapter 导入自由不得扩展到 transport。transport 继续只随官方应用分发，不向 adapter 或本地 bundle 开放原生模块、VPN、raw socket 或 TLS 中间人能力。

### 5.7 契约与 UI

- adapter 输出继续接受标准 schema 校验；
- UI 不执行 adapter 下发的任意原生渲染代码；
- adapter 吸收学校差异和校本派生，上层消费统一数据；
- 修改 contract、执行信任、Credential Store、网络出口、签名或 transport 必须先有 ADR。

---

## 6. 明确退役的 V1 机制

V2 不继续维护：

- declarative / imperative 双 requestGraph；
- `requests/bind/compute/inject` 数据流 DSL；
- opaque handle；
- Broker 自动代 adapter 完成全部凭证注入；
- 为 dataflow 维护的跨端封闭 crypto op；
- mandatory Response Masker；
- 以 DEV/DEPLOY profile 作为 unsigned adapter 唯一执行边界；
- “凭证及等价物永不进入 adapter”的产品保证。

现有实现应在 V2 替代门和 adapter 迁移完成后删除，不长期维护双契约或双 runtime。

---

## 7. 继续复用的资产

V2 不是推倒重来。以下资产继续保留：

- QuickJS runtime、background isolate 和资源预算；
- 宿主网络代理、URL/redirect 检查和 transport；
- Credential Store 的平台安全存储后端；
- 标准数据 schema、capability registry 和 UI；
- 脱敏 fixture replay、expected schema、PII scanner 和输出校验；
- catalog/revocation 等跨组件 wire/signature 向量；不再维护客户端/服务端 adapter runtime 一致性 golden；
- bundle envelope、digest、官方签名、catalog、sequence 和吊销；
- 公网零凭证与客户端直连架构；
- adapter 热更新和公开 adapter 仓库。

---

## 8. 迁移原则

迁移必须遵循以下顺序：

1. 先建立 V2 contract、执行准入、digest trust、iOS loader gate、Credential Store API 和网络出口测试；
2. 将现有 adapter 转为统一异步 JavaScript；
3. official 与 local unsigned 两条路径均通过真实 bundle 和合成凭证测试；
4. 再删除 declarative/dataflow/opaque handle/Masker 和旧 trust profile；
5. 最后清理 V1 兼容字段、实现和 CI 门。

不得先移除旧边界，再补 V2 的执行准入或宿主出口。

---

## 9. 后继决策

以下主题必须分别建立 V2 ADR：

- Manifest V2、统一 adapter SDK 与迁移窗口；
- Credential Store 复合键和 JS 读写 API；
- 宿主网络权限、URL canonicalization 与地址策略；
- local bundle 导入、digest trust、更新和撤销；
- official 审核流水线、LLM threat scan 与人工签署 ceremony；
- bundle 签名、catalog、revocation 和 release ledger；
- iOS/App Store 分发策略；
- transport 与 app-tunnel；
- 标准 schema、UI 和 actuator 边界。
