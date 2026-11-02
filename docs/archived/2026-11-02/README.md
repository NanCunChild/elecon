# 2026-11-02 旧实施材料补充归档

依据 [ADR-041](../../adr/adr_041_current_architecture.md) 的文档治理和本轮项目整理授权，移出仍混在活动目录中的旧实施记录。原始决定、人工签收空白、未完成状态及当时测试结果均保留；归档不表示这些测试已重跑，也不表示旧运行时已删除。

| 原路径 | 归档原因 | 当前入口 |
|---|---|---|
| `docs/notes/hardware_persistence_plan.md` | 2026-07 的接线草案与旧待办，部分建议不能作为当前实现说明 | [凭据存储](../../../client/lib/core/credential/)、[功能边界](../../reference/core_script_boundaries.md) |
| `docs/notes/pr86_security_review_checklist.md` | 特定旧 PR 的签审记录，含已退出主线的官方仓/补签流程 | [当前工作规则](../../rules/feature_workflow.md)；原人工签审状态仍在档案 |
| `docs/probes/probe_001_*.md`（4 份） | 旧 V1 WebView 收割探针及桌面研究，不能代表当前平台支持或真实验收 | [客户端说明](../../../client/README.md)、[OHOS 旁路](../../../client/ohos/README.md) |
| `docs/probes/probe_002_atrust_tunnel.md` | 保留早期 aTrust 研究证据；“实现为零/ADR 待起草”已不是现况 | [ADR-062](../../adr/adr_062_app_tunnel_selection.md)、[原生桥](../../../native/hermes_app_tunnel/README.md) |
| `docs/reference/gradepoint_ownership_landing.md` | 2026-09 迁移快照；当时“客户端零消费 gpa.summary”已过时 | [业务边界](../../reference/core_script_boundaries.md)、[schema](../../../contract/schema/grades.list.schema.json) |
| `docs/reference/xidian_smoke_runbook.md` | V1 CASTGC/headless mint 验收脚手架，不适用于受信源码学校认证 | [现行脚本实施记录](../../planning/trusted_scripts.md) |

归档保留原目录结构，原文件改为跳转。正文仅增加档案标记、重定位 Markdown 相对链接并清理行尾空白；历史文本中的内联路径和行号仍代表当时位置。精确路径与原文 SHA-256 见 [manifest.json](manifest.json)。本次不重写 2026-10-31 档案或更早的 `docs/archive/`。
