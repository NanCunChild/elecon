# WebView、DOM 与包内网页

[返回目录](README.md) · 相关：[登录与凭据](accounts.md)

## 三种 HTML 使用场景

| 场景 | 入口 | 文档行为 |
|---|---|---|
| 读取静态 HTML | `ctx.fetch` + `elecon:html` | 在背景脚本解析，不开 WebView |
| 官方学校网页登录与页面读取 | `ctx.browser.open/evaluate/text/waitFor` | 用户可见，学校网页自身运行 |
| 包内业务表单 | SDK14 `webContent` + `openContent/content` | Android 无文档脚本、无直接网络，固定 DOM 操作 |

这三类接口不能互换。尤其包内网页不是任意远端表单的透明嵌入，也没有 `window.elecon`、凭据库或通用能力桥。浏览器授权仍受实际平台支持限制；包内网页当前只支持 Android，隐藏远端认证与普通 WebView APPTunnel 尚未开放。

## 静态 HTML 解析

只为读取列表时优先使用背景解析。以下是虚构学校标记结构的处理器示例，需要声明 `notice.list` 和 `https://campus.example.edu` origin，并按学校实际 HTML 调整选择器与 ID 规则。

```js
import { parseDocument, selectAll, getText, getAttributeValue } from "elecon:html";

export const capabilities = {
  async "notice.list"(ctx) {
    const response = await ctx.fetch("https://campus.example.edu/notices");
    if (!response.ok) throw new Error("notice_http_failed");
    const document = parseDocument(await response.text());
    const items = selectAll("a[data-notice-id]", document).map((node) => ({
      id: getAttributeValue(node, "data-notice-id"),
      title: getText(node).trim(),
      source: "示例教务处", category: "academic"
    }));
    if (items.some((item) => !item.id || !item.title)) {
      throw Object.assign(new Error("source_response_invalid"), { code: "source_response_invalid" });
    }
    return { items };
  }
};
```

`elecon:html` 是宿主内置解析库，`selectAll(selector,document)` 返回解析节点，不是 WebView DOM。这里的 `document` 是局部解析结果。学校 HTML 变更时应更新学校脚本和夹具，不在核心增加学校选择器。

## 官方网页的可见 DOM 操作

manifest 设置 `browser:true`，并在 `network.origins` 中列出认证与业务的实际 origin，包括跳转涉及的身份系统。以下为 **DOM 调用片段**，`#notice-list` 等仅表示虚构页面结构：

```js
await ctx.browser.open("https://campus.example.edu/notices");
const ready = await ctx.browser.waitFor("#notice-list", 30000);
if (!ready) {
  throw Object.assign(new Error("authentication_timeout"), { code: "authentication_timeout" });
}
const heading = await ctx.browser.text("h1");
const hasList = await ctx.browser.exists("#notice-list");
const rows = await ctx.browser.queryAll("#notice-list a", 20);
const items = await ctx.browser.evaluate(() =>
  Array.from(document.querySelectorAll("#notice-list a[data-notice-id]")).map((node) => ({
    id: node.dataset.noticeId,
    title: node.textContent.trim(),
    category: "academic", source: "示例教务处"
  }))
);
```

`waitFor` 返回布尔值，不等于已验证业务会话。`queryAll` 的节点快照与业务 schema 不同，需要映射；复杂读取可在 evaluate 中返回可序列化数据。evaluate 中的函数在页面环境执行，不捕获外层 QuickJS 变量，也不能访问 `ctx`。参数显式传入，避免把密码拼成 JS 源码：

```js
async function fillSchoolLoginForm(ctx, attempt) {
  return ctx.browser.evaluate((username, password) => {
    const user = document.querySelector("#username");
    const secret = document.querySelector("#password");
    const submit = document.querySelector("button[type=submit]");
    if (!user || !secret || !submit) return false;
    user.value = username;
    secret.value = password;
    user.dispatchEvent(new Event("input", { bubbles: true }));
    secret.dispatchEvent(new Event("input", { bubbles: true }));
    submit.click();
    return true;
  }, attempt.username, attempt.password);
}
```

这里的 attempt 来自[声明账号的前台密码输入](accounts.md)，函数只演示写入并点击学校按钮。具体框架可能需要不同事件或 setter，学校脚本应按真实表单适配。返回 true 只表示找到了元素并执行点击，不证明登录成功；随后仍需学校状态和业务 API 验证。验证码、滑块或 MFA 应留给可见页面的用户操作。

SDK4+ 可在**已进入非交互收尾阶段**使用固定遮罩，避免用户在保存会话时继续操作：

