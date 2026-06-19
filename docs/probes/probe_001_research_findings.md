# Probe-001 研究发现 · OHOS WebView 行为机制（桌面调研结论）

> **类型**：桌面调研结论（[`probe_001_research_outline.md`](probe_001_research_outline.md) 的填写产出）。**这是上真机前的文档/源码调研结果，不替代真机 gate**（见 [`probe_001_ohos_webview_harvest.md`](probe_001_ohos_webview_harvest.md) §6 决策；最终 go/no-go 仍待真机，尤其能力 ③）。
> **关联**：issue #65 · ADR-016 §2.4 · ADR-015（`navigationAllow` / `success.whenUrlMatches`）· ADR-012 §2.2（凭证边界）。
> **调研对象**：HarmonyOS NEXT / OpenHarmony（OHOS）的 **ArkWeb** 引擎（自研 Chromium/Blink + V8，非 AOSP WebView）及 Flutter-OHOS 集成栈。
> **🔒 合规**：本文为调研结论，不含真机凭证；真机验证与收割实现仍按红线 #1 须人工主导 + 安全清单 + ≥1 人工审（AGENTS §1）。

---

## 0. 结论速览（按 outline §6 产出格式）

| 能力 | 结论 | 关键依据 | 真机要点 |
|---|---|---|---|
| **① cookie jar 可读（含 HttpOnly）** | ✅ **文档确认可行** | C-API `ArkWeb_CookieManagerAPI` 的 `getCookie(url, incognito, includeHttpOnly, cookieValue)` 显式暴露 `includeHttpOnly` 布尔位 → 宿主可穿透读 HttpOnly；ArkTS 层 `webview.WebCookieManager.fetchCookieSync(url)`（替代 @deprecated 旧接口）。 | CAS 跳完、等 `onPageFinished` 后读，断言含 `JSESSIONID`、无空串。 |
| **② 导航闭锁可拦（pre-navigation）** | ✅ **文档确认可行** | 锚定 `onOverrideUrlLoading`（主框架 + 302/303 每跳都触发、返回 `true` 抢占）；**不依赖** `onLoadIntercept`（对被动 302 不敏感、`loadUrl`/iframe 可能漏触发）。`flutter_inappwebview_ohos` 的 `OhosWebView.ets` 已把它桥接到 Dart 侧 `shouldOverrideUrlLoading`。 | 白名单 `ids`+`ehall`，验证 302 链每跳触发、越界链接被拦、`whenUrlMatches` 命中触发收割。 |
| **③ 隔离 profile + 用后销毁** | ⚠️ **文档模糊，需真机验证** | OHOS **无** `setDataDirectorySuffix` 等价的目录级硬隔离；多 `WebviewController` 实例**默认共享**同一 cookie/LocalStorage 持久层。只能用 `incognitoMode:true`（纯内存、关闭即 GC 清）侧面实现隔离 → 残留清除依赖 GC + 内核释放的异步时序，存在滞后窗口风险。 | 双实例隔离测试（A 登录、B 应未登录）；销毁后重开验证 cookie 已清；强制 `clearSessionCookieSync()` + `clearCache()` 兜底。 |

**选型裁定**：`flutter_inappwebview`（OHOS 移植 = `flutter_inappwebview_ohos`，已到 6.x，OpenHarmony-SIG 专仓，`OhosWebView.ets` 经 PlatformView 封装 ArkUI Web）= **当前最优可行路径**；`webview_flutter` OHOS 版高级 API 暴露受限（曾有白屏/控制器空指针），不足以承载 CAS 极端拦截。

**总体取向**：①② 文档级确认可行、选型确定 → **WebView 主路线在 OHOS 倾向成立（GO-leaning）**；③ 须真机定夺（隔离的强度与残留清除时序）。最终 go/no-go 待真机 ③ 验证后回写 ADR-016 §2.4。

---

## 1. 背景：ArkWeb 底座重构

OHOS（HarmonyOS NEXT / OpenHarmony）已剥离 AOSP，原 Android WebView 内核被全栈自研 **ArkWeb** 替代（Chromium/Blink + V8 底座，针对分布式架构与强隔离多进程沙箱深度定制）。其在**网络请求拦截时序**、**HttpOnly 穿透读取**、**跨进程桥接**上与 Android/iOS 有不同的底层安全语义 —— 架构层须做范式转移，不能照搬 Android 经验。

