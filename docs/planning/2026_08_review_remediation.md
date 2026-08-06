# 项目审查整改清单与修改路线（2026-08-05）

> 本文来自 2026-08-05 的全仓只读审查，是实施清单，不是 ADR，也不改变任何既有契约或安全决策。
> 涉及 `contract/`、签名、凭证、Broker、传输或信任模型的项目必须按 `docs/rules/feature_workflow.md` 走慢车道，并由人工完成安全复核。
> 状态约定：`[ ]` 未开始，`[x]` 已完成。关闭项目时必须同时满足“完成条件”，不能只以 smoke 通过为准。

## 1. 总体目标

整改顺序固定为：

1. 先阻断凭证泄漏、签名完整性和越界出网风险。
2. 再闭合签名加载、Broker、Masker、Credential Store、schema gate 等承重链。
3. 再修普通正确性问题和重复实现。
4. 再统一 ADR、README、发布输入和 CI 的状态源。
5. 最后恢复新 capability、多校、campus relay 和多平台扩展。

在 P0 和 P1 承重项关闭前，不建议继续扩大 actuator、body credential、material seed 或新学校的生产发布范围。

## 2. P0：安全与发版阻断

P0 整改 owner：**NanCunChild**。2026-08-05 执行分组如下；“跳过”表示必须先完成 ADR 修订或澄清，本轮不得修改实现。

| 执行组 | 项目 | 本轮处理 |
|---|---|---|
| A：既有 ADR 落地 | P0-02、P0-03、P0-04、P0-06、P0-07、P0-08、P0-11、P0-12、P0-13、P0-15 | 实施并提供验证证据；安全项由 NanCunChild 人工签收后关闭 |
| B：分段落地 | P0-10 | 先关闭现有入口绕过和取消后提交；handle、policy matcher、actuator 分别受 P1-08、P1-09、P1-12 前置约束，不虚假关闭 |
| C：ADR 阻塞，跳过 | P0-01、P0-05、P0-09、P0-14 | P0-01 需修订 ADR-002/018；P0-05 需修订 ADR-009；P0-09 需澄清 ADR-026 optional 语义；P0-14 landing 要求同步修订 ADR-002 |

实施顺序：日志与 fixture 止血（P0-11/12）→ 请求配额与 Cookie（P0-03/04）→ UI/硬件档/输出 gate（P0-02/06/07/08）→ firewall 现有入口（P0-10）→ ledger 与 release gate（P0-15/13）。P0-13 的 GitHub Environment 配置和 P0-15 的历史签署事实必须由 NanCunChild 提供或确认，不得由实现者猜测。

### 2.1 执行状态（2026-08-05）

| 状态 | 项目 | 结果 / 剩余门槛 |
|---|---|---|
| owner 已签收 | P0-02、P0-03、P0-04、P0-08、P0-11、P0-12 | 实现与自动化测试已完成；NanCunChild 于 2026-08-06 完成人工复核并授权关闭 |
| 待真机签收 | P0-06、P0-07 | iOS 已降级为 S/M 且 H 路径 fail-closed；Android 已用 `KeyInfo` 拒绝 software/unknown；仍需 iOS 升级安装及 Android emulator/TEE/StrongBox 矩阵 |
| 部分落地，保持开放 | P0-10 | TS 已阻止取消后 Commit；Dart 已有 firewall/commit 原语与严格 UTF-8 状态；生产 wiring 仍依赖已验签 policy loader/matcher、执行级 query harvest 事务、P1-08/P1-09/P1-12 |
| 待仓库/历史事实 | P0-13、P0-15 | reusable CI、main-only preflight、tag SHA/ancestry、审批 hook、真实验签 ledger 工具已落地；仍需配置 `release` Environment、不可变 `v*` tag 规则，并由 NanCunChild 提供历史 source commit/签署时间/签署人/复核引用 |
| ADR 阻塞，未改实现 | P0-01、P0-05、P0-09、P0-14 | 按 owner 指令跳过；先完成上表 C 组所列 ADR 修订或澄清 |

