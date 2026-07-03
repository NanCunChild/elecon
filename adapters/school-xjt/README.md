# school-xjt（西安交通大学）— fetch 模式 adapter（Track A spike）

**首个 fetch 模式 adapter。状态：已通过本地夹具回放端到端 smoke。**

- **数据**：教务处公开通知 `notice.list`。
- **为何 fetch 模式**：站点有 JS 反爬挑战（多步握手），需 `ctx.fetch` 自行发起。
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
