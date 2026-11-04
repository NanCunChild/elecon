# 本地浏览器 HAR 录制

`scripts/browser-har.mjs` 用独立 Chrome 会话记录用户手动操作期间的 HTTP 请求和响应，供学校协议、字段及分页分析。它是开发机工具，不修改应用宿主接口、安装授权或学校脚本；原有 [`trace:browser`](browser_auth_trace.md) 仍只生成脱敏认证元数据。

## 使用

需要 Node 20+、本机 Chrome/Chromium 和图形桌面。在仓库根目录安装依赖后运行：

```sh
npm run capture:browser
```

可通过 `CHROME_BIN` 指定浏览器可执行文件。工具启动空白页，不自动访问学校或提交表单。在这个窗口手动完成登录、页面查询、筛选切换与分页；同一会话中新开的标签页和弹窗也参与录制。结束时回到终端按 **回车或 Ctrl+C**，等待 `browser_har_saved`。工具先等待 `context.close()` 完成 HAR 导出，再报告保存成功。直接关闭 Chrome 或浏览器崩溃会标记 `interrupted`，不能视为已完整保存；强制结束进程或关机可能丢失本轮 HAR。

输出在仓库外的临时目录 `elecon-browser-har-*`：

| 文件 | 内容 |
|---|---|
| `session.har` | `full` 模式、正文内嵌的 HAR，包括所有域名，无 URL 筛选；二进制正文可用 base64 表达 |
| `capture.json` | 开始/结束时间、保存状态、浏览器版本、请求/页面计数与 HAR 概要；不记录 URL 或业务值 |
| `profile/` | 本次独立浏览器的 Cookie、Storage 等会话状态 |

目录为 0700，HAR 和摘要文件为 0600；工具拒绝把临时根目录设置在本仓库内。**HAR 和 profile 含原始 Cookie、认证头、表单及个人数据，保留在本机，不能提交入库或直接当作可分享的测试夹具。** 工具不会上传、自动脱敏或重放。测试夹具应从所需响应结构另行合成或脱敏。分析完成后由使用者删除本次目录；系统也可能清理临时目录。

只检查已存在 HAR 的规模和正文数量，可运行：

```sh
npm run capture:browser -- --summary /data/ehall.xidian.edu.cn_empty_classroom.har
```

此操作不启动浏览器、不访问网络，只输出条目、页面、请求/响应正文、缺正文、失败和跳转数量。缺正文包括重定向、无内容响应、失败等正常情况，并不全部代表抓取丢失。当前概要读取整个 HAR，适用于本地交互录制，超大文件应分段录制。

## 覆盖含义

“全部”指本次独立 browser context 中 Playwright 能观察到的 HTTP 请求，不以学校域名或接口路径裁剪；不是设备全流量抓包。保留学校正常的 Service Worker 行为，但不承诺捕获其所有内部请求、浏览器后台流量、缓存命中的全部正文或无限响应流。WebSocket 消息帧、WebRTC 数据及其他浏览器/profile 不属于 HAR 正文覆盖范围。正在传输的请求在停止时可能取消；`pendingRequests` 和失败计数只辅助判读，不是完整性证明。

工具不替换证书、绕过 TLS 验证、改写 UA、禁用 Service Worker 或重放请求。Playwright 使用自动化启动参数，独立 profile 也与日常浏览器缓存状态不同；不能把此记录当作真实 App WebView、APPTunnel 或所有平台行为已验收。

## 依赖与验证

开发依赖固定为 Microsoft [`playwright-core` 1.64.1](https://github.com/microsoft/playwright)，Apache-2.0；版本、来源与完整性固定在根 `package-lock.json`，已核对已安装包的 `LICENSE`。仅用于开发机浏览器控制和 HAR 导出，不引入浏览器二进制下载、不进入 Flutter 应用或学校脚本。来源与用途同时记入[依赖清单](trusted_scripts_dependencies.md)。

[官方 `recordHar` 文档](https://playwright.dev/docs/api/class-browsertype#browser-type-launch-persistent-context-option-record-har) 定义 full/embed、全页面范围和关闭 context 后保存的要求。使用本机 Chrome 的兼容性需实际测试，不能由 Playwright 版本号推断。

```sh
npm run test:browser-har
npm run test:browser-trace
npx biome check scripts/browser-har.mjs scripts/browser-har.test.mjs
```

新增合成测试只请求本机 HTTP 服务，以真实 headless Chrome 验证重定向、Cookie/认证头、POST/JSON、二进制正文、跨源 iframe、弹窗、失败请求、权限、重复停止及异常关闭。没有浏览器时集成测试会跳过，不能把跳过当作通过。本次未访问学校、录制真实登录或验证真实学校验收。