## 2. Flutter-OHOS 生态栈

- **SDK 对齐**：Flutter-OHOS 适配处于高活跃维护期，核心已支持到 Flutter 3.22.x（分支如 `3.22.0-ohos`），可复用 Dart 业务层并享受较新 Framework / Impeller 红利（OpenHarmony-SIG 仓库）。
- **`webview_flutter`（OHOS）**：官方移植入 `flutter_packages`，支持基础 URL 加载 / DOM 渲染；但早期有白屏、控制器空指针，高级 API（如网络级拦截配置）暴露受限 → 难承载极端鉴权拦截。
- **`flutter_inappwebview`（OHOS）**：社区功能最全、侵入性最强；OHOS 移植 = `flutter_inappwebview_ohos`（6.x）。`OhosWebView.ets` 经 PlatformView 封装 ArkUI 原生 Web；EventHub 事件总线映射 pull-to-refresh / startScripts / cacheEnabled 等；回调映射表完备（权限、上下文菜单、地理位置、全屏、及关键的 `onLoadIntercept` / `onOverrideUrlLoading`）。**→ 选定为 CAS 承载容器。**

## 3. 会话穿透与 Cookie 管理（能力 ①）

- **API 现代化**：API 9 起废弃实例绑定的 `WebController.getCookieManager()`，改用全局静态 `webview.WebCookieManager`；用 `fetchCookieSync` / `getCookie` 取代 @deprecated 旧接口。跨子域过滤（`ids.xidian.edu.cn` vs `.xidian.edu.cn`）需在应用层对 `;` 分隔的原始串自行正则拆解。
- **HttpOnly 穿透（决定性）**：C-API `ArkWeb_CookieManagerAPI` 的底层签名
  ```c
  ArkWeb_ErrorCode getCookie(const char* url, bool incognito, bool includeHttpOnly, char** cookieValue)
  ```
  `includeHttpOnly` 独立布尔位直接决定内核是否把 HttpOnly cookie 串入返回内存块 → 宿主持有合法控制器即可穿透读 `JSESSIONID` 级凭证。"前端不可见（防 XSS）≠ 宿主原生不可见"。
- **时序状态机**：
  - **注入前置**：`configCookieSync(url, value)` / `setStructuredCookie`（可配 Path/Domain/Secure/SameSite）须在加载周期初始化**前**完成。
  - **获取后置**：必须等 `onPageFinished`（至少 `onPageVisible`）再读 —— `Set-Cookie` 走内核异步队列，过早在 `onLoadIntercept` 读会拿到空串/陈旧值（持久层未落盘）。
  - **CORS + cookie**：仅前端 `withCredentials/credentials:'include'` 不够；需后端 `Access-Control-Allow-Credentials: true`（Origin 不可用 `*`）+ 原生层 `WebCookieManager.putAcceptCookieEnabled()` 全局解阀。

## 4. 导航闭锁状态机（能力 ②）

三个回调的语义辨析（**CAS 票据链必须锚定 `onOverrideUrlLoading`**）：

| 回调 | 层级 / 场景 | 阻断语义 | 对 302 重定向 |
|---|---|---|---|
| `onLoadIntercept` | 所有资源（主框架 + iframe 子资源）；偏防火墙被动拦截 | 返回 `true` 阻断、`false` 放行 | **不敏感**，`loadUrl` / 某些 iframe 可能不触发 → 易漏 |
| **`onOverrideUrlLoading`** | 主框架 / 定向导航的**主动路由接管** | 返回 `true` 宿主抢占中止加载、`false` 照常跳转 | **物理跳转前密集触发**，覆盖主动导航 + 被动 302/303 每一环 → **理想锚点** |
| `onInterceptRequest` | 数据包级，可构造自定义响应体 | 返回 `WebResourceResponse` 或 `null`（用原始流） | 不用于逻辑重定向；用于 mock / 本地资源 / 离线缓存 |

