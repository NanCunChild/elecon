# 规则 Git 与提交

依据 [AGENTS](../../AGENTS.md)。旧版已[废弃归档](../archived/2026-10-31/docs/rules/git.md)。

- 使用短命分支：`feat/`、`fix/`、`docs/`、`refactor/`、`chore/`、`adapter/<school>`。已有任务分支可继续使用；禁止直推受保护 `main`，经 PR 审查合并。
- 提交用 Conventional Commits：`type(scope): subject`。一个提交一个目的，避免把文档迁移、业务实现和格式化混在一起。
- AI 辅助提交 body 加 `Assisted-by: Codex`；安全敏感变化写明边界影响和验证。
- 用户要求 unsigned 时，逐次使用 `git -c commit.gpgsign=false commit --no-gpg-sign`，不修改全局签名设置，不签署 tag 或发布产物。
- 提交前核对 `git diff --cached`，只暂存本次变化；已有未提交内容保留。需要修改同一文件时按本次差异暂存。
- PR 说明有效 ADR、源码/V1/提案的路线范围、验证和剩余人工验收。使用[模板](../../.github/pull_request_template.md)。

契约和核心变更按 [feature_workflow](feature_workflow.md) 处理。V1 门只验证 V1；新脚本验证安装授权、身份、网络、版本、取消和输出。CI 与人工安全审阅分别记录。
