# ADR-001：V2 项目形态、单一执行面与责任拓扑

- **状态**：已接受（Accepted，2026-08-11 owner 评审通过）
- **日期**：2026-08-11
- **依赖**：[ADR-000](./adr_000_abstract.md)
- **覆盖**：ADR-000 §3、§5.5、§7、§9 中关于校内授权中继、服务端 adapter 执行及跨 runtime golden 的表述
- **实施约束**：`server/src/campus` 直接删除；跨 runtime golden 仅按 §4.7 审计分类，在替代测试落地后逐项处理

---

## 1. 摘要

V2 采用**客户端单一生产执行面**：需要用户凭证、私密响应或学校认证状态的 adapter，只在用户设备上的可信客户端宿主中执行。项目不再建设、部署或维护校内授权中继，也不提供由项目服务器代用户访问学校私密接口的路径。

项目同时停止维护“客户端 QuickJS 与服务端 QuickJS-wasm 行为一致”的架构承诺，不再以共享跨 runtime golden 证明两套引擎、绑定和 host API 等价。服务端不再作为 adapter 的第二个产品运行目标。

fixture 测试继续保留，并成为 adapter 回归、协议变更检测、标准 schema 验证和 official 审核的重要证据。退役的是**跨 runtime 一致性 golden**，不是 fixture、expected output、mock transport 或 replay 测试本身。

---

## 2. 背景与问题

### 2.1 校内授权中继的成本与项目目标不一致

校内授权中继原本用于解决校外无法直连学校私密接口的问题。它要求项目或合作学校长期承担：

- 校内部署、网络准入、域名、证书和可用性维护；
- 用户身份、凭证、会话和多租户隔离；
- 学校授权、数据处理协议、审计和事件响应；
- 私密请求路由、限流、日志净化、密钥轮换和灾难恢复；
- 各学校独立环境、升级窗口和责任主体协调。

这不是一个可以被“轻量 optional backend”吸收的附加功能。它会形成第二套持有私密数据的生产系统，并把项目从本地优先应用扩展为校园身份和数据处理服务。该长期责任与“以最少维护人力提升 adapter 供给和学校变化韧性”的首要目标冲突。

### 2.2 双运行目标制造持续的语义税

V1 希望同一 adapter 同时运行于客户端 QuickJS 和服务端 QuickJS-wasm，并用共享 golden 限制语义漂移。实践中，两端仍具有不同的：

- QuickJS 版本、编译选项、FFI/wasm 绑定和 job queue；
- host API、网络栈、取消、时间、编码和错误映射；
- 平台存储、cookie、WebView、transport 和资源预算；
- 发布周期、依赖图和故障环境。

共享 golden 只能覆盖枚举到的行为，不能证明两个运行时一般等价。每增加一个 SDK 方法、错误分支或平台能力，都必须维护双实现和一致性向量。这将 V2 希望交还 adapter 作者的流程自由，重新转化为核心跨端兼容负担。

### 2.3 fixture 与跨 runtime golden 是两类资产

二者必须明确区分：

- **fixture 回归**回答“给定脱敏学校响应和请求脚本，这个 adapter 是否仍产生符合标准 schema 的预期结果”；
- **跨 runtime golden**回答“客户端和服务端的两个执行器是否对同一低层语义向量产生相同结果”。

前者直接服务学校 adapter 的正确性、审查和维护，应长期保留；后者服务已经取消的双产品运行目标，应停止扩展并在替代测试建立后删除。

---

## 3. 决策驱动因素

本 ADR 优先考虑：

1. 将有限维护资源集中于客户端、adapter SDK、审核和发布治理；
2. 不让项目服务器接触用户凭证或私密校园数据；
3. 减少 adapter 作者必须理解的运行环境和兼容限制；
4. 保留能直接发现学校协议回归的 fixture 资产；
5. 让生产行为的权威实现唯一且可明确测试；
6. 接受校外私密数据在网络条件不满足时不可用，而不是用服务器托管凭证换取可用性。

---

