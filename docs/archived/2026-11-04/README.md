# 2026-11-04 文档收敛快照

依据 [ADR-081](../../adr/adr_081_script_runtime_consolidation.md)。此处保存收敛前工作区的 8 份文档，包括此前尚未提交的文档变化；不是某个 Git commit 的独立发布快照。

原正文保留，只添加历史标记并重定位 Markdown 相对链接。原字节与归档字节 SHA-256 见[清单](manifest.json)。当前架构改为按模块组织，作者入口集中到 [Wiki](../../wiki/README.md)，未完成事项只维护在[实施计划](../../planning/implementation.md)。旧路径保留跳转，旧章节可在本目录对应快照查询。

| 内容 | 历史快照 |
|---|---|
| 架构与逐功能职责 | [架构](docs/architecture.md)、[职责表](docs/reference/core_script_boundaries.md) |
| 版本递增式作者参考 | [受信脚本参考](docs/reference/trusted_scripts.md) |
| 实施与验证流水 | [受信脚本记录](docs/planning/trusted_scripts.md) |
| 分散计划 | [平台演进](docs/planning/platform_evolution.md)、[论坛消息](docs/planning/forum_and_messages.md)、[功能补充](docs/planning/feature_supplements.md) |
| ADR 当时的状态表 | [ADR 索引](docs/adr/README.md) |

ADR 正文本轮不移动、不批量改变 Accepted/Proposed 状态；已有 V1 调用、保护和测试没有因文档归档而删除。历史测试、真实学校和人工签收证据保持原范围，历史待办不自动成为当前发布门。
