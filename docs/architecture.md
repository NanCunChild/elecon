# Elecon 当前架构

学校差异由用户安装的受信 JavaScript 扩展实现；核心提供跨学校的执行、身份、网络、存储、认证输入和展示基底。脚本作者使用普通 ES 模块、异步函数与异常，学校协议和交互流程不进入核心。

本文是现行架构的唯一维护入口。作者从 [Wiki](wiki/README.md) 开始，接口字段以 [SDK 类型](../contract/script-sdk/types.d.ts)、[包 schema](../contract/script-package.schema.json)和[领域契约](../contract/schema/)为准；实施状态见[统一计划](planning/implementation.md)。[ADR 索引](adr/README.md)用于追溯决策原因，不要求逐篇阅读。

## 模块与职责

```mermaid
flowchart TD
  Trigger[原生页面 / 卡片 / 工作台] --> Session[会话：来源、身份、交互模式、取消]
  Session --> Host[宿主：授权字节、网络、资源、结构化结果]
  Host --> Script[QuickJS：普通 ES 模块与异步函数]
  Script --> Ports[HTTP / 浏览器 / 凭据 / 原生输入]
  Ports --> School[学校系统]
  Script --> Contract[标准业务数据与 schema 校验]
  Contract --> Trigger
```

| 模块 | 核心责任 | 脚本责任 | 实现入口 |
|---|---|---|---|
| 安装与来源 | 审查包内容、学校和网络范围；保存批准 digest；更新重新确认；逐能力来源及显式覆盖 | 声明能力、资源、账号与运行需要；普通模块函数只在必要时注册成宿主入口 | [scripts](../client/lib/core/scripts/)、[打包器](../tools/src/script/package.ts) |
| 调用与生命周期 | 校验来源、参数、身份和取消；处理交互、错误、输出及资源回收 | `capabilities[id](ctx, params)` 返回标准数据或抛异常；辅助函数保持普通 JS | [script_session](../client/lib/session/script_session.dart)、[runtime](../client/lib/core/scripts/runtime.dart)、[查询门面](../client/lib/session/capability_query.dart) |
| 身份、凭据与认证 | Profile 隔离、受保护存储、账号页面、短期输入与恢复额度；主密钥不离开宿主 | 学校 SSO、Cookie/token、母子票据、登录成功验证与学校错误判定 | [credentials](../client/lib/core/scripts/credentials.dart)、[account_auth](../client/lib/core/scripts/account_auth.dart)、[账号手册](wiki/accounts.md) |
| HTTP、WSS、浏览器与隧道 | 声明网络范围、DNS/TLS、跳转、预算和取消；Hermes 原生传输与独立秘密；浏览器容器 | URL、协议、签名、请求体、DOM 和业务成功条件 | [transport](../client/lib/core/transport/)、[browser](../client/lib/core/scripts/browser.dart)、[浏览器手册](wiki/browser.md) |
| 标准业务数据 | 时间、单位、缺失值、实体身份、版本和输出校验；可共享的原生领域组件 | 把学校数据归一为约定含义；网页局部状态无需进入全局 schema | [contract](../contract/)、[解码器](../client/lib/ui/home/decoders/)、[学校源码](../school-scripts/) |
| 页面、首页与缓存 | 原生路由、输入、卡片布局和用户选择；缓存固定身份、来源 digest、参数、语言与原始时间 | 文案、查询条件和已有展示建议；不把业务流程编码成 Widget tree | [home](../client/lib/ui/home/)、[卡片手册](wiki/cards.md)、[交互手册](wiki/interactions.md) |

## 作者运行环境

普通 ES 模块经过构建打包为受信源码，在背景 QuickJS isolate 运行。模块和函数边界不引入新的流程语言；包版本、SDK 版本、业务 schema 版本分别管理。只有跨宿主调用的入口需要注册，内部认证步骤、工具函数和网页事件使用普通 JS。

[ADR-081](adr/adr_081_script_runtime_consolidation.md) 收敛 SDK17 的请求/响应、取消与错误协议，专有端口集中到 `elecon` 命名空间；旧 `ctx` 与 SDK1–16 保持其版本语义。标准 API 的实际支持范围、生命周期和不支持项只维护在[SDK 手册](wiki/sdk-and-host.md)，不将标准形状等同于完整浏览器或 Node 环境。

运行错误以稳定分类跨宿主传递，JS 继续使用 `throw`、`try/catch` 和 `Error`。业务码和宿主分类分开；宿主桥不再通过异常显示文字判定错误。学校侧旧认证封装的 message 分支迁移仍见统一计划。取消、资源超限、认证需要交互和业务失败不能相互冒充。恢复策略由调用层与学校流程明确实施，错误本身不授权重试。

