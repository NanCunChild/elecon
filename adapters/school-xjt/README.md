# school-xjt（西安交通大学）— imperative requestGraph adapter（Track A spike）

**首个 imperative adapter。状态：已通过本地夹具回放端到端 smoke。**

- **数据**：教务处公开通知 `notice.list`。
- **为何 imperative（ADR-023 §6 复核，2026-07-24）**：本 capability **不满足**声明式跨请求
  数据流（ADR-023）的迁移条件，须**保留 imperative**，理由是 ADR-022 §2.5 划归命令式的**两类
  都命中**：
  1. **动态拓扑**：`index.js [2]` 的 `if (html.includes("var challengeId"))` 依**响应内容**决定
     是否发起后续两个请求（POST 挑战 + 二次 GET）。请求数量/是否发出随响应而变，不是静态 DAG——
     声明式的 `bind/compute/inject` 是固定拓扑，表达不了「命中挑战页才多发两跳」。
  2. **不可枚举计算 + 值回读**：POST body 的 `browser_info` 是反爬**指纹伪造**（非封闭 op 词表可
     表达），且挑战 `answer` 需从页面读入再回填请求体（值经 adapter 逻辑），超出「句柄不进 adapter」
     的声明式边界。
  故本 capability 是 ADR-023 §6「仍保留 imperative」的登记项，非迁移试点。声明式数据流的参考
  示例见 `adapters/_template/declarative`（挑战页→抽取→注入的**固定拓扑**版）。
- **不碰学生凭证**：`credentials` 块为空，全程 passthrough；client_id/JSESSIONID 是 origin
  下发的反爬会话态，由 per-execution jar 管理、执行后即弃（不入凭证库）。

## 运行与验证

B6 运行时已把 B1–B5 编织成可跑的 `ctx.fetch`。服务端回放验证：

```bash
cd server
npm run smoke:xjt
```

## body-token 缺口（已修补）

~~挑战返回的 `client_id` 只在响应体、无 `Set-Cookie` → jar 抓不到。~~
**已修补**：经 `ctx.setEphemeralCookie`（ADR-009 §2.4 rev-3 / PR #34 契约 / B4 #37 运行时）写入
jar ephemeral 分区。四重栅栏由 Broker 强制（仅 passthrough / 不覆盖凭证 / 永不收割 / 执行即弃）。

## 夹具

`fixtures/` 已放入脱敏后的 challenge.html / challenge_response.json / notice.html，供 XJT fetch 回放 smoke 使用。录制方法与脱敏要求见 FLOW.md §5。