本轮自动验证：`npm run lint`、`npm run typecheck`、`npm run smoke:all`（server 26/26、tools 18/18）、`flutter analyze`、`flutter test`（744 项）、全量 scanner、release ledger smoke/validate、release preflight、recorder Python tests、`git diff --check`。自动验证不是安全签收的替代品。

| ID | TODO | 主要位置 | 车道与依据 | 完成条件 |
|---|---|---|---|---|
| P0-01 | [ ] 让 bundle digest 同时绑定规范化路径、编码、长度和内容，拒绝重复路径、绝对路径、反斜杠及 `.`/`..` | `tools/src/signer/index.ts`、`tools/src/bundle/envelope.ts` | 慢车道；签名格式，ADR-002/018 | TS/Dart 共用新 golden；只改路径必须验签失败；写明旧 bundle 迁移和 host version gate；人工签收 |
| P0-02 | [x] 从 UI 会话 API 移除完整 `CredentialStore`，只暴露登录状态、数量、ref、保护等级等元数据 | `client/lib/session/session_controller.dart`、`client/lib/core/credential/` | 慢车道；红线 #1、ADR-012 | UI 包无法取得 `CredentialEntry.value`/`ResolvedCredential.value`；Broker 仍可在核心内解析；边界测试通过；人工签收 |
| P0-03 | [x] 在每次 transport hop 出网前原子预留全局请求配额，修复并发 `ctx.fetch` 超限 | `server/src/runtime/sandbox.ts`、Dart 对应 runtime | 慢车道；Broker/网络边界，ADR-014/022 | 21/100 并发请求的第 21 个在出网前被拒；并发重定向共用配额；双端测试；人工复核 |
| P0-04 | [x] 正确建模 host-only Cookie，禁止无 `Domain` Cookie 发往子域 | `server/src/runtime/broker/cookie-jar.ts`、Dart 对应 Broker | 慢车道；红线 #1 | TS/Dart host-only golden 一致；子域负例零出网凭证；人工复核 |
| P0-05 | [ ] 安全策略阻止的重定向必须 fail-closed，不向 adapter 交付 3xx 中间 body/header | `server/src/runtime/broker/redirect.ts`、`fetch-proxy.ts`、Dart 对应实现 | 慢车道；红线 #1、ADR-009/020/026 | allow 外、超 hop、非法 Location 的 token body/header 均不可见；正常终态行为有 golden；人工复核 |
| P0-06 | [ ] 修正 iOS 硬件保护档：采用不可导出 Secure Enclave 密钥包装 DEK，或降级保护等级 | `client/ios/Runner/HardwareKeystorePlugin.swift`、`hardware_secure_store.dart` | 慢车道；ADR-012 | 真机证明密钥不可导出；若降级则显示 S/M 风险提示且不再标 H；人工安全签收 |
| P0-07 | [ ] Android 使用 `KeyInfo` 验证 StrongBox/TEE，软件 Keystore 不得标记为 H 档 | `client/android/app/src/main/kotlin/dev/nancunchild/elecon/HardwareKeystorePlugin.kt` | 慢车道；ADR-012 | 覆盖软件 provider、模拟器、TEE、StrongBox；每类保护等级符合 ADR；人工安全签收 |
| P0-08 | [x] 在客户端核心边界按已验签 manifest 的 `emits.schema/schemaVersion` 严格验证 adapter 输出 | `client/lib/core/adapter_runtime.dart`、`adapter_service.dart` | 慢车道；红线 #6、ADR-008 | 缺字段、错类型、错误 schemaVersion、畸形 item 整体拒绝；UI 不承担契约修复；生成类型/validator 单源 |
| P0-09 | [ ] Masker policy 改为已验签 bundle 的不可选运行时输入；要求 Masker 的 bundle 遗漏装配时拒载 | `server/src/runtime/sandbox.ts`、`fetch-proxy.ts`、Dart runtime | 慢车道；ADR-026 | policy、sink、store 或 host gate 任一缺失均不执行；不允许空规则透明回退；人工安全签收 |
| P0-10 | [ ] 完成 ADR-026 统一 delivery firewall：TS/Dart、declarative/imperative/actuator、Capture/Project/Commit 全入口收口 | `server/src/runtime/broker/delivery-firewall.ts`、`client/lib/core/broker/response_masker.dart` | 慢车道；ADR-026 | 所有响应入口不可绕过；credential 与 handle 事务提交完整；取消/失败无半提交；签收清单关闭 |
| P0-11 | [x] 永久禁止 debug 日志输出凭证 query、fragment、userinfo、Cookie 和 ticket URL | `client/lib/core/debug/dev_log.dart`、`dev_log_page.dart` | 慢车道；红线 #1 | 即使关闭普通脱敏，声明为 credential 的值仍不可见；控制台/UI/错误对象负例通过 |
| P0-12 | [x] 修复 fixture recorder 和探针的凭证落盘/日志风险 | `adapters_tests/XJT/dean/record_fixtures.py`、`XIDIAN/ids/login.py`、`XIDIAN/energy/meter.py` | 慢车道；红线 #1/#8 | 删除全部 Cookie/Set-Cookie；raw 只能写 `.private-probes/`；不打印 ticket URL/真实 NodeID；scanner 作为写后硬门 |
| P0-13 | [ ] 让 release workflow 复用完整 CI，不允许 tag 发布绕过 server/tools/contract/adapter/release gate | `.github/workflows/ci.yml`、`release.yml` | 慢车道；发布与信任链 | reusable workflow 覆盖 lint、typecheck、smoke、validator、scanner、codegen、Flutter、bootstrap、trust profile；tag ancestry 和环境审批有机械验证 |
| P0-14 | [ ] 完成 ADR-024 DEPLOY profile 接线和产物级证明 | `client/lib/core/trust/`、`client/tool/check_release_gate.sh`、release workflow | 慢车道；红线 #4、ADR-024 | release 产物无侧载符号；DEV applicationId/bundle ID 隔离；水印与构建元数据正确；人工签收 |
| P0-15 | [ ] 建立 git 跟踪的 adapter 发布台账 | `docs/reference/signing_ceremony.md`、`adapter_release.md`、新 ledger | 慢车道；ADR-002/018 | 每次发布记录 source commit、版本、bundle/policy digest、catalog/revocation sequence、keyId、签署人与复核引用 |