## 4. 决策

### 4.1 四个责任单元

V2 由四个长期责任单元组成：

1. **Flutter 客户端可信宿主**
   - 唯一的产品级 adapter 执行面；
   - 负责执行准入、QuickJS、Credential Store、宿主网络、WebView、transport 接线、标准输出校验和 UI；
   - 私密请求由用户设备直接发送到学校或通过用户设备上的 official transport 发送。

2. **QuickJS adapter 层**
   - 受信 JavaScript 自行读取凭证、构造请求、执行认证流程、计算、解析并输出标准 schema；
   - 只面向客户端定义的 V2 SDK 和 host API；
   - 不承担服务端 runtime 兼容义务。
   - manifest 必须完整声明 adapter 可能访问的所有网络 scheme、origin、path 和 method；宿主将其作为强制上限。

3. **公网哑服务 `server/src/public`**
   - 只分发 official adapter、catalog、revocation、公开配置和允许缓存的公开数据；
   - 零用户凭证、零私密校园数据、无用户会话；
   - 不执行需要用户身份、学校 session 或私密响应的 adapter；
   - 不提供“临时”“降级”或“仅部分学校”的私密代理入口。
   - 不执行任何 adapter，包括公开数据 adapter；公开数据只能作为预先生成、独立审核的静态产物进入分发目录。

4. **审核与发布治理面**
   - 由 `tools/`、CI、隔离审查环境、LLM threat scan、人工 reviewer、离线签名设备和发布台账组成；
   - 使用合成凭证、测试账号和脱敏 fixture；
   - 可以为审核目的运行 adapter replay，但该运行不是生产服务，也不建立第二个 runtime 兼容承诺。

`contract/` 继续作为 Manifest V2、SDK 类型、标准 schema 和 bundle 格式的事实来源。真实 adapter 位于独立公开仓，本仓通过 exact ref 获取；缓存、生成目录、fixture 和 `dist-*` 均不是执行信任来源。

### 4.2 校内授权中继退出项目形态

V2 不实现或维护校内授权中继：

- `server/src/campus` 直接删除，不保留 501 stub；
- 不为其维护 API、部署模板、凭证协议、状态存储、CI、监控或兼容层；
- 不接受以“学校自建”“可选插件”“未来备用”为理由在主仓保留半实现生产面；
- 现有 stub、文档、测试和部署入口应在本 ADR 接受后按迁移计划删除或归档。

若未来重新提出由服务器处理用户私密数据，必须另立明确覆盖本 ADR 的架构决策，重新评估数据责任、学校授权、多租户隔离、运维主体、成本和事件响应；不得把它视为普通 feature。

### 4.3 执行前确认与 manifest 网络声明

official adapter 经官方执行准入门后自动受信。local unsigned adapter 的安装流程可以在执行前完成 bounded unpack、digest、manifest/schema 校验和静态风险分析，但在用户点击“确认接受并安装非官方 adapter”之前，不得：

- 创建 QuickJS adapter runtime；
- 执行 entry、module initializer、capability 或迁移脚本；
- 调用 adapter 提供的探测、预览或安装钩子；
- 读取 Credential Store、发起 adapter 网络请求或产生 adapter 持久化副作用。

用户确认必须绑定界面实际展示的 exact bundle digest。确认后才可铸造 local digest trust 并进入统一执行路径；取消、关闭窗口或解析失败均不得留下可执行 grant。

Manifest V2 继续强制 adapter 声明其可能访问的全部网络目标。完整声明用于：

- 用户在确认 local unsigned adapter 时理解其出网面；
- official reviewer 比较声明与代码、fixture 和观测行为；
- 宿主在每次请求和每跳重定向前执行 fail-closed 裁定。

manifest 网络声明不是细粒度用户授权，也不承诺检测获准请求中的秘密内容。受信 adapter 仍可向其获准目标发送凭证或私密数据。

### 4.4 校外访问由用户侧网络条件承担

私密数据只有以下访问路径：

