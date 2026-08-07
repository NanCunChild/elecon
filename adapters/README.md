# adapters/ — 学校 adapter 目录

> adapter 是吸收学校接口差异的 shim：把原始数据归一化成标准 schema，并承接脏数据清洗与校本派生。
> **能力/信任面越薄越好，工程功能面越完整越好**。adapter 不持凭证、不决定网络授权、不驱动渲染，也不做跨数据源编排（ADR-000 §3.1）。

## 目录约定

```
adapters/
  _template/          脚手架模板（两种 requestGraph）
    imperative/       → 官方签名 adapter 模板（ctx.fetch 自取）
    declarative/      → 第三方/侧载 adapter 模板（核心代取 + 纯解析）
  school-<id>/        各学校 adapter
    manifest.json
    index.js
    fixtures/         脱敏的抓包样本
    README.md         该校信息与已知坑
```

## 快速开始

```bash
# 从模板复制（official 常用 imperative；sideload 必须 declarative）
cp -r adapters/_template/imperative adapters/school-<你的学校id>
# 或
cp -r adapters/_template/declarative adapters/school-<你的学校id>

# 修改 manifest.json：每 capability 声明 requestGraph + 域名白名单
# 在 index.js 实现归一化
# 在 fixtures/ 放入脱敏抓包样本

# 校验（tools 为 Node/TS 工具链）
cd tools && npm run validate -- --adapter=../adapters/school-<id>
```

## 信任级别与 requestGraph

| trustTier | requestGraph（每 capability） | 能做什么 |
|---|---|---|
| `official` | `imperative` 和/或 `declarative` | imperative：受限 `ctx.fetch`（白名单内注入凭证）；declarative：核心代取 + 纯解析 |
| `sideload` | **强制全部** `declarative` | declarative 纯解析，无网络、无凭证、无副作用（红线 #5；ADR-022） |

> `community` 档已于 ADR-002（2026-06-14 修订）移除，`manifest.schema.json` 的
> `trustTier` enum 仅 `official` / `sideload`。