## 3. P1：核心正确性与契约闭环

| ID | TODO | 主要位置 | 前置 | 完成条件 |
|---|---|---|---|---|
| P1-01 | [ ] Credential Store 按用户、学校、ref 隔离，或用类型保证 store 单租户 | `client/lib/core/credential/`、`server/src/runtime/credential/` | P0-02 | 两校同名 ref 不覆盖；resolver 绑定执行上下文；迁移旧数据；人工复核 |
| P1-02 | [ ] 修复 H/S 持久化队列首次失败后永久中毒 | `software_secure_store.dart`、`hardware_secure_store.dart` | 无 | 首写失败后后写可恢复；durability failure 可见；无静默内存成功 |
| P1-03 | [ ] 登出改为等待 `delete + flush` 的异步事务 | `session_controller.dart`、`settings_page.dart` | P1-02 | 删除未落盘时不得显示完成；失败有安全错误；立即重启不恢复旧凭证 |
| P1-04 | [ ] 保留重复响应头的原始多值语义，Masker 基数检查发生在折叠前 | `server/src/runtime/transport/direct.ts`、Dart transport、Masker | P0-09 | 两个同名 token header 触发 ambiguous fail-closed；双端真实 HTTP 测试 |
| P1-05 | [ ] 修复同名不同 Path Cookie 的选择与排序 | `server/src/runtime/broker/cookie-jar.ts`、Dart 对应实现 | P0-04 | `/` 与 `/api` 同名 Cookie 行为符合明确策略/RFC；双端 golden |
| P1-06 | [ ] 补齐 Cookie 的 Secure、Max-Age、Expires 和删除语义 | TS/Dart CookieJar | P0-04 | HTTPS/HTTP、过期、`Max-Age=0`、覆盖删除均有共享 golden |
| P1-07 | [ ] Transport 解压 body 后清理或重算 `Content-Encoding/Content-Length` | `server/src/runtime/transport/direct.ts`、Dart transport | 无 | gzip/br 响应交给 adapter 时 body 与实体头一致；双端测试 |
| P1-08 | [ ] Masker 支持并事务提交 `destination.kind: handle` | TS/Dart Response Masker 与 dataflow runtime | P0-10 | staged handle 与 credential 同事务；失败不激活旧/半成品 generation；共享 golden |
| P1-09 | [ ] ADR-026 policy 按最终 URL、status、Content-Type 匹配并合并多条规则 | `contract/response-masker.schema.json`、validator、runtime | P0-09；需按 ADR-026 慢车道 | schema、validator、TS/Dart runtime 一致；host gate 生效；人工签收 |
| P1-10 | [ ] 落地 ADR-031 `seed`、`material`、D17-D21 和 hydrate 边界 | manifest、validator、TS/Dart dataflow、Credential Store | P0-10；ADR-031 | material 只进入句柄空间、不走 HTTP 注入；预算/缺失/failure 测试；人工签收 |
| P1-11 | [ ] 落地 ADR-029 固定 body 模板和受限 body credential inject | manifest、validator、TS/Dart Broker | P0-10、P1-10；ADR-029 | 仅固定字段/模板可注入；adapter 不见值；重定向与日志规则闭合；人工签收 |
| P1-12 | [ ] 完成 ADR-030 actuator 统一副作用闸门 | contract registry、Broker、UI action entry | P0-10、P1-11；ADR-030 | 仅用户手势触发；禁自动重试；状态未知语义；固定 endpoint；审计与人工签收 |
| P1-13 | [ ] manifest validator 强制 `requests[].key` 唯一，runtime 纵深拒绝重复 key | `contract/manifest.schema.json`、`tools/src/validator/`、TS/Dart runtime | 需确认是否仅 validator bugfix或契约增补 | 重复 key 在签发前和运行时都失败；bind/Masker 负例覆盖 |
| P1-14 | [ ] registry 有 params 时，manifest 必须声明完全一致的 params binding | `tools/src/validator/index.ts` | 无 | 缺 params、错 schema、额外 params 均硬错误；template 回归通过 |
| P1-15 | [ ] 分层关闭 manifest 安全面未知字段 | `contract/manifest.schema.json` | 慢车道；需兼容性方案 | 已删除 `mode`、拼错字段和未知安全声明均失败；旧 bundle 迁移策略明确 |
| P1-16 | [ ] 修正 declarative/imperative 模板的 `gradePoint:null` 和未知课程类型映射 | `adapters/_template/*/index.js` | P0-08 | 可选字段缺失时省略；未知类别为 `unknown`；真实 replay+schema+golden 通过 |
| P1-17 | [ ] 建立真正的 adapter fixture replay 门，而不是只校验 expected JSON | `tools/src/validator/`、adapter fixtures | P0-08 | replay 请求/dataflow/handler 后逐字段比较 expected 并校验 schema；输入链缺失会失败 |
| P1-18 | [ ] 修复 external adapter 根环境变量不一致 | `scripts/fetch-adapters.sh`、`tools/src/validator/index.ts`、CI | 无 | CI 输出实际扫描目录和 adapter 数量；pinned adapters 全量 validator 确实运行 |
| P1-19 | [ ] adapter discovery 排除 `graphify-out`、缓存和非 adapter manifest | `tools/src/validator/index.ts` | 无 | 本地 graphify 后全量 validator 不误扫；只识别合法 adapter 根 |
| P1-20 | [ ] 修复 `adapters_tests/XIDIAN/jwc/std` 的 entry、schemaVersion、日期和手写校验器漂移 | 对应 manifest/index/run | P0-08 | 使用标准 fixture/replay；坏日期省略；UTC 归一；validator 零错误 |