- 用户设备直接连接学校；
- 用户自行配置的系统 VPN；
- 随官方应用分发、由宿主管理的 official transport/app-tunnel。

当这些路径均不可用时，相应私密 capability 明确失败或展示缓存的本地历史结果。项目不通过公网或校内部署的项目服务代取最新私密数据。

该决策主动降低部分场景的可用性，以换取更小的数据责任、攻击面和长期维护面。

Transport 基座继续存在，本 ADR 不退役 direct、system VPN 或 app-tunnel。app-tunnel 运行在用户设备和宿主网络边界内，不引入项目服务器私密执行面，因此不受删除 campus relay 的影响。transport 仍由官方应用分发，adapter 不获得 native transport、raw socket、VPN 或 TLS 中间人能力；具体边界由 ADR-007 裁定。

### 4.5 客户端是唯一、全平台通用的生产 runtime 权威

客户端 QuickJS、V2 SDK 和客户端 host API 定义 adapter 的生产行为。该 runtime 契约对 Android、iOS、OHOS 和 desktop 共用，不建立平台专属 adapter 语言、manifest 分支或 capability 语义。平台差异必须收敛在宿主绑定、WebView、secure storage 和 transport seam 之下；adapter 源码和 SDK 行为保持同一套定义。

“全平台通用”不表示所有平台实现天然无差异，也不恢复客户端/服务端双跑。实际平台测试矩阵、真机层级和 release gate 由后续 CI/平台 ADR 决定；在此之前，不得用某一平台测试结果宣称所有平台已经签收。

服务端 Node/TS 可以继续承担：

- manifest 和 bundle 静态验证；
- source policy、依赖和许可证扫描；
- fixture 编排工具；
- LLM 审核上下文生成；
- 与网络无关的纯工具函数测试；
- 隔离审查环境中的辅助 replay。

这些工具不得被描述为与客户端 runtime 等价，也不得作为“服务端测试通过，因此客户端行为已证明”的依据。official 发布必须包含针对实际客户端 QuickJS/host API 的测试证据。

### 4.6 退役跨 runtime 一致性 golden

V2 不新增、不扩展并最终删除用于证明客户端与服务端执行器一致的 golden，包括：

- 同一 host API 在 Dart/TS 两端逐字段一致的语义向量；
- 为双执行器维持的 dataflow、Masker、cookie 注入或私有计算词表向量；
- 仅因“同一 adapter 必须在两端运行”而存在的 canary 和 dual-run gate。

删除必须遵循迁移顺序：先确认相应行为不再被 V2 contract 或客户端生产测试依赖，再移除 golden、服务端镜像实现和 CI job。不得通过一次性删除全部 `contract/golden/` 误伤仍有独立价值的协议、bundle、签名或 fixture 测试。

### 4.7 golden 审计与迁移裁定

对现有 `contract/golden/` 的逐文件审计结论如下：

| 处理 | 文件 | 理由与前置 |
|---|---|---|
| **保留** | `catalog/catalog.json`、`revocation/revocation.json` | TS 发布工具与客户端 loader 的 wire/signature 互操作，不属于双 runtime；继续保护 exact bytes、签名、回滚和吊销 |
| **迁为客户端单端 fixture** | `broker/redirect.json` | 重定向仍是宿主网络安全边界，但权威实现只在客户端；补齐 canonical URL、跨 origin、DNS/IP、取消后零副作用后再删除 TS 镜像 |
| **随 V1 删除** | `broker/dataflow.json`、`broker/harvest.json`、`broker/inject-policy.json`、`broker/response-masker.json`、`broker/response-masker-validator.json` | 分别绑定已退役的 dataflow、自动收割/注入和 mandatory Masker；须先迁完 adapter、contract、validator、fixture 和客户端接线 |
| **按 V2 重写** | `bundle/loader.json` | 保留 bundle/digest/signature 测试职责，改为 official 与 local digest trust、TOCTOU、iOS official-only 和 Manifest V2 |
| **按 V2 重写并迁客户端** | `broker/cookie-jar.json`、`broker/assemble.json`、`broker/url-match.json`、`broker/header-sanitize.json` | HTTP/cookie/network/header 仍有独立价值，但 V1 自动凭证注入、响应隐藏和 TS/Dart 镜像语义不能继承 |

