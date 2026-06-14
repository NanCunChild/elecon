# XJT dean（西安交大教务处）fetch 模式流程 + spike 记录

> Track A spike：第一个 fetch 模式 adapter 的逆向与设计验证。目标数据 = 教务处**公开通知**
> （`notice.list`）。选它是因为它需要 fetch 模式（多步 + JS 反爬挑战），但数据公开、
> **不碰学生凭证**——以最低风险锻炼整条 fetch 链（ADR-009）。

## 1. 实测流程（来自 `fetch.py` 逆向）

```
[1] GET  https://dean.xjtu.edu.cn/                      （passthrough，不注入）
        └─ 命中 JS 挑战页：HTML 内含 `var challengeId="..."` + `var answer=N`
[2] 解析 challengeId / answer（answer 直接给在页面里，无需算 JS）
[3] POST https://dean.xjtu.edu.cn/dynamic_challenge      （passthrough）
        body = { challenge_id, answer, browser_info:{ua,platform,...} }
        └─ 响应 JSON：{ success:true, client_id:"..." }
[4] 把 client_id 作为 cookie 带上（⚠️ 见 §3 设计缺口）
[5] GET  https://dean.xjtu.edu.cn/                       （带 client_id + JSESSIONID cookie）
        └─ 返回真实通知列表 HTML
[6] 解析 div.tz（含「通知公告」）→ li → a[title]（标题/链接）、i（分类）、span（日期）
```

实测 cookie（`pac.txt`，已脱敏）：最终请求带 `client_id=<REDACTED>; JSESSIONID=<REDACTED>`。
两者都是 origin 下发的会话态，**非学生认证**。

## 2. 映射到 ADR-009 fetch 模式

| 流程节点 | ADR-009 机制 |
|---|---|
| GET 挑战页 / POST 挑战 | passthrough（`network.allow` 内、不命中任何 `credentials.scope` → 放行不注入，§2.4） |
| origin 下发的 `JSESSIONID` | per-execution cookie jar 自动持久化 `Set-Cookie`、后续请求自动带（§2.4） |
| HTML 解析 | `elecon:html`（两端零漂移，§2.4 第 1 条 / ADR-011） |
| 反爬挑战由 adapter 解 | official 独占 fetch（§2.4 第 3 条），解析内联值 + 伪造指纹属 fetch 模式职责 |
| client_id（见下） | **⚠️ 缺口** |

**无学生凭证**：`credentials` 块为空 → 全程 passthrough。不需要 ADR-012 凭证存储 / WebView 登录。
client_id / JSESSIONID 是 per-execution jar 的活，执行结束即弃（未被任何 ref 声明 → 不收割入库，§2.4 判据 b）。

## 3. ⚠️ 设计缺口：client_id 来自 **body**，不是 Set-Cookie

spike（`fetch.py:69-74`）从 POST 的 **JSON 响应体** 读 `client_id`，再 `session.cookies.set(...)`
**手动**设为 cookie。真实浏览器里是页面 JS 把 body 里的 client_id 写进 `document.cookie`。

这与 ADR-009 当前模型冲突：
- §2.3：adapter 经 `init.headers` 设的 `Cookie` 头被宿主**无条件剥除** → adapter **不能自己设 cookie**。
- §2.4：per-execution jar 只自动持久化 origin 的 **`Set-Cookie`** → 若 client_id 只在 body、没有 Set-Cookie，**jar 抓不到**，后续请求带不上 → 流程断。

**待确认（需一次真实抓包）**：`POST /dynamic_challenge` 的响应**有没有 `Set-Cookie: client_id=...`**？
- 若**有** → jar 自动处理，ADR-009 现模型够用，adapter 无需碰 cookie。✅
- 若**只在 body** → ADR-009 有真实缺口，需修订（见 §4）。这类"origin 把会话 token 放 body、
  靠前端 JS 写 cookie"是常见反爬模式，值得正式补。

## 4. 若需修订 ADR-009（缺口为真时的方向，待人工 + ADR）

候选方向（**不**在本 spike 拍板，留给 ADR-009 修订 + 安全审）：
- **方向 A（倾向）**：放宽"剥除 adapter 所有 Cookie 头"为"adapter 设的 Cookie 头**注入 per-execution
  jar**（而非拒绝），约束：① 仅作用于 jar、不跨执行、scope 受 `network.allow` 约束；② **绝不**覆盖
  broker 注入的 credential ref（真·学生凭证）；③ 仅 passthrough 场景。红线 #1 不破——adapter 设的是
  它自己从 passthrough 响应里解出的反爬 token，本就无学生凭证可泄。
- **方向 B**：manifest 声明式"body 字段 → jar cookie"提取规则（纯数据、核心执行）。表达力受限、复杂。

## 5. 录制脱敏夹具（需用户在本机/校园网跑，AI 不直连真实校服务器）

需要三份**脱敏后**的固定夹具供回放（ADR-009 §3.6）：
1. `challenge.html` —— 步骤[1] 的挑战页（含 `var challengeId/answer`，可用假值替换真实 id）。
2. `challenge_response.json` + **响应头**（关键：看有没有 `Set-Cookie`，解 §3 缺口）。
3. `notice.html` —— 步骤[5] 的真实通知页（删除任何个人化痕迹；通知本身是公开数据）。

脱敏要求（红线 #8）：challengeId / client_id / JSESSIONID 一律替换为假值；不留真实 cookie。

> 抓包建议：用浏览器 DevTools 或 mitmproxy 录一次完整流程，**务必保留 POST 响应的完整 header**
> 以判定 §3。导出后人工脱敏再入 `adapters/school-xjt/fixtures/`。