## 4. P2：普通逻辑、解耦与可维护性

| ID | TODO | 主要位置 | 完成条件 |
|---|---|---|---|
| P2-01 | [ ] 启动页显式处理 bootstrap Future 异常并支持安全重试 | `client/lib/main.dart` | 启动失败不进入半初始化主页；损坏存储恢复路径有测试 |
| P2-02 | [ ] 首页刷新 Future 等待真实请求完成并处理重复刷新代次 | `client/lib/ui/home/home_page.dart` | spinner 生命周期正确；旧请求结果不覆盖新请求 |
| P2-03 | [ ] GPA 排除非正学分并处理零分母 | `client/lib/ui/home/home_page.dart` | 零学分不显示 `NaN`；单元/widget 测试覆盖 |
| P2-04 | [ ] 公网 handler 捕获畸形百分号编码并返回 400 | `server/src/public/index.ts` | `/%`、非法 UTF-8 不抛出 handler；进程保持可用 |
| P2-05 | [ ] 公网静态端点只允许 catalog、revocation 和合法 digest bundle 路径 | `server/src/public/index.ts`、nginx 配置 | 任意 dist 文件不自动公开；bundle 名称/大小/method 有硬限制 |
| P2-06 | [ ] 抽取共享 JSONPath tokenizer/AST，消除 dataflow 与 Masker 语义漂移 | `server/src/runtime/broker/dataflow.ts`、`response-masker.ts`、Dart 对应实现 | 安全整数、转义、错误分类共享 golden；不保留平行 parser |
| P2-07 | [ ] 抽取版本化 Credential codec 和可靠持久化队列 | H/S secure store | H/S 仅负责 DEK custody；序列化、迁移、损坏处理单源 |
| P2-08 | [ ] 使用生成契约类型替代客户端手写 manifest/credential 枚举解析 | `client/lib/catalog/schools.dart`、loader | 新 credential/schema 类型不需多处手工同步；unknown 处理明确 |
| P2-09 | [ ] 为 `AdapterService` 增加所有权清晰的 `dispose/close` | `client/lib/core/adapter_service.dart`、transport/fetcher | SessionController dispose 后 HttpClient/socket 释放；测试验证 |
| P2-10 | [ ] 将 server smoke/replay/testutils 从生产源码和 build 产物分离 | `server/src/runtime/*.smoke.ts`、`tsconfig.json` | `npm run build` 不产出测试入口；测试命令保持可用 |
| P2-11 | [ ] 将所有用户可见文案迁到 ARB，并加入 UI 字面量静态门 | `client/lib/ui/`、l10n | 英文 locale 下首页、登录、安全警告无中文残留；CI 可阻止新增字面量 |
| P2-12 | [ ] 修正 Linux 支持矩阵或提供可信登录路径 | `client/lib/ui/login/login_flow.dart`、发布文档 | 若不支持认证则从正式能力矩阵排除；若支持则有平台集成测试 |
| P2-13 | [ ] 处理 OHOS pubspec 漂移，区分 probe 与正式构建清单 | `client/pubspec.ohos.yaml` | release 不会误用旧 QJS/缺依赖清单；CI 至少解析/最小编译正式清单 |
| P2-14 | [ ] 统一 XJT/XJTU 命名及 adapter_tests 元数据 | `adapters_tests/` | 每目录说明 schoolId、系统、状态、敏感度和是否仍使用 |
| P2-15 | [ ] 更新 adapter SDK 为最小 `BrokerResponse`，移除鼓励 adapter 自取 token 的旧说明 | `contract/adapter-sdk/types.d.ts` | 不暴露完整 DOM Response/url；ADR-026 目标态清楚；契约改动走慢车道 |