## 执行与身份边界

- 执行字节必须匹配批准 digest。来源更新、禁用、退出和切身份使旧执行及迟到结果失效；显示来源或卡片不授予执行权限。
- 当前学校受信脚本可处理其授权凭据；UI 不取得完整凭据库或主密钥。namespace 是寻址与 API 组织方式，同校共享须显式寻址，不是包间最小权限沙箱。
- 宿主不开放任意文件、进程、FFI、raw socket 或原生模块侧载。公网静态分发不持凭据或私密数据；校内部署位置本身不产生共享授权。
- 用户按钮发起普通请求，无另一个 action 通道或逐次额外确认。展示、预加载和缓存恢复不能发起写操作；发送结果未知时不自动重放。
- 只读查询可按明确学校认证证据恢复；验证码、MFA、网络失败和合法无权限不等于密码错误。成功登录仍须验证目标业务会话。
- 显式声明的账号登录先清除当前学校所有包的业务查询缓存并等待持久化，再执行学校登录；清理失败不执行登录，取消或拒绝登录不恢复旧快照。业务数据代际同时使旧页面结果和排队查询失效，与登录窗口的执行代际分开。同校凭据及其他学校缓存不因这一步清除；普通查询内的票据续期不触发此清理。

## 已有产品能力及限制

原生领域组件覆盖课表、成绩、考试、空教室、通知、校园卡、借阅、水电、空调、电话黄页与教师检索等；具体学校是否支持以安装包声明及源站验证为准。SDK12 同型卡片实例固定来源，默认能力覆盖独立保存；更新不抢占用户布局。成绩学期与教室筛选、课表缓存和时间轴复用共性组件。[ADR-082](adr/adr_082_script_query_forms.md) 的 query.controls 2.0 由脚本创建有类型的字段实例，核心不预置学校业务筛选清单；独立 filters 参数、动态依赖与旧 1.0 表单分别维护。[ADR-083](adr/adr_083_deferred_query_fields.md) 的 2.1 可选字段按依赖延迟解析，基础查询不等待补充；静态目录、学校时间和选项取数策略仍由脚本负责。

账号声明支持独立服务与同包登录/状态入口；保存密码先验证再替换。SDK16 可声明 Hermes 网关账号和逐能力依赖，不满足依赖时停止，不直连回退；普通 WebView 尚未接入 APPTunnel。当前包内网页是 Android 离线 HTML 与固定 DOM 操作模式，作者网页 JS/直接网络仍关闭；这描述旧模式的实现，不是扩展目标的永久限制。

消息已有会话、群/私聊历史及一次文本发送，受保护 SQLite 由核心托管；论坛帖子、未读、附件操作及推送尚未实现。系统 AI 为四个具名只读 AppFunctions，当前身份逐次授权，不提供任意脚本执行口。[ADR-085](adr/adr_085_feature_shortcuts.md) 的 Android 快捷方式及 App Actions 另提供固定原生功能的页面入口，经过正常恢复、选校与来源绑定，不授予 AI 数据读取或控制权限。原生权限、平台支持和真实服务验收不能从 schema 存在推断。

## 已接受的扩展目标

[ADR-080](adr/adr_080_trusted_script_extensibility.md) 接受长期 WebView JS、自绘按钮/框图、全部能力首页入口、脚本决定使用的独立验证码/MFA 界面，以及用户启用后自动执行的定时任务。一次调用、长期网页会话和持久计划分别管理生命周期，复用同一调用语义；不能通过无限延长短请求超时实现全部目标。

远端增强须兑现网页网络范围、桥接来源与取消，依赖隧道时不能直连。自动化须记录时间窗口、错过、认证等待和未知结果，不能承诺所有平台锁屏或退出后精确执行。上述接口的实施状态与验证条件只维护在[统一计划](planning/implementation.md#受信扩展)。

## 兼容、发布与证据

仍有消费者的 V1 official/Broker/Masker 路径按[兼容维护边界](reference/legacy_compatibility.md)维护；不为它扩充学校 DSL。可以完整退役旧调用链，但文档归档不等于删除运行代码或保护。`server/src/public` 是零凭据静态分发，`server/src/campus` 仍是 stub，没有新源码服务端生产执行器。

架构或契约含义变化记录整体决定；普通实现拆分和已有决定覆盖的功能不另造 ADR。当前开发阶段可显式升版破坏性更新，不能无声改变旧字段。依[功能工作流](rules/feature_workflow.md)和[测试规则](rules/testing.md)验证实际改动；代码、自动测试、平台真机、学校验证与人工审阅分别记录。历史实现流水见[收敛快照](archived/2026-11-04/README.md)。
