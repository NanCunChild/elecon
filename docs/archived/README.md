# 已废弃文档档案

本目录保存退出当前开发主线的文档。**所有历史正文已废弃为新开发依据**；历史 Accepted、人工签收和未完成事实保留，不因归档被改写。

当前入口：[AGENTS](../../AGENTS.md)、[架构](../architecture.md)、[ADR 索引](../adr/README.md)、[兼容维护边界](../reference/legacy_compatibility.md)。归档决策见 [ADR-041](../adr/adr_041_current_architecture.md)。

## 2026-10-31 迁移

68 份已提交基线快照，目录镜像原路径；正文仅增加归档标记、重定位相对链接并清理行尾空白，历史决定不改写。55 个原路径保留跳转，其余入口重写。根 AGENTS 的历史正文特意改名，避免工具把档案当作新的指令文件。

| 历史内容 | 位置 |
|---|---|
| 旧总则 | [AGENTS.pre-2026-10-31](2026-10-31/AGENTS.pre-2026-10-31.md) |
| 旧主入口 | [README](2026-10-31/README.md)、[architecture](2026-10-31/docs/architecture.md)、[glossary](2026-10-31/docs/glossary.md) |
| ADR-000–033（021 无文件） | [adr](2026-10-31/docs/adr/)，包括原状态索引 |
| 旧开发规则和 PR 模板 | [rules](2026-10-31/docs/rules/)、[PR 模板](2026-10-31/.github/pull_request_template.md) |
| V1 实施/签收状态 | [planning](2026-10-31/docs/planning/) |
| requestGraph、Masker、签名发布与旧认证参考 | [reference](2026-10-31/docs/reference/) |
| 精确原路径与处理方式 | [manifest.json](2026-10-31/manifest.json) |

ADR-034 起的当前决策仍在 `docs/adr/`。任务开始前的未提交业务变化不混入历史基线快照，也不由本次文档提交签收。旧引用带章节号时进入历史正文查阅。

更早的 [docs/archive](../archive/README.md) 保持原路径；二者都是档案，不竞争当前状态源。

## 2026-11-02 补充归档

9 份旧实施计划、探针和迁移/验收记录已归档，原路径保留跳转。旧文中的待签收项、性能数字和平台判断仅保留历史语境，不成为当前发布门或验收证据。见[迁移说明](2026-11-02/README.md)与[清单](2026-11-02/manifest.json)。当前功能职责由[核心与脚本边界](../reference/core_script_boundaries.md)承接。