## 5. P3：文档、CI、发布与运维

| ID | TODO | 完成条件 |
|---|---|---|
| P3-01 | [ ] 建立 ADR 索引，分别记录 Decision、Landing、Security signoff、Owner、Blocker | README 不再把 Accepted 误写成 Implemented；ADR-013/023/024/026-031 状态一致 |
| P3-02 | [ ] 更新或归档旧 `docs/architecture.md` 分支快照 | 不再描述旧 adapter 布局、stripEchoes 或过时 ADR 状态；明确代码事实与 ADR 约束关系 |
| P3-03 | [ ] 更新 README、adapter README、testing rule 和旧 TODO | 修正模板复制命令、“越薄”两轴含义、外部 adapter fixture 路径和 ADR 状态 |
| P3-04 | [ ] 为 35 处 schema 字段补 description，并把 `--require-descriptions` 设为 CI 硬门 | codegen check 零缺失；时间、金额、窗口和缺失语义有文档 |
| P3-05 | [ ] 统一 Money 字段语义，确认哪些域允许负数 | 非负金额有 `minimum:0`；例外有领域说明；ADR-021 状态明确 |
| P3-06 | [ ] 将 schema behavior golden 从 7/48 扩展到所有 registry emits/params | 覆盖嵌套 required、enum、format、null/缺失、金额、URI 和 params 边界 |
| P3-07 | [ ] 明确 canonical dist，消除 `dist-full`、`dist-xidian`、bootstrap 和 release 多事实源 | CI 检查实际发布 dist 与 bootstrap 字节一致；不再依赖人工记忆 |
| P3-08 | [ ] 在发版门检查 revocation 新鲜度与 catalog/revocation sequence 单调性 | 过期或倒退时禁止 release；急性吊销流程可演练 |
| P3-09 | [ ] 修复应用内版本注入 | release tag 与 About 页面一致；构建命令传入 `ELECON_VERSION` 或改用可靠平台版本源 |
| P3-10 | [ ] 固定 release Flutter 版本，与普通 CI 使用同一 SDK | release 不再使用浮动 `stable`；升级单独评审 |
| P3-11 | [ ] 提交并审查 Windows/macOS 平台工程，禁止 release 临时 `flutter create` | runner、标识、entitlement 可复现且进入代码审查 |
| P3-12 | [ ] 增加依赖、许可证、SBOM、secret scanning 和 SAST 门 | npm/pub/镜像依赖均覆盖；GPL/未知许可证阻断；安全结果可追踪 |
| P3-13 | [ ] 增加 release checksum、provenance、签名和人工批准 | 各平台产物身份可验证；unsigned 工件不伪装成正式发布 |
| P3-14 | [ ] 发布正式隐私政策、数据处理说明和安全联系渠道 | App 内链接有效；说明凭证、WebView、日志、删除和第三方 SDK |
| P3-15 | [ ] 完善公网端点部署和运维 | 镜像 pin/扫描、非 root、原子发布、回滚、TLS/CDN/DNS、监控和吊销新鲜度告警齐全 |
| P3-16 | [ ] 为 campus relay 起草专项 ADR，替换“等待 ADR-003”的过时 blocker | 明确授权、协议、凭证一次性投递、状态和部署边界后才实现 |
| P3-17 | [ ] 将 `widget_test.dart` 占位替换为启动、选校、登录、首页错误态集成测试 | 关键用户流程在至少 Android 模拟器形成门禁 |
| P3-18 | [ ] 将 QuickJS 文案改为“共享 golden 控制已使用语义漂移” | 不再宣称两种绑定在所有行为上天然零漂移 |

