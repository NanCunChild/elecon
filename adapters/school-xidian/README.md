# school-xidian（西安电子科技大学）— parser 模式 adapter

**首个 parser 模式正式 adapter。状态：已端到端跑通**——QuickJS-wasm 沙箱对录制夹具产出等于 golden（`server npm run smoke:sandbox` 的 `testXidianNoticeList`）。

- **数据**：教务处公开通知 `notice.list`（emits `elecon.notice.list@1.1`）。
- **为何 parser 模式**：`jwc.xidian.edu.cn` 通知页是纯静态 HTML，无 JS 反爬，核心代取并脱敏后传入原始响应，adapter 只做 HTML → 标准 schema 的纯解析（不网络、不持凭证，红线 #5）。
- **域名白名单**：`https://jwc.xidian.edu.cn/*`（见 `manifest.json` `network.allow`）。

## 已知坑

- **两种日期结构并存**（见 `index.js:extractDateStr`）：
  1. `<li>…<span>2026-06-10</span></li>` —— span 即完整日期；
  2. `<li>…<div class="time"><p>30</p><span>2026.06</span></div>` —— 年月在 span、日在 p，需拼合。
  两者最终都经 `normalizeDate` 归一为 UTC RFC3339；识别失败则省略 `publishedAt`（schema 可选）。
- **URL 归一**：沙箱内无 `URL` 全局，手工拼接——绝对 URL 原样保留，相对路径拼 `ORIGIN`。
- **日期时区**：`normalizeDate` 统一产出 `...T00:00:00Z`（UTC）。注意 `adapters_tests/XIDIAN/jwc/std/` 下的逆向 spike 用的是本地 `+08:00`，二者 golden 不同——**正式 adapter 以本目录 UTC 产出为准**。

## 运行与验证

```bash
cd server
npm run smoke:sandbox    # 含 testXidianNoticeList 回放
```

## 夹具

`fixtures/` 放脱敏后的 notice.html 与期望 `notice.list.json`。脱敏要求见 `adapters/README.md` 与 tools PII scanner（`tools/src/scanner`）。

## 待办

- `adapters_tests/XIDIAN/` 下已有 IDS 登录、E-Hall 成绩/课表/考试、一卡通、图书馆等逆向脚本，但尚未封装为本 adapter 的 capability；接入需 WebView 登录收割（ADR-016）+ 凭证存储（ADR-012）就绪。