`ids` 密码校验通过 → 302 指回 `ehall` 时，ArkWeb 挂起域名解析，先拉 `onOverrideUrlLoading` 让宿主在真实加载前做票据清洗 / 白名单校验。`OhosWebView.ets` 已硬编码桥接：
```ts
.onLoadIntercept(this.inAppWebView!.inAppWebViewClient?.onLoadIntercept)
.onOverrideUrlLoading(this.inAppWebView!.inAppWebViewClient?.onOverrideUrlLoading)
.onInterceptRequest(...)
```
→ Dart 侧 `shouldOverrideUrlLoading`（跨端统一名）准确获参；越界链接拦截、特殊 scheme（`about:blank`/`javascript:`/`mailto:`）识别、拦截后页面销毁均"文档确认可行"。

## 5. 隔离 Profile 与销毁（能力 ③ — 需真机）

- **目录级硬隔离缺失**：OHOS 无 Android `setDataDirectorySuffix()` 等价的任意路径挂载 / 目录切片；多 `WebviewController` 默认**共享**同一 cookie 持久层 + LocalStorage 缓存树。
- **内存态 incognito 侧路**：`Web({src, controller, incognitoMode: true})` 划出纯内存（In-Memory）上下文，HTTP / `document.cookie` / DOM 缓存全约束在进程私有内存、与持久层切断。底层 C-API 取数时 `incognito` 布尔须显式置 `true`（常规空间与隐身空间标识在内存映射表正交，否则寻址被阻断）。`flutter_inappwebview_ohos` 的 `InAppWebView.ets` 对 `InAppWebViewSettings.incognito` 做了**动态增量监听**（非仅初始化生效）。
- **销毁**：incognito 组件 `onDisAppear` 卸载即随进程 GC 清空（含 IndexedDB）；非隐身 / 全局重置须主动 `clearSessionCookieSync()`（或遍历 `deleteCookie`）+ `WebviewController.clearCache()` 实现"阅后即焚"。
- **风险（须真机量化）**：残留清除依赖 ArkTS GC + 内核释放的**双边异步调度**，理论上存在敏感 Session Cookie 残留的滞后窗口 → 这是 ③ 必须真机压测的关键。

## 6. 附属安全 / 兼容能力（附加观测项）

- **JS 桥防污染**：仅在 `onControllerAttached`（早于任何 URL 加载 / DOM 解析）调 `registerJavaScriptProxy` 单向注入原生对象，构成防作用域污染的单向互信通道。**陷阱**：此钩子内调图形层 API（`zoomIn()` / 滚动等）会因 DOM/Frame 渲染树未初始化而抛运行时异常甚至崩溃。
- **UA 伪装**：`setCustomUserAgent` 必须在 `onControllerAttached`、`src` 仍为空串时抢先写入，再 `loadUrl`。**绝不可**在 `onLoadIntercept` / `onOverrideUrlLoading` 内动态改运行中请求的 UA → 会致协议栈状态机紊乱、静默断流 / 挂起。
- **SSL 异常接管**：旧 `onSslErrorEventReceive` 被弃，改用 `onSslErrorEvent`；强行信任自签 / 过期证书须显式 `event.handler.handleConfirm()`（无布尔暴力放行）；不显式确认则内核回调退出后永久阻断。⚠️ 等同应用层自担 MITM 风险，仅对确有必要的校内自签节点谨慎使用。
- **性能**：ArkWeb 默认独立 Web 渲染子进程（崩溃只触发 `onRenderExited`、OOM 隔离不波及宿主）。早期 `webview.WebviewController.initializeWebEngine()` 预热可省 ~300–500ms 首屏；`prefetchPage()` 可削 40%+ 转场等待。每个活跃实例（尤其并发 incognito profile）内存近线性增长，须关注。

---

## 7. 对 ADR-016 / 后续的影响

1. **WebView 主路线在 OHOS 倾向成立**：①② 文档级确认 + 选型（`flutter_inappwebview_ohos`）确定。最终 GO 待真机 ③。
2. **真机只带 ③ + 时序坑**：①②④ 多为"文档确认"，真机重点收窄到 —— ③ 隔离强度与残留清除时序（incognito 双实例串键、销毁后残留窗口），以及 ③ 之外需实测的时序锚点（`onPageFinished` 后读 cookie 的稳定性、302 链每跳 `onOverrideUrlLoading` 触发率）。
3. **实现约束已知**：cookie 读须等 `onPageFinished`；JS 注入 / UA 设置须在 `onControllerAttached`；隔离靠 incognito + 主动清除兜底；SSL 异常须显式 `handleConfirm`。这些直接进 WebView 收割实现的设计约束。