## 6. P4：产品与扩展性

| ID | TODO | 前置 | 完成条件 |
|---|---|---|---|
| P4-01 | [ ] 设计动态学校目录或明确受控内置目录策略 | P0/P1 承重项 | 新学校是否需要客户端发版有明确答案；涉及契约则先 ADR |
| P4-02 | [ ] 用 capability 级 `credentialRefs` 收窄 imperative 最小权限 | 独立 ADR；P0-09/P0-10 | capability 只能使用显式授权 ref；redirect/harvest 同步约束；旧 host 迁移明确 |
| P4-03 | [ ] 为课表、成绩、考试、空教室、一卡通、图书馆完成 UI 闭环 | P0-08、对应 adapter 正式签发 | loading/empty/stale/error/unsupported 四态清楚；schema 驱动而非学校硬编码 |
| P4-04 | [ ] 至少完成一个非 Xidian 学校的产品闭环 | P4-01、P4-03 | 登录、取数、schema gate、UI、fixture、签发和真机验收完整 |
| P4-05 | [ ] 明确 freshness/TTL、刷新和离线陈旧数据的用户语义 | P4-03 | UI 清楚区分最新、缓存、陈旧、失败和不支持 |
| P4-06 | [ ] 设计无凭证 telemetry/error reporting | P0-11 | 任何 URL/header/body/error 均经过永久脱敏；用户可关闭；隐私政策同步 |
| P4-07 | [ ] campus relay 在专项 ADR 接受后实现最小授权链 | P3-16 | 公网零凭证；私密数据只在校内授权环境；集成和部署安全测试完整 |