不得按目录批量删除 `contract/golden/`。每个文件只有在表中指定的 V2 替代测试成为 required gate、消费者完成迁移后才能删除或替换。

### 4.8 fixture、expected output 与 replay 长期保留

每个 official adapter capability 应保留可审查、脱敏的 fixture。按场景至少包含：

- 学校响应样本或结构化 synthetic response；
- imperative 请求序列的 mock transport script；
- 固定输入参数、时间、账户和环境条件；
- 预期标准 schema 输出或预期错误；
- 网络声明、重定向和资源预算的观测记录；
- 对学校协议变化和历史 bug 的回归样本。

fixture 测试的权威目标是：

1. adapter 在目标客户端 runtime 中可执行；
2. 请求未越过 manifest 与宿主网络边界；
3. 输出符合 capability schema；
4. 已知学校响应变化不会静默破坏归一化；
5. official 审核可以比较版本间的行为差异。

服务端工具可以读取和预检同一 fixture，但不要求与客户端逐字节、逐异常或逐调度一致。若工具结果与客户端结果冲突，以客户端目标 runtime 和人工调查为准。

### 4.9 标准 schema 保持跨组件契约

取消 runtime 双跑不取消数据契约。adapter 输出、客户端 UI、缓存格式和审核工具仍共享标准 schema。schema validator、codegen drift、capability registry 和 fixture expected output 继续作为 required gates。

adapter 更新只能实现 App 已知 capability，不能通过 bundle 增加原生 UI、transport、WebView controller 或新的 host API。

---

## 5. 安全分析

### 5.1 攻击面收缩

删除校内授权中继后，项目不再需要防护一个长期在线、持有多用户凭证和私密响应的服务器。由此消除或显著降低：

- 服务端凭证库泄漏；
- 多租户身份混淆；
- 私密响应日志、备份和遥测泄漏；
- 校内节点被攻陷后横向访问学校系统；
- 中继管理员、部署方和项目方之间责任不清；
- public/campus 错误路由或部署身份混用。

### 5.2 保留风险

- 受信 adapter 仍可读取并外传客户端 Credential Store；该风险由执行信任、official 审核和用户 digest trust 承担。
- 用户设备、系统 VPN 和 official transport 仍可观察或影响流量，其边界由后继 ADR 约束。
- 客户端成为唯一生产实现后，其 runtime bug 影响全部用户，必须提高客户端测试和人工审查强度。
- 无服务端 fallback 时，学校网络不可达会直接降低可用性。

### 5.3 取消双跑不会降低的保证

以下保证不依赖双 runtime golden，继续成立：

- 未受信 adapter 不执行；
- adapter 无 raw socket、Node 模块、WebView controller 或原生 FFI；
- 所有请求经过宿主网络门；
- public 服务零凭证、无私密数据；
- fixture 不含真实学生数据；
- adapter 输出必须通过标准 schema；
- official bundle 绑定 exact digest、审核、签名和吊销。

---

## 6. 取舍与后果

### 6.1 收益

- 永久移除一整套私密服务端的安全、合规和运维责任；
- adapter 只有一个生产 runtime 和一套 SDK，开发心智显著简化；
- host API 不再为 Dart/TS 镜像实现和逐语义一致性所限制；
- CI 资源聚焦于客户端真实行为、fixture、schema、审核和发布供应链；
- 项目形态与 local-first、用户负责信任选择的 V2 原则一致。

### 6.2 代价

- 没有 VPN/official transport 时，校外私密数据可能不可用；
- 不再支持服务器定时刷新用户私密数据、后台聚合或推送；
- 客户端平台差异必须分别测试，不能借服务端结果替代；
- 部分现有 server runtime、共享 golden 和 CI 投入将成为迁移成本；
- fixture 无法证明未覆盖输入、真实网络时序或所有恶意分支，需要 official 审核和真机测试补充。

