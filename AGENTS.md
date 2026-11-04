# AGENTS.md · elecon 开发总则

> 当前基线：2026-11-04（ADR-081 统一运行模型与文档收敛；ADR-080 扩展按切片实施）。修改前先读本文、[当前架构](docs/architecture.md)及相关 [rules](docs/rules/)。旧总则已[归档并废弃](docs/archived/2026-10-31/AGENTS.pre-2026-10-31.md)，不再要求先读 ADR-000。

elecon 面向学生聚合校园服务。学校差异集中在可更新的受信学校脚本；宿主负责执行授权、身份与网络边界、标准契约、原生页面与可编程网页容器。核心提供跨学校共性基底，学校交互与自动化策略尽量留在受信脚本。优先减少学校变更波及面与长期维护负担。现行规则集中在[当前架构](docs/architecture.md)，决策原因按需查 [ADR 索引](docs/adr/README.md)，无需逐篇阅读历史 ADR。

## 1. 现行边界

以下使用 B1–B10 新编号。代码和历史 ADR 中的“红线 #n”仍指[旧总则编号](docs/reference/legacy_compatibility.md#历史红线编号)，不可按下面的位置重解释。


**B1. 执行授权**：`elecon-script/1` 允许未签名源码，经用户检查包内容、学校身份、网络范围后安装；更新重新确认，实际执行字节必须匹配授权 digest。包版本、SDK 版本和数据 schema 版本分别裁定。

**B2. 凭据与身份**：受信学校脚本可处理当前授权学校身份的凭据；UI 不取得完整凭据库、主密钥，脚本不得跨学校/未授权身份访问。SDK 2 namespace 是寻址而非权限隔离，同校受信脚本可显式共享；不能声称现有增强包拥有独立的最小权限沙箱。

**B3. 公网边界**：公网服务不持凭据、私密数据不经公共中继。现有 `server/src/public` 是零凭据静态分发服务；公开业务缓存是独立待实施服务。校内授权中继仍是 stub，部署位置本身不产生查询或共享数据的授权。

**B4. 宿主能力**：学校认证、请求、签名和 DOM 编排留在脚本；宿主约束声明的网络范围、身份、取消与资源预算，不开放任意文件、进程、FFI、raw socket 或原生模块侧载。宿主侧脚本在背景 isolate，UI 异步；[ADR-080](docs/adr/adr_080_trusted_script_extensibility.md) 接受 WebView 内作者 JS、长期会话与自动化方向，按独立生命周期和资源策略实施，不以短请求预算永久限制扩展。

**B5. 契约含义**：输入、输出、单位、时间、缺失值、副作用和实体身份必须明确。`contract/` 或核心抽象变更先有覆盖该变化的 ADR；已有决定覆盖的实现拆分不另建 ADR；当前开发阶段允许明确版本与迁移方案的破坏性更新，不能无声重解释已有字段。公测稳定后的兼容政策由人工决定。

**B6. 页面与操作**：客户端拥有原生布局、路由和网页容器；脚本提供标准数据，也可在新网页模式内用 JS 自绘交互，不下发 Flutter Widget tree。[ADR-080](docs/adr/adr_080_trusted_script_extensibility.md) 接受全部能力首页入口、用户启用的定时自动操作及脚本决定使用的验证码/MFA 独立界面；接口未实施前沿用旧 SDK 行为。新受信脚本按 [ADR-046](docs/adr/adr_046_triggered_script_requests.md) 使用通用请求，不另设 action 或逐次额外确认；展示、预加载和缓存恢复不触发命令，未知结果不自动重发。自动化由明确启用的计划触发，不能借刷新隐式执行。V1 的命令确认与平台门按兼容边界维护。

**B7. 旧路径隔离**：未迁移 V1 official bundle 继续验签、身份绑定、吊销和 Broker/Masker 保护；新源码安装授权不替代旧验签，旧 C3/official-only 也不阻塞新脚本。不再为旧 DSL 扩充学校协议算子。详见[兼容维护边界](docs/reference/legacy_compatibility.md)。

**B8. 证据与数据**：夹具必须合成或脱敏，不提交真实学生数据、凭据或设备标识；不把自动测试、研究方案或文档状态当作真实学校验收、人工安全签收或上线证据。

**B9. 依赖与许可**：新增依赖声明来源、用途和许可证；GPL 系组件先确定适用的模块/进程隔离与分发边界，不顺手引入。

**B10. 人工责任**：架构变化先写 ADR，代码按已授权范围推进；核心、凭据、网络、控制和签名的实现仍需人工实质审阅后合并。无需为已授权的研究、文档整理或已有 ADR 覆盖的工作重复索要许可。

## 2. 工作方式

- 先查状态和现有代码，再修改；保留工作区已有改动，只提交本次任务内容。
- 单一目的、分步 commit，遵循 [Git 规则](docs/rules/git.md)。AI 辅助提交写 `Assisted-by: Codex`；用户指定不签名时用 `git -c commit.gpgsign=false commit --no-gpg-sign`。
- 依改动使用 [功能工作流](docs/rules/feature_workflow.md)、[测试规则](docs/rules/testing.md)、[AI 自检](docs/rules/ai_coding.md)、[UI 规则](docs/rules/ui_ai_generation.md)、[schema 风格](docs/rules/schema_style.md)。
- `Proposed` 表示可研究、未成为已实现的接口；新能力不得仅因规划文档出现就写进现有包 manifest。

## 3. 状态与阅读入口

| 内容 | 唯一维护入口 |
|---|---|
| 当前架构与边界 | [架构](docs/architecture.md)；[ADR](docs/adr/README.md)仅按需追溯原因 |
| 当前实施、待办与剩余验收 | [统一实施计划](docs/planning/implementation.md) |
| 作者用法、源码模板与打包 | [作者手册](docs/wiki/README.md)；字段以 SDK/schema 为准 |
| 术语 | [glossary](docs/glossary.md) |
| 废弃总纲和旧机制记录 | [archived](docs/archived/README.md)；[archive](docs/archive/README.md) 为更早档案 |

旧文档的历史批准事实保留，旧路线待办不自动成为新路线的发布门。执行进度、决策接受和人工签收分别记录。