## 7. 推荐修改路线

### 阶段 R0：冻结与基线（1 个 PR）

目标：让后续整改可追踪，不改变运行行为。

1. 合入本清单并为 P0/P1 建立 issue/owner。
2. 建立 ADR landing status 索引骨架。
3. 固定当前测试基线、外部 adapter commit 和发布输入摘要。
4. 暂停新增 actuator、body credential、material seed 和新正式 bundle。

退出条件：每个 P0/P1 项都有 owner、目标 ADR、PR 边界和人工复核人。

### 阶段 R1：无契约止血（多个小 PR，可部分并行）

建议批次：

1. 探针/fixture/log 永久脱敏：P0-11、P0-12。
2. public URL 异常与路径 allowlist：P2-04、P2-05。
3. CI adapter 根和 discovery：P1-18、P1-19。
4. 启动、刷新、GPA、资源释放：P2-01、P2-02、P2-03、P2-09。
5. 持久化队列恢复：P1-02；登出事务 P1-03 紧随其后。

退出条件：已知直接泄漏路径关闭；普通错误不再干扰后续安全迁移；不改 contract。

### 阶段 R2：签名完整性迁移（独立安全项目）

顺序：

1. 修订 ADR-002/018，定义 bundle digest v2、路径规范化和兼容策略。
2. 先实现 TS/Dart verifier 与 golden，再实现 signer/packer。
3. 增加 host version gate，重新签发 bootstrap/catalog/bundle。
4. 增加 P0-15 发布台账和 release 防回滚检查。
5. 由非实现者完成人工安全复核和迁移演练。

退出条件：P0-01、P0-15 关闭；旧产物处理方式明确；只改路径必然验签失败。

### 阶段 R3：凭证隔离与存储（独立安全项目）

顺序：

1. 收窄 UI API：P0-02。
2. 落实 store scope 与旧数据迁移：P1-01。
3. 修复 Android/iOS 保护等级：P0-06、P0-07。
4. 完成登出、失败恢复、重启和真机测试：P1-02、P1-03。

退出条件：UI 无法取得明文；跨校不混用；H 档有真机证据；登出具备持久化完成语义。

### 阶段 R4：Broker 网络与交付边界（独立安全项目）

顺序：

