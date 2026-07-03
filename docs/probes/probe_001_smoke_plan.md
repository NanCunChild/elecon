# Probe-001 真机执行计划 · 阶段一：工具链冒烟（凭证无关）

> **类型**：真机执行计划（[`probe_001_ohos_webview_harvest.md`](probe_001_ohos_webview_harvest.md) 的分阶段落地，先于完整三能力探针）。
> **决策依据**：桌面调研（[`probe_001_research_findings.md`](probe_001_research_findings.md)）已把 ① cookie/HttpOnly 可读、② 导航闭锁可拦定为「文档级确认」，选型锁定 `flutter_inappwebview_ohos`；真机唯一未决的是 **③ 隔离 profile + 残留清除时序**。
> **本阶段范围**：**仅验证工具链可用** —— OHOS 嵌入能生成、`flutter_inappwebview_ohos` 能 build/跑、WebView 能加载页面、cookie 能从宿主侧读出、`shouldOverrideUrlLoading` 能触发。**全程凭证无关**（不碰 CAS 登录、不收割 session）。
> **🔒 边界**：本阶段刻意不触红线 #1。完整 ③ 验收（XIDIAN IDS CAS 登录 + session 收割）是**下一阶段、人工主导**（AGENTS §1：AI 不得独自闭环），不在本计划内。

关联：issue #65 · ADR-016 §2.4 · [`probe_001_ohos_webview_harvest.md`](probe_001_ohos_webview_harvest.md)

---

## 0. 为什么先冒烟（不直接写完整探针）

- **`client/ohos/` 尚不存在**：OHOS 嵌入从未生成过，需先 `flutter create --platforms ohos` 落地平台目录。
- **Flutter 版本分叉**：主线/CI 锁 **3.44.1（官方）**；Flutter-OHOS 在 **~3.22.x-ohos**。OHOS 构建须切到**独立 FVM SDK**，官方 3.44.1 **不能** build OHOS。→ OHOS 探针与主线 `flutter test` 闸门**不共享 SDK**，须隔离对待（见 §4）。
- 在工具链未证可 build 前写完整三能力探针 = 可能整块返工。冒烟通过 = build/加载/读 cookie/拦导航四件事都成立，再投入完整探针成本最低。

---

## 1. 前置：环境搭建清单（可复现）

> 目标平台为 OHOS 真机（你已就绪）。版本/路径以**执行时实际值**为准。

- [x] **FVM 装独立 OHOS SDK**：`fvm fork add ohos https://gitcode.com/CPF-Flutter/flutter_flutter.git` + `fvm install ohos/br_3.27.4-ohos-1.0.4`（= **Flutter 3.27.5-ohos-1.0.4 / Dart 3.6.2 / engine e672b006cb**），与官方 3.44.1 并存。`fvm spawn ohos/br_3.27.4-ohos-1.0.4 config --enable-ohos` 开启 OHOS。**主线不切 SDK**，一次性命令用 `fvm spawn`，不污染 `client/.fvmrc`。
- [x] **华为 Command Line Tools + SDK + 环境隔离**：CLI Tools 6.1.1.280（HarmonyOS SDK 6.1.1 / API 24）装于 `/opt/ohos_cli_tools`。环境变量经 [`tools/ohos/`](../../tools/ohos/README.md) 的 `env.sh`（子 shell / direnv 隔离，不污染主 shell）+ `fvm spawn ohos/... config --ohos-sdk /opt/ohos_cli_tools/sdk/default/openharmony` 持久化。**`flutter doctor` 的 `[✓] HarmonyOS toolchain` 已点亮**（ohpm 6.1.2 / node v18.20.1 / hvigorw）。
- [ ] **真机签名 + 连接**：配 HarmonyOS 调试证书；连真机、开 USB/无线调试并在机上确认授权，`hdc list targets` 能看到设备（当前 `[Empty]`，待连）。
- [x] **生成 OHOS 嵌入**：`flutter create --platforms ohos`，生成 `client/ohos/`（PR #73，bundleName 暂占位 `com.example.elecon`）。**待真机 build 验证后合并**。
- [ ] **加 WebView 依赖**：`flutter_inappwebview`（6.x）+ OHOS 移植 `flutter_inappwebview_ohos`，**经 `dependency_overrides` 注入**。锁定实际版本后回填。
- [ ] **冒烟可跑**：`( source tools/ohos/env.sh && fvm spawn ohos/br_3.27.4-ohos-1.0.4 run -d <ohos-device> )` 能把空 app 推上真机。

**dependency_overrides 草样**（版本待锁定后回填，勿照抄版本号）：
```yaml
# client/pubspec.yaml —— 仅 OHOS 构建链路使用
dependencies:
  flutter_inappwebview: ^6.0.0
dependency_overrides:
  flutter_inappwebview_ohos:
    git:
      url: <OpenHarmony-SIG flutter_inappwebview_ohos 仓>
      ref: <锁定 tag/commit>
```

---

## 2. 冒烟标的（凭证无关）

用**公开、无登录**的页面，不用任何学校鉴权页：

- 首选 XIDIAN 公开通知页（与现有 `notice.list` 同域、零凭证），或任一稳定公开页（如 `example.com`）。
- 不输入任何账号口令；不触发 CAS；不读取/落盘任何 session/JSESSIONID 级凭证。冒烟读的 cookie 须是页面公开下发的非敏感 cookie。

---

## 3. 验收标准（四项，全部凭证无关）