```js
await ctx.browser.setBusy(true);
try {
  // 在此执行已验证会话的有界采集/保存，不等待用户处理验证码。
  const cookies = await ctx.browser.cookies("https://campus.example.edu/api/notices");
  await ctx.credentials.set("api-cookies", JSON.stringify(cookies), { type: "cookie" });
} finally {
  await ctx.browser.setBusy(false);
}
```

该片段只展示遮罩与采集 API，完整的多目标 Cookie 快照及恢复应采用[凭据章节](accounts.md#5-保存浏览器-cookie)的模板，不能直接把所有 Cookie 发给任意 URL。遮罩不增加关闭浏览器的 API，取消仍保留。

可见网页登录已有导航、来源、TLS、取消及清理约束；这些检查不能解释为跨平台所有子资源、XHR、WebSocket、WebRTC 均已被强制代理。需要隐藏远端网页、透明表单或隧道传输时，先核实当前支持范围，不能把可见浏览器简单改为不可见。

## 包内网页与表单

SDK14+ manifest 片段如下。HTML 随包安装，和源码一起纳入批准 digest；不是从网络下载一个 URL。

```json
{
  "browser": true,
  "network": { "origins": [] },
  "capabilities": [
    { "id": "web.content", "schema": "elecon.web.content", "schemaVersion": "1.0" }
  ],
  "webContent": [{
    "id": "draft",
    "title": "本地草稿",
    "html": "<label for='subject'>主题</label><input id='subject' maxlength='120'><button id='submit' type='button'>使用草稿</button><output id='result'></output>"
  }]
}
```

宿主为声明页面提供入口，用户点击打开按钮后调用同包 `web.content({pageId:"draft"})`。以下处理器只读取本地草稿，不保存、不联网：

```js
export const capabilities = {
  async "web.content"(ctx, { pageId }) {
    if (pageId !== "draft") throw new Error("input_invalid_request");
    await ctx.browser.openContent(pageId);
    const clicked = await ctx.browser.content({
      operation: "waitForEvent", selector: "#submit", event: "click", timeoutMs: 60000
    });
    if (!clicked) return { pageId, status: "cancelled" };
    const subject = await ctx.browser.content({ operation: "getValue", selector: "#subject" });
    if (typeof subject !== "string" || !subject.trim() || subject.length > 120) {
      return { pageId, status: "cancelled" };
    }
    await ctx.browser.content({ operation: "setText", selector: "#result", value: subject });
    return { pageId, status: "completed" };
  }
};
```

这里 completed 只表示本地草稿流程完成。真实学校提交由背景脚本 `ctx.fetch` 发送一次并验证响应；可能已提交却无法确认时返回 unknown，不自动重放。想在页面继续展示确认内容，可像[完整模板](../../adapters/_template/trusted/web-form/index.js)一样等待用户点击关闭。

### 固定 DOM 操作表

所有操作通过 `ctx.browser.content({...})`，不执行作者的表达式：

| operation | 其他参数 | 返回 |
|---|---|---|
| setText / setHtml / setValue | selector、字符串 value | null |
| setAttribute | selector、attribute、字符串 value | null |
| setDisabled | selector、布尔 value | null |
| getText / getValue | selector | 字符串 |
| exists | selector | 布尔值 |
| queryAll | selector、可选 limit | 有界 tag/text 快照数组 |
| waitForEvent | selector、event、可选 timeoutMs | 真实用户事件 true，超时 false |

事件限 click/submit/change。click/submit 会阻止默认提交，并禁用可禁用的目标避免双击；只有真实用户事件可完成等待。后续需要重启交互时由脚本明确恢复控件和监听，不能程序化模拟用户点击。

最多八页，单页 HTML 256 KiB、总 HTML 512 KiB，整包仍为 1 MiB。selector 最多 1024 字符，写入字符串最多 65536 UTF-8 字节；queryAll 的 limit 为 1–100；事件默认等待 60 秒、最多 90 秒，仍受总调用预算约束。

包内模式拒绝 `evaluate`、旧式可执行 DOM、Cookie 等远端浏览器接口。HTML 中的 script、on*、javascript URL 不执行；`setHtml` 不会开放它们。inline CSS 与 data 图片可用，远端脚本/样式/图片、iframe、原生表单提交、导航、下载和页面直接网络均被禁止。外部学校协议由 `ctx.fetch` 承担，并仍受 manifest 网络边界约束。

容器、平台限制与取消语义见[浏览器参考](../reference/script_browser_surfaces.md)。关闭、换身份或撤销后，旧 DOM 回复不能写入新页面或身份；不要自行创建未受宿主管理的 WebView 绕过这些入口。