1. 请求配额和 redirect fail-closed：P0-03、P0-05。
2. Cookie host-only、Path、过期语义：P0-04、P1-05、P1-06。
3. 原始响应头和解压实体头：P1-04、P1-07。
4. Masker 不可选装配和最终响应 policy match：P0-09、P1-09。
5. 统一 firewall 与 handle transaction：P0-10、P1-08。
6. 最后接客户端生产 schema gate：P0-08。

退出条件：任何响应进入 adapter/UI 前都经过不可绕过的安全与 schema 边界；失败、取消、并发无半提交或迟到副作用。

### 阶段 R5：契约能力补齐（严格串行）

顺序：

1. 先关闭 manifest 基础歧义：P1-13、P1-14、P1-15。
2. 再落 ADR-031 seed/material：P1-10。
3. 再落 ADR-029 body inject：P1-11。
4. 最后落 ADR-030 actuator：P1-12。
5. capability 级 `credentialRefs` 作为独立 ADR/PR：P4-02，不与上述改动捆绑。

退出条件：每一项都有 schema、validator、TS、Dart、共享 golden、host gate 和人工签收；不得一次 PR 同时改多个承重能力。

### 阶段 R6：去重、测试和文档收敛

顺序：

1. 抽取 JSONPath、Credential codec、生成类型：P2-06、P2-07、P2-08。
2. 修复模板、fixture replay 和 std adapter：P1-16、P1-17、P1-20。
3. 扩 schema golden 和 descriptions：P3-04、P3-05、P3-06。
4. 分离生产/测试源码并补 widget/integration：P2-10、P3-17。
5. 统一 README、ADR index、architecture 和旧 TODO：P3-01、P3-02、P3-03、P3-18。

退出条件：契约解析、JSONPath、Credential codec 不再有平行实现；文档能区分决策与落地状态。

### 阶段 R7：发布和运维闭环

顺序：

1. reusable release verification 与 ADR-024 gate：P0-13、P0-14。
2. canonical dist、bootstrap 和 revocation：P3-07、P3-08。
3. 版本/SDK/平台工程可复现：P3-09、P3-10、P3-11。
4. 供应链、签名、provenance、隐私：P3-12、P3-13、P3-14。
5. 公网部署、监控和回滚：P3-15。

退出条件：tag 不能绕过完整验证；发布产物、adapter bundle、bootstrap、catalog 和 revocation 均可追溯、可验证、可回滚。

### 阶段 R8：恢复产品扩展

顺序：P4-01 动态学校目录 → P4-03 现有能力 UI → P4-04 第二所学校 → P4-05 freshness → P4-07 campus relay。P4-06 telemetry 可在隐私政策完成后独立推进。

退出条件：至少两所学校形成签名 adapter、登录、取数、schema gate、UI 和真机验收的完整闭环。

## 8. PR 拆分原则

1. 一个 PR 只关闭一个安全语义或一个普通问题簇，不把签名、凭证、Masker、contract 混在一起。
2. 安全 PR 必须先列攻击/失败场景，再写实现；测试由人工实质性复核，AI 不得独自闭环。
3. 契约 PR 必须说明旧 host、旧 bundle、旧持久化数据和 rollback 行为。
4. 双端功能的完成定义包含 TS、Dart、共享 golden 和至少一个集成入口，不能只完成参考执行器。
5. 所有 fixture 必须先脱敏再入库；scanner 通过不是人工隐私复核的替代品。
6. 文档状态使用 Decision 与 Landing 两个维度，不再用单个“已接受”暗示实现完成。

## 9. 每阶段统一验证门

每个阶段至少运行：

```text
npm run lint
npm run typecheck
npm run smoke:all
flutter analyze
flutter test
```

涉及 adapter/contract/release 时另运行全量 validator、PII scanner、codegen drift、description gate、bootstrap drift 和真实 external adapters replay。涉及硬件保护、WebView 登录、URL query credential 或 actuator 时，必须增加脱敏测试账号的 Android/iOS 真机验收，真实凭证和学生数据不得写入 fixture 或日志。
