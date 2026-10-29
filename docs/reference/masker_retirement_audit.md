# Masker 退役审计与脚本格式边界

审计日期：2026-10-29。依据 [ADR-034](../adr/adr_034_trusted_school_scripts.md) 与 [ADR-035](../adr/adr_035_script_credential_identity.md)。这是当前代码和入库资产的审计记录，不是“已全部删除”的签收证明。

## 结论

**新 `elecon-script/1` 路径不依赖 Masker；全仓仍保留实际可执行的 V1 official 兼容链。** 不能把新路线完成表述为 Masker 已从客户端、服务端、工具和签名资产中完全消失。

新路径由 `SessionController.runTrustedScript` → `TrustedScriptRuntime` → `ScriptHttpTransport` / `ScriptBrowserBridge` 执行。其源码包 schema、SDK、打包 CLI 不要求 `masker.json`，不会调用旧 Broker 的凭据注入、声明式 dataflow 或 delivery firewall。SDK 2 的显式共享 namespace 也不是 Masker 或不透明句柄。

## 仍然在用的旧链

| 位置 | 实际依赖 | 删除前的配套工作 |
|---|---|---|
| [`session_controller.dart`](../../client/lib/session/session_controller.dart) 的 `runCapability` | 已安装脚本优先；没有本地 provider 时仍执行旧 `AdapterService` | 迁移或明确停用旧 provider，不能只删除其底层模块 |
| [`adapter_launcher.dart`](../../client/lib/core/adapter_launcher.dart) | `planLaunch` 从签名 bundle 读取、解析 `masker.json`；`runLoadedAdapter` 要求 Credential Store sink 并装配 policy | 同批修改 launch plan、service 入参和运行入口 |
| [`fetch_proxy.dart`](../../client/lib/core/broker/fetch_proxy.dart)、[`declarative_host.dart`](../../client/lib/core/declarative_host.dart)、旧 adapter runtime | 响应经规则选择及 delivery firewall，声明式与命令式均有接线 | 不能留下入口调用已删的投影/提交实现 |
| `client/lib/core/broker/{response_masker,masker_policy,masker_commit,delivery_firewall}.dart` | 当前客户端 Masker 引擎、匹配器和提交实现 | 与上游入口、测试一起退役 |
| [`server/src/runtime/sandbox.ts`](../../server/src/runtime/sandbox.ts) 及其 broker | official 路径仍在创建引擎前要求 policy/sink，响应继续经 TS Masker 镜像 | 服务端 runtime 和 fixture 回放的保留范围需一起调整 |
| [`server/build.mjs`](../../server/build.mjs) | 生产构建明确要求 `runtime/sandbox.js`；当前 tsconfig 仅排除测试，并未排除 runtime | 公网服务本身只分发静态字节，可先收窄生产产物；不要把“公网不执行”误写成“已无 runtime 文件” |
| [`tools/src/validator/index.ts`](../../tools/src/validator/index.ts) 与 `response-masker.ts` | 旧 official adapter 根目录必须带 Masker policy；仍执行 RM 规则 | 删除旧校验与旧 adapter 发行入口时同步调整 |
| [`tools/src/release/package.ts`](../../tools/src/release/package.ts) | 签名前调用旧 official validator，再打包、签名全部文件 | 新源码包 CLI 已独立；旧签发管线没有自动迁移 |
| [`tools/src/bundle/envelope.ts`](../../tools/src/bundle/envelope.ts) / 客户端旧 bundle parser | 固定 `elecon-bundle/3`，其既有语义含 Masker 运行门 | 若继续发行其他 official 格式，应显式定义新格式与兼容规则 |
| [`tools/src/release-ledger/index.ts`](../../tools/src/release-ledger/index.ts) | 提取已签 `masker.json` 的 SHA-256 到 policy 审计字段 | 历史台账保留真实签发事实，不改写过去的记录 |
| [`contract/response-masker.schema.json`](../../contract/response-masker.schema.json)、broker golden、对应 Dart/TS smoke | 仍约束旧生产入口 | 退役旧行为后同步移除对应 CI 门；新脚本回归继续保留 |

专属 Masker 的四个 Dart 模块、四个 TS 模块、validator 与 schema 在此快照约 3031 行，尚未计入接线、测试和文档。这个数字只说明维护面，不代表可以脱离调用链直接批量删除。

## 凭据冲突修复的范围

SDK 2 的新地址包含学校、namespace 和 key，独立脚本默认 namespace 为脚本 id，有意共享才显式选择同一 namespace。当前新机制的不同学校/namespace/同名 key 独立与显式共享已有回归。