| # | 验收项 | 判据 | 对应完整探针能力 |
|---|---|---|---|
| S1 | **WebView 能加载** | 真机上 `InAppWebView` 加载标的页、`onLoadStop` 触发、可见渲染（非白屏）。 | 选型可用性（`flutter_inappwebview_ohos` 真能跑） |
| S2 | **cookie 宿主可读** | `onLoadStop`（≥`onPageFinished`）后，`CookieManager.getCookies(url)` 读出**非空**、含标的页公开 cookie。 | ①（机制连通；HttpOnly 穿透留完整探针验） |
| S3 | **导航回调触发** | 点站内链接/触发一次跳转 → `shouldOverrideUrlLoading` 被调用、能拿到目标 URL、`return true` 能拦下。 | ②（锚点 `onOverrideUrlLoading` 在真机确触发） |
| S4 | **incognito 实例可建** | 以 `incognito: true` 建实例能正常加载、`onDisAppear`/销毁不崩。 | ③ 的**前置**（隔离/残留时序的强度仍留完整探针真机压测） |

> S2/S3 时序坑（来自调研）：cookie 必须等 `onLoadStop`/`onPageFinished` 后读（`Set-Cookie` 走内核异步队列，过早读空串）；UA/JS 注入须在 `onControllerAttached` 且 `src` 仍空时设。冒烟即顺带验证这些锚点在真机的真实时序。

---

## 4. 产物与 CI 处置

- **代码落点**：建议 `client/` 下独立 probe 入口（如 `client/tool/ohos_probe/` 或 `--dart-define` 切换的 debug-only 屏），**不进 release**（与红线 #4/#5 的 debug-only 例外同范式：探针/侧载路径编译期从发版剔除）。
- **不进主线 CI**：OHOS 在分叉 SDK（§0），主线 `flutter test`（官方 3.44.1）跑不了 OHOS；冒烟为**真机手动门**，证据按 [`probe_001_ohos_webview_harvest.md`](probe_001_ohos_webview_harvest.md) 的证据格式留档，不做自动闸门。
- **证据**：S1–S4 各留一条日志/截图（cookie 值打码，红线 #8），回填本文。

### 4.1 OHOS 兼容基线 + 上游漂移检查点

> **优先级：低（OHOS 整体挂起）**。Android / iOS 主线跟进官方 Flutter stable；OHOS 等待 OpenHarmony-SIG fork 更新或官方主线支持。本节只做「记账」，不设定期任务、不进 CI 闸门——需要时（下次 OHOS 打包前）翻本节即可。

**为什么要有基线**：OHOS 那条线的 Dart 由 OpenHarmony-SIG 的 Flutter-OHOS fork 决定，非我方可选，当前停在 **Dart 3.6.2**（fork `ohos/br_3.27.4-ohos-1.0.4` = 3.27.5-ohos-1.0.4）；主线 Android/iOS 用官方 Flutter 3.44.1（Dart 3.12.1）。两条线**语言/依赖 SDK 约束不对齐**，风险都在边界。

**兼容基线（当前值）**：

| 项 | 主线（Android/iOS） | OHOS fork | 约束 |
|---|---|---|---|
| Flutter | 官方 3.44.1 | 3.27.5-ohos-1.0.4 | — |
| Dart | 3.12.1 | **3.6.2** | OHOS 下限 = **3.6.2** |

- **主线优先**：Android / iOS 不受 OHOS fork 的 Dart 3.6.2 约束。主线可使用官方 stable 支持的语法/API/依赖版本，`pubspec.lock` 也按主线 stable 解析。
- **OHOS 兼容债务**：若主线用了 OHOS fork 暂不支持的语法/API/依赖，先记为 OHOS 恢复时要处理的兼容债务，不阻塞 Android / iOS。OHOS 打包前再核对 fork 是否已跟进；未跟进时再做 fork/override/降级或等待上游。

**上游漂移检查点（无需定期，OHOS 打包前核对即可）**：

- [ ] OpenHarmony-SIG 是否发了更高的 Flutter-OHOS br 分支（能否升 Dart 下限）。
- [ ] **官方主线是否已支持 OHOS**——若是，整个 fork 体系（Flutter-OHOS SDK + `flutter_inappwebview` fork）可退役，这是最想要的终局。
- [ ] fork 依赖 `NanCunChild/flutter_inappwebview @ 9fa5a533` 上游（gitee `openharmony-sig` @ `bfc8e52c`）是否有需要跟进的修复。

---

## 5. 冒烟通过后 → 完整探针（下一阶段，人工主导）

S1–S4 全绿 = 工具链 + 选型在 OHOS 真机坐实，于是进完整探针：
- ① HttpOnly 穿透读（`getCookie(..., includeHttpOnly=true, ...)`）拿 CAS 后 `JSESSIONID`；
- ② `navigationAllow` 白名单闭锁（`ids`+`ehall`）+ `success.whenUrlMatches` 命中触发收割（ADR-015）；
- ③ **真机重点**：incognito 双实例隔离（A 登录、B 应未登录）+ 销毁后残留窗口压测（`clearSessionCookieSync` + `clearCache` 兜底时序）。

→ 标的 = XIDIAN IDS CAS（滑块用户手解），结论回写 **ADR-016 §2.4** 定最终 go/no-go。
**🔒 该阶段触红线 #1**：登录收割代码 + 测试须人工主导 + 安全清单 + ≥1 人工审，AI 不独自闭环。
