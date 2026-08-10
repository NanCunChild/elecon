# adapters/ — 学校 adapter 目录

> adapter 是吸收学校接口差异的 shim：把原始数据归一化成标准 schema，并承接脏数据清洗与校本派生。
> **能力/信任面越薄越好，工程功能面越完整越好**。adapter 不持凭证、不决定网络授权、不驱动渲染，也不做跨数据源编排（ADR-000 §3.1）。

## 目录约定

```
adapters/
  _template/          脚手架模板（两种 requestGraph）
    imperative/       → imperative 模板（official 或 DEV-Sideload 调试）
    declarative/      → declarative 模板（official 或 DEV-Sideload 调试）
  school-<id>/        各学校 adapter
    manifest.json
    index.js
    fixtures/         脱敏的抓包样本
    README.md         该校信息与已知坑
```

## 快速开始

```bash
# 按目标 capability 选择模板；DEV-Sideload 可调试两种 requestGraph
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
| `sideload` / DEV-Sideload | `imperative` 和/或 `declarative` | 全能力开发调试；imperative 可驱动核心使用开发者测试凭证，但凭证值仍不离核心；不可分发 |

> `community` 档已于 ADR-002（2026-06-14 修订）移除，`manifest.schema.json` 的
> `trustTier` enum 仅 `official` / `sideload`。
>
> **当前实现差异**：validator 仍有 `C3_sideload_must_declarative`，会拒绝 sideload + imperative；
> ADR-033（已接受）将退役 C3，但**尚未落地**：在它随 DEPLOY official-only 负例同批提交前，不要通过放宽断言绕过，DEV imperative 的完整预检链待该批落地。
