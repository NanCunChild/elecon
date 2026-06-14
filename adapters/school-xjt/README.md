# school-xjt（西安交通大学）— fetch 模式 adapter（Track A spike）

**首个 fetch 模式 adapter。状态：逻辑 spike，尚不可端到端运行。**

- **数据**：教务处公开通知 `notice.list`。
- **为何 fetch 模式**：站点有 JS 反爬挑战（多步握手），需 `ctx.fetch` 自行发起。
- **不碰学生凭证**：`credentials` 块为空，全程 passthrough；client_id/JSESSIONID 是 origin
  下发的反爬会话态，由 per-execution jar 管理、执行后即弃（不入凭证库）。

## 运行依赖（未就绪）

端到端运行需 **Track B**：运行时受限 `ctx.fetch` + Broker（ADR-009 承重路径，🔒 人工主导，未实现）。
本 adapter 先作为逻辑 spike + 设计验证。

## 待解决：ADR-009 设计缺口

挑战返回的 `client_id` 可能只在响应体、无 `Set-Cookie` → jar 抓不到、adapter 又不能自设 cookie。
详见 [`FLOW.md`](./FLOW.md) §3/§4。**需一次真实抓包确认**。

## 夹具（待录制）

`fixtures/` 待放入脱敏后的 challenge.html / challenge_response.json(+headers) / notice.html，
供录制/回放双跑（ADR-009 §3.6）。录制方法见 FLOW.md §5。
