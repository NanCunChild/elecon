# 受信脚本浏览器容器与包内网页

依据 [ADR-068](../adr/adr_068_script_interaction_and_recovery.md)、[ADR-073](../adr/adr_073_packaged_web_content.md)。可见登录和包内业务网页共用原生容器、独占租约与清理；它们的网络权限不同。

## 包内网页模板（SDK14，Android）

`manifest.webContent` 是 1–8 个 `{id,title,html}`，必须同时声明 `browser:true` 和 `web.content/1.0`。单页 HTML UTF-8 最多 256 KiB，全部最多 512 KiB；包总预算仍为 1 MiB。资源随包安装和更新授权，不从网络补下载，也不用 file://。id 为 1–64 个小写字母、数字、点、下划线和连字符且首字母为字母；title 为最多 80 字符纯文本。

每页有独立首页入口，核心固定绑定来源包、批准 digest 和 `pageId`。打开功能页后，点击按钮才调用 `web.content({pageId})`；它不参与预加载、缓存、整体刷新或自动恢复重试。结果为 `{pageId,status}`，status 为 completed/cancelled/unknown：只有脚本能根据业务证据确认完成或确认尚未提交；连接中断且可能已提交应返回 unknown。

脚本先 `await ctx.browser.openContent(pageId)`，再通过 `ctx.browser.content(request)` 操作文档。页面没有 QuickJS ctx、HTTP、凭据库或通用能力桥。

| operation | 参数 | 返回 |
|---|---|---|
| setText / setHtml / setValue | selector、value 字符串 | null |
| setAttribute | selector、attribute、value 字符串 | null |
| setDisabled | selector、value 布尔值 | null |
| getText / getValue | selector | 字符串 |
| exists | selector | 布尔值 |
| queryAll | selector、可选 limit（1–100，默认100） | 有界 tag/text 数组 |
| waitForEvent | selector、event（click/submit/change）、可选 timeoutMs（1–90000，默认60000） | true 为真实用户事件，false 为超时 |

selector 最多 1024 字符；写入 value 最多 65536 UTF-8 字节；读取最多 65536 字符；attribute 是最多64字符的小写名称，拒绝 on* 事件属性。不存在的目标或无 value/disabled 属性的元素返回固定错误。未知操作、额外字段和超预算在宿主拒绝。`waitForEvent` 阻止原生默认动作、移除监听器，并在 click/submit 后禁用可禁用的目标以避免双击；只有用户产生的 trusted 事件可完成等待。脚本收到输入后仍要验证类型/范围，使用 `ctx.fetch` 按学校协议提交一次。

在此模式调用 `evaluate` 或旧的可执行 DOM 方法会被拒绝；setHtml 的内容仍为无脚本文档。宿主固定 DOM 程序通过原生注入，参数仅为 JSON 数据，不 eval 作者表达式。作者可以构建任意需要的 HTML 节点、文本和表单布局，但文档中的 script、on* 事件、javascript URL 都不能执行。

HTML 前先安装宿主 CSP：文档脚本、连接、iframe、worker、对象、表单原生提交和 base URI 均禁止，仅允许 inline CSS 与 data 图片。Android 同时启用原生 blockNetworkLoads/禁网络图片、禁文件和 content URI；拒绝所有页面导航、窗口、下载和原生权限。宿主保留当前合成 HTTPS 来源，Android 的当前虚拟主文档 GET 回调使用同一授权 HTML 内存响应（附 CSP 响应头），其他请求全部拒绝，不访问该域名。禁文档脚本也阻止 WebRTC 数据通道等不由 CSP connect-src 完整覆盖的旁路；不把替换 JavaScript 构造器当成权限隔离。其他平台暂时返回 unavailable。

[可运行模板](../../adapters/_template/trusted/web-form/)演示本地草稿；它没有真实网络提交。`client/lib/dev/web_content_smoke.dart` 为纯合成设备入口，检验禁止文档脚本、固定 DOM、用户事件和取消清理，不含学校账号。

## 共享宿主组件

- [ScriptBrowserSurface](../../client/lib/ui/scripts/script_browser_surface.dart) 是页面内有界区域，保留宿主标题、来源、关闭、加载/失败状态。网页 DOM 不能覆盖这些控件；关闭只结束该区域。
- [ScriptBrowserPage](../../client/lib/ui/scripts/script_browser_page.dart) 提供既有路由/返回语义；包内网页使用声明标题，旧登录保留核心登录标题。
- [ScriptBrowserPlatformView](../../client/lib/ui/scripts/script_browser_platform_view.dart) 统一设置与导航、TLS、权限、窗口、下载和结果回调；[driver](../../client/lib/core/scripts/inappwebview_browser_driver.dart) 统一 Cookie/存储初始化与清理。
- 移除或换身份 bridge 时，完成旧 native 清理后才释放租约及创建新视图。旧回调捕获旧 bridge，不能写入新身份。DOM nonce 单次使用，关闭/导航撤销旧回复。

## 远端网页与隐藏恢复的限制

旧可见网页登录仍支持已有 `ctx.browser.open/evaluate`，保留既有网络 origin、TLS、导航、取消和独占清理。子 frame 允许来源不改变顶层身份；拒绝来源会阻止导航。

这些导航检查不等同于跨平台所有子资源、XHR/fetch、WebSocket、WebRTC 与重定向的强制路由。完整远端学校表单透明嵌入、隐藏远端认证和 WebView APPTunnel 仍须落实受限传输。包内模板让学校脚本通过受限 ctx.fetch 实现表单协议，不能声称任意远端网页已可安全隐藏。选择 APPTunnel 后，现有会话继续拒绝浏览器调用，不能静默直连。

## 验证范围

合成回归覆盖旧浏览器/容器、包内 CSP 前置、原生网络设置、全部导航拒绝、DOM 参数与预算、禁止任意 JS/Cookie、实际 QuickJS API/页面身份、关闭晚到值与清理租约、首页显式触发、固定来源、后台拒绝、刷新/缓存/未知结果不重放。设备 smoke 与真实学校提交验收分别记录于实施进度；通过合成测试不表示远端传输或真实表单已验收。

2026-11-03 在 API37 Android 模拟器运行合成 smoke：授权 HTML 经虚拟主文档内存响应加载，inline script/onerror 保持不执行；固定 DOM 构建、读写输入及任意 evaluate 拒绝通过。实际触摸网页提交按钮后，原生界面与固定日志均为 `WEB_CONTENT_SMOKE_PASS`；重新启动后通过原生取消按钮得到 `WEB_CONTENT_SMOKE_CANCEL_PASS`，两条路径均在 native 清理并释放独占租约后才发布通过。该证据不涉及真实学校表单或隐藏认证。定位并修复了 loadData 的 data 主请求被拒绝问题，以及加载/来源状态行变化可能重建原生区域的问题（稳定区域 key，挂载计数回归）。
