# Schema / Capability 扩展 —— 残留清单

> **2026-07-20 清理**：原「字段缺口 + P0/P1/P2 注册 + 主仓库行动」大部已由契约扩展落地
> （registry 已含 profile/term/exam/classroom/…；`notice.list` / `grades.list` / `schedule.week` /
> `card.*` / `library.loans` / `generic.section` 等 schema 已扩；分页/时间/金额/状态/来源等公共约定已进 schema）。
> 本文只保留**仍待做**项。历史愿望单见 git 历史。

## 已完成（勿再当 TODO）

- [x] P0/P1/P2 capability ID 注册 + JSON Schema + TS/Dart 产物生成链
- [x] 成绩 / 课表 / 通知 / 校园卡 / 图书馆 / generic 等基线字段扩面
- [x] 分页、RFC3339 时间、金额、状态枚举、来源、`sourceSystem`/`updatedAt` 等公共字段
- [x] 脱敏夹具与 schema golden 入口（contract/golden + 学校侧 fixture 约定）
- [x] validator / catalog 对新增 capability 的静态校验路径
- [x] vendor 契约快照同步流程（独立提交，不混 adapter）

## 仍待做

### 契约演进（按需、先 ADR）

- [ ] 字段级「不支持 / 未返回 / 空 / 脱敏」四态若要在 envelope 统一表达，开小 ADR 后再改 schema（避免静默改语义）
- [ ] 增量同步（课表变更、成绩更新、通知撤回）的版本/游标约定——有真实校需再立
- [x] `login.ssoMint.services[*].forms` + 校验器 M6/M7（ADR-017 PR-5）
- [ ] 声明式过期/升级判据（`expiredWhenUrlMatches` 等，ADR-017 rev-2 §2.9）

### 宿主 / 运行时（非 schema 正文）

- [ ] WebVPN、多跳统一认证、验证码、会话过期的**宿主侧**能力面（adapter 不存凭证）
- [ ] XIDIAN mint 全闭环：见 [`docs/reference/xidian_mint_closed_loop_plan.md`](docs/reference/xidian_mint_closed_loop_plan.md)
- [ ] 命名 Header / 固定 body 凭证注入：评审 ADR-029 后再实现
- [ ] 空调物理控制：评审 ADR-030 并完成核心 action 门禁后再接正式 adapter

### 文档

- [ ] 学校原始字段 → 标准字段映射指南（adapter 作者文档，非契约硬约束）
- [ ] 契约版本升级与 vendor 兼容性检查清单固化到 `docs/rules/`

## 明确不在本清单

- 具体学校 adapter 实现（属 `adapters/` + 签名发布）
- 凭证 mint 执行体接线（属 ADR-017，人工主导）
