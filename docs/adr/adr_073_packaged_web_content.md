# ADR-073 · 包内网页模板与显式提交

- 日期：2026-11-03
- 状态：Accepted（所有者授权剩余功能实施；远端网页网络及隐藏恢复不在本接口中冒充完成）
- 承接：ADR-034、046、068、070。

## 决策与分层

SDK14 增加可选 `manifest.webContent`，是 1–8 个 `{id,title,html}` 包内页面。id 为小写稳定标识，title 为不含控制符的 1–80 字符纯文本；单页 HTML UTF-8 最多 256 KiB，所有 HTML 合计最多 512 KiB，包总预算仍为 1 MiB。所有字节纳入批准 digest；更新重新批准。声明须同时具备 `browser:true` 与 `web.content/1.0`。不支持磁盘路径、远程资源地址或未纳入包的动态 HTML 作为声明。

核心提供固定的原生网页入口和有界网页区域，保留来源、标题、关闭与错误状态。点击入口才调用同包、同批准 digest 的 `web.content({pageId})`；禁止预加载、缓存、整体刷新与重试。结果 `{pageId,status}` 中 status 为 `completed/cancelled/unknown`，只表示该次交互；`unknown` 不得自动重放提交。UI 不推断或展示“源站已提交”除非脚本有明确成功证据。

脚本通过 `ctx.browser.openContent(pageId)` 打开已批准 HTML，再通过固定 `ctx.browser.content` 操作编辑 DOM、读取用户输入和等待显式点击；此模式拒绝 `evaluate` 和其他执行作者网页 JS 的旧方法。页面本身没有 QuickJS ctx、HTTP/凭据 API 或通用函数桥；页面结果仍视为不可信输入，由学校脚本验证。网络和学校协议继续走 QuickJS `ctx.fetch`，沿用网络范围、TLS、APPTunnel、取消和预算。写操作只由用户明确触发一次，认证恢复不重放。

## 网页网络边界

包内页面使用宿主合成的 HTTPS 地址 `https://elecon-script.invalid/<digest>/<id>`，通过当前页面的虚拟 main-frame GET 装载；原生请求拦截器只返回当前宿主打开页面的授权 HTML 内存响应（附 CSP 响应头），其余请求全部拒绝。不监听端口、不使用 file://，不会对该地址发起网络回退。HTML 前置宿主 CSP，先于任何包字节解析；`default-src/connect-src/frame-src/worker-src/object-src/form-action/base-uri` 均为 `none`。禁止包内脚本和事件属性执行；仅允许 inline CSS 和 data 图片，禁止直接 fetch/XHR/WebSocket、外链资源、表单原生提交、iframe、worker/service worker 和对象。新增窗口、下载、原生权限和外部导航仍拒绝。Android 同时启用 `blockNetworkLoads`，作为独立于页面脚本的原生断网门；新包网页模板首片仅在 Android 启用，其他平台返回固定 unsupported 错误，不能依赖未验收的回调等价性。

CSP 来自宿主，不把包提供的 meta 作为权限声明；额外 meta 只能叠加更严格策略。页面不能从 DOM 删除一个已生效的策略来扩大网络权限。宿主固定 DOM 程序经原生注入，参数只作为 JSON 数据；不 eval 作者表达式。操作限定 setText/setHtml/setValue/setAttribute/setDisabled/getText/getValue/exists/queryAll/waitForEvent，waitForEvent 只接受真实用户 click/submit/change、阻止原生提交，并返回布尔值。作者在 QuickJS 读取输入及执行协议。禁止文档 JS 同时消除 WebRTC 数据通道等不受 CSP connect-src 可靠覆盖的浏览器 API 调用；不依赖替换 JS 构造器的可绕过补丁。独占 WebView 租约与前后 Cookie/存储清理继续保留；包内页拒绝 Cookie 端口及切换到远端 open。

该接口可实现脚本自定义的表单和交互页面；它不是任意远端学校网页的安全透明嵌入。现有远端登录兼容路径的导航检查不覆盖所有子资源和 WebSocket。完整远端业务网页、WebView APPTunnel 与隐藏远端密码登录仍须单独落实受限传输；不通过隐藏布局绕过这一前置。

## 兼容、回滚与验证

SDK1–13 不接受 webContent。SDK14 未声明时不提供 openContent；既有可见网页登录 API、来源和数据含义保持不变。没有新增原生依赖。撤销/切身份/页面关闭/超时结束执行，关闭 native driver 后才释放全局租约。

验证：包大小/重复 id/控制符/声明缺失负例；包资源不可绕过 digest；实际 QuickJS 到 presenter 的 openContent 参数；CSP 在所有包字节前；原生断网设置及导航/iframe/下载拒绝；DOM nonce/关闭/身份替换；固定来源入口只在点击时执行；取消、未知提交不自动重发。合成测试、设备 WebView 防旁路测试、真实学校提交与人工安全审阅分别记录。

参考：[W3C CSP3](https://www.w3.org/TR/CSP/)、[HTML meta CSP](https://html.spec.whatwg.org/multipage/semantics.html#attr-meta-http-equiv-content-security-policy)、[Android WebSettings blockNetworkLoads](https://developer.android.com/reference/android/webkit/WebSettings#setBlockNetworkLoads(boolean))。meta 不支持 sandbox，故不把它列为已生效的保护。
