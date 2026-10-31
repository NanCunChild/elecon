# AGENTS.md · elecon 开发总则

> 当前基线：2026-10-31。修改前先读本文、[当前架构](docs/architecture.md)及相关 [rules](docs/rules/)。旧总则已[归档并废弃](docs/archived/2026-10-31/AGENTS.pre-2026-10-31.md)，不再要求先读 ADR-000。

elecon 面向学生聚合校园服务。学校差异集中在可更新的受信学校脚本；宿主负责执行授权、身份与网络边界、标准契约和原生页面。优先减少学校变更波及面与长期维护负担。当前决策基线为 [ADR-041](docs/adr/adr_041_current_architecture.md)和 ADR-034 起的有效 ADR。

## 1. 现行边界

以下使用 B1–B10 新编号。代码和历史 ADR 中的“红线 #n”仍指[旧总则编号](docs/reference/legacy_compatibility.md#历史红线编号)，不可按下面的位置重解释。


**B1. 执行授权**：`elecon-script/1` 允许未签名源码，经用户检查包内容、学校身份、网络范围后安装；更新重新确认，实际执行字节必须匹配授权 digest。包版本、SDK 版本和数据 schema 版本分别裁定。

**B2. 凭据与身份**：受信学校脚本可处理当前授权学校身份的凭据；UI 不取得完整凭据库、主密钥，脚本不得跨学校/未授权身份访问。SDK 2 namespace 是寻址而非权限隔离，同校受信脚本可显式共享；不能声称现有增强包拥有独立的最小权限沙箱。

**B3. 公网边界**：公网服务不持凭据、私密数据不经公共中继。现有 `server/src/public` 是零凭据静态分发服务；公开业务缓存是独立待实施服务。校内授权中继仍是 stub，部署位置本身不产生查询或共享数据的授权。

**B4. 宿主能力**：学校认证、请求、签名和 DOM 编排留在脚本；宿主约束声明的网络范围、身份、取消与资源预算，不开放任意文件、进程、FFI、raw socket 或原生模块侧载。客户端脚本在背景 isolate，UI 异步。

**B5. 契约含义**：输入、输出、单位、时间、缺失值、副作用和实体身份必须明确。`contract/` 或核心抽象变更先有 ADR；当前开发阶段允许明确版本与迁移方案的破坏性更新，不能无声重解释已有字段。公测稳定后的兼容政策由人工决定。

**B6. 页面与操作**：客户端拥有布局、路由和交互；脚本提供标准数据，不下发 Widget tree。页面可组合多个能力，卡片是其中一种展示。查询和控制命令分开；现有命令确认、未知结果、禁自动重试及平台门不因新模板或增强包绕过。

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
| 架构与有效决策 | [架构](docs/architecture.md)、[ADR 索引](docs/adr/README.md) |
| 已有受信脚本实施和剩余验收 | [trusted_scripts](docs/planning/trusted_scripts.md) |
| 页面、增强包、中继的后续切片 | [platform_evolution](docs/planning/platform_evolution.md) |
| 使用、源码模板与打包 | [受信脚本参考](docs/reference/trusted_scripts.md) |
| 术语 | [glossary](docs/glossary.md) |
| 废弃总纲和旧机制记录 | [archived](docs/archived/README.md)；[archive](docs/archive/README.md) 为更早档案 |

旧文档的历史批准事实保留，旧路线待办不自动成为新路线的发布门。执行进度、决策接受和人工签收分别记录。