旧 `CredentialStore` / `SecureStore` 仍以 raw ref 为物理索引，`schoolId` 只是条目字段；两个旧 V1 学校若都写同名旧 ref，旧链没有通用的双校共存命名保证。SDK 1 默认学校共享的查找行为也仅为预览兼容继续保留。`@legacy` 是 SDK 2 显式读取和迁移旧记录的入口，不表示已全量改造旧存储。

因此，本轮可以确认 SDK 2 新寻址的冲突隔离，不能声称全仓所有旧凭据冲突已经解决；这与仍保留 V1 执行链是同一个迁移边界。

## 当前签名资产

只读解包 `client/assets/bootstrap/bundles/*.bundle` 得到下表。五份均为 `elecon-bundle/3`，均含 `masker.json`，且当前规则数组都是空数组：

| Adapter | 版本 | Bundle digest 前缀 | Masker rules |
|---|---|---|---|
| school-xidian | 0.5.5 | `192434f0` | 0 |
| school-xjt | 0.2.0 | `3c5eaa23` | 0 |
| school-fudan | 0.2.0 | `62841684` | 0 |
| school-thu | 0.2.0 | `aceb2111` | 0 |
| school-helloworld | 0.2.0 | `e7db14c1` | 0 |

“规则为空”只描述这些入库字节，不代表旧运行入口不依赖 policy，也不代表将来取得的其他签名 bundle 都为空。文件路径、大小、哈希和 bundle format 已在原签名承诺内；就地删除签名文件里的 `masker.json` 会改变内容身份，原签名不能复用。

可以完整保留这些不可变历史资产并停止旧执行入口，或按新的发行决策生成新产物。不能伪造重签、签署者、复核记录或仪式时效。本次新脚本机制没有要求执行任何签名私钥操作。

## 完整退役的顺序

1. 将真实学校能力迁到普通 JS，或明确停用旧入口。旧源码不能直接不加转换地复制：西电通知仍依赖 declarative 的 `responses` 参数；旧 imperative 请求依赖 Broker 自动注入；西交挑战流程还使用 `setEphemeralCookie`。
2. 校本会话逻辑放进 JS/helper，完成脱敏 fixture 与真实客户端运行时回归。避免用另一个核心 DSL 替换旧 DSL。
3. 同批删除旧执行分派、Masker 引擎与接线，移除 TS 镜像、旧 validator 和专属测试/golden；保留新执行边界所需回归。
4. 更新 CI、发行文档、ADR 的旧路线兼容声明和产物清单。签名历史作为历史保留，不篡改。

在上述迁移完成前，直接删除 Masker 文件或让旧加载门静默忽略 policy，都不等价于完成路线迁移。

## SDK、版本与打包检查

包容器仍为 `elecon-script/1`；宿主分别识别 SDK 1 与 SDK 2，未知 SDK 拒绝。SDK 1 保留预览期凭据查找语义；SDK 2 采用 `(schoolId, namespace, key)` 描述符，新模板显式共享 `campus.session`。脚本自身 `version` 是独立的三段数字版本，与 SDK 或旧 bundle `/3` 不比较。

安装器要求显式内容 digest 授权；已安装同 id 只接受同学校的更高版本，相同版本异内容或降级拒绝。源码、权限或 SDK 改变均须提升脚本版本并重新确认。CLI 不猜版本、不执行源码、不签名，确定性打包并在失败时保留旧输出；npm workspace 参数相对用户原调用目录解析。

结构 schema 之外，CLI 已增加与宿主一致的精确 origin/端口、规范化重复 origin、IP/CIDR、名称和重复 capability 预检，避免已知的“打包成功、安装失败”。实际宿主仍在安装前重新验证内容身份、大小、格式和语义。

新 HTTP/browser 模板均为 SDK 2、版本 `0.2.0`。共享记录 `browser-cookies` 是按真实页面/API URL 分组的 JSON 快照：`{version:1, targets:[{url,cookies:[...]}]}`；不会把 Cookie 按 name 合并或将永久保存形式退化为一个 header。HTTP 仅对对应采集 origin/path 构造 header，检查 domain/path、Secure 和 expiry，已知长 path 优先；SameSite/HttpOnly 等元数据保留用于浏览器恢复。

部分 Android Cookie API 只返回 name/value，无法证明原始 Domain、Path、有效期或 SameSite。模板保留这些记录的采集 URL；未知 Domain 限制到采集 hostname，未知 Path 仅在采集业务路径使用和恢复。若原生平台缺少同名 Cookie 的范围信息，无法保证浏览器恢复为完全相同的 jar，仍可能需要用户重新登录；不会通过猜测属性宣称无损。回归使用实际模板源码与 fake ctx，不访问真实学校。