### 6.3 责任变化

- 项目维护者对 public 分发、客户端核心和 official 审核负责，不对用户自行部署的私密中继负责，因为 V2 不提供该组件；
- adapter 作者对目标客户端 runtime、fixture 完整性和学校流程负责；
- 用户对网络可达性、系统 VPN/local adapter 信任选择负责；
- official reviewer 不得用服务端 replay 代替客户端证据。

---

## 7. 被拒绝的方案

### 7.1 保留 campus stub，未来再说

拒绝。长期保留目录、接口和文档会持续制造“仍受支持”的暗示，诱导新功能依赖未维护组件，并要求 CI 和安全规则持续考虑第二条私密路径。

### 7.2 中继由学校自行部署，项目只提供代码

拒绝作为 V2 主仓能力。即使部署责任交给学校，项目仍需维护协议、升级、兼容、安全修复和数据责任边界。未来若有具名学校、明确维护主体和授权，可作为独立项目重新评估。

### 7.3 保留服务端 adapter runtime 作为“保险”

拒绝。只要它被视为生产备用，就必须继续维护行为兼容、凭证路径、回归和 incident response；这与删除双运行目标矛盾。

### 7.4 删除所有 golden 和 fixture

拒绝。取消双 runtime 等价承诺不等于取消确定性回归。fixture、schema、bundle、签名、URL policy 等测试仍直接保护 V2 产品和审核质量。

### 7.5 继续双跑，但允许结果偶尔不同

拒绝。没有明确一致性承诺的双产品 runtime 会产生无法裁定的故障和审核证据。V2 应明确单一生产权威，而不是维护模糊兼容。

---

## 8. 迁移计划

本 ADR 接受后按以下顺序实施：

1. 更新 ADR-000、AGENTS、architecture 和 V2 migration，删除 campus 与双跑的现行承诺；
2. 盘点 `server/src/campus`、服务端 adapter runtime、共享 golden、dual-run/canary 和 CI 消费关系；
3. 为每类 fixture 建立客户端目标 runtime replay 与 schema gate；
4. 将 official 审核证据切换到客户端 runtime 或真实平台构建；
5. 删除 campus stub、部署入口和专属测试；
6. 删除仅服务双跑的 server runtime 镜像和跨 runtime golden；
7. 保留或迁移具有独立价值的 URL、bundle、签名、schema、fixture 和纯工具测试；
8. 更新 CI required checks 和文档索引，记录实际 Landing 状态。

迁移期间旧测试可以作为 legacy baseline 保留，但不得新增依赖或扩展其契约。

---

## 9. 验收标准

本 ADR 的实现完成必须同时满足：

- 活跃架构和部署配置中不存在 campus relay 产品入口；
- public server 无 Credential Store、用户会话或私密 adapter 执行路径；
- adapter 文档只声明客户端生产 runtime；
- CI 不再声称 Dart/TS adapter runtime 等价；
- 每个 official capability 仍有脱敏 fixture、mock transport/response 和 expected schema 回归；
- schema、bundle、签名、network policy 等非双跑测试未被误删；
- official 发布证据包含目标客户端 runtime 测试；
- 旧 campus 与 dual-run 文档、实现和测试已删除或明确归档。

---

## 10. Owner 评审记录

2026-08-11 owner 接受本 ADR，并确认：

1. local unsigned adapter 只有在用户点击确认接受安装窗口、且确认绑定 exact digest 后才可首次执行；manifest 继续声明全部网络目标。
2. `server/src/campus` 直接删除，不保留 501 stub。
3. public server 不执行任何 adapter。
4. 客户端 runtime 对全平台使用同一契约，不按平台拆分 adapter；具体测试矩阵后议。
5. transport 基座继续存在，app-tunnel 属用户设备侧 official transport，不受删除 campus relay 影响。
6. `contract/golden/` 按 §4.7 逐文件处理，fixture/replay 长期保留。
