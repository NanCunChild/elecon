# SDK 与 Flutter 宿主组件

[返回目录](README.md) · 相关：[卡片模板](cards.md)、[按钮响应](interactions.md)

## 按需选择 SDK

以下列出常用接口的最低版本，完整旧接口见 [types.d.ts](../../contract/script-sdk/types.d.ts)，SDK17 全局接口见 [sdk17.d.ts](../../contract/script-sdk/sdk17.d.ts)。既有示例保留其最低版本；新标准 API 示例明确使用 SDK17，旧包不自动升级。

| 最低 SDK | 功能 |
|---|---|
| 2 | 完整凭据地址与 namespace 语义 |
| 3 | `ctx.ui.requestInput` |
| 4 | `manifest.home`、浏览器 setBusy |
| 6 | `manifest.cards` 有限模板建议 |
| 7 | `manifest.homeTitle` |
| 8 | scanner 声明与扫码 |
| 9 | 独立 WebSocket origins 与前台连接 |
| 10 | 前台照片/选图/位置、二进制 HTTP body |
| 11 | 必填 accounts 说明与登录绑定 |
| 12 | 显式卡片 id/title、账号状态和宿主 APPTunnel 端口 |
| 13 | 包内 localization 与 ctx.i18n/locale |
| 14 | 保存密码、账号事件、包内 HTML/固定 DOM |
| 15 | 声明账号到指定网关的凭据复用 |
| 16 | 脚本声明隧道账号、能力/账号隧道依赖 |
| 17 | 全局 elecon、缓冲 Web API 子集、结构化桥接错误与包命名空间业务错误 |

`query.controls` 是业务能力 1.0，沿用现有 SDK 授权。SDK16 可声明院校与身份类型的展示分组：

```json
{
  "school": {
    "id": "demo-university",
    "name": "示例大学",
    "type": { "id": "undergraduate", "name": "本科生" }
  }
}
```

`school.id/name/type` 用于选校分组与标题，原有 `schoolId` 继续决定凭据、缓存和执行授权范围。同一大学不同身份类型不会因此共享凭据。细节见 [ADR-079](../adr/adr_079_school_presentation_and_titles.md)。

## SDK17：普通 JS 与宿主命名空间

SDK17 在导入 ES 模块前提供全局 `elecon` 与下表中的 Web API。能力仍是普通异步函数；传入的 `ctx` 与 `elecon` 是同一当前调用上下文，不需要为旧代码增加包装器。凭据、账号、原生输入、浏览器与业务错误等专有 API 使用 `elecon.credentials/accounts/ui/browser/errors`；可用端口仍受包声明、版本和平台支持约束。

```js
export const capabilities = {
  "notice.list": async () => {
    const response = await fetch("https://campus.example.edu/api/notices", {
      headers: new Headers({ Accept: "application/json" })
    });
    if (!response.ok) throw elecon.errors.create("notice_http_failed");
    const data = await response.json();
    // 实际学校字段在此归一；这个示例假定 items 已符合 notice.list 的结构。
    return { items: data.items };
  }
};
```

manifest 必须使用 SDK17、声明目标 origin 和对应能力。`fetch` 复用已有授权网络端口，没有额外联网权限、自动登录或自动 Cookie jar。模块顶层可定义函数/常量；不要把认证或有副作用请求放在顶层，导入本身就会执行这些语句。

| API | 已支持 | 明确限制 |
|---|---|---|
| `Headers` | 构造、读写、迭代、`getSetCookie()` | fetch 响应头不可修改；受信宿主提供 Cookie 头，不模拟浏览器 CORS 过滤 |
| `Request` / `fetch` | 绝对 HTTP(S) 字符串或 Request；method、headers、body、redirect、signal | 未知选项拒绝；无 URL 构造器，地址由宿主在发送时验证；CONNECT/TRACE/TRACK 拒绝；GET/HEAD 不带 body |
| 请求 body | 字符串、ArrayBuffer、typed array 视图，复制后传递 | 无 Blob、FormData、流式 body；沿用宿主大小预算 |
| `Response` | status/ok/url/statusText/headers/type；text/json/bytes/arrayBuffer；读取前 clone | 全量缓冲；有正文只读一次；text/json 使用 UTF-8；真实响应 statusText 为空，无 redirected 属性；不伪造未知传输信息 |
| `AbortController` / `AbortSignal` | abort、aborted/reason、throwIfAborted、add/removeEventListener、onabort、静态 abort | 无静态 any/timeout；默认错误为名为 AbortError 的 Error，不提供 DOMException |

`AbortSignal` 已取消时不发请求；请求进行中取消会拒绝 JS Promise，并丢弃晚到结果。它**不保证撤回已经发送的原生请求**，尤其不能当作源站写操作已回滚。宿主整次调用的取消、身份检查和传输关闭仍由会话层执行。

此运行环境没有完整 DOM、Node、浏览器缓存/CORS、URL/URLSearchParams、streams 或浏览器式 WebSocket 构造器。现有 `elecon.websocket` 保留有界收发端口。需要旧 SDK 的重复读取响应、显式 Latin-1 或旧错误行为时继续使用 `ctx.fetch`；它的版本语义不因全局标准 API 增加而改变。后续标准库扩展按实际实现与兼容验证增加，不以近似实现冒充完整标准。

SDK17 类型与[编译示例](../../contract/script-sdk/examples/)可用于编辑器和构建检查，使用 ES2022 lib，不混入完整 DOM 类型。运行 `npm run scripts:check-sdk -w tools` 检查类型示例；可直接打包的[普通 JavaScript 模板](../../adapters/_template/trusted/standard-js/README.md)展示模块顶层构造标准对象、全局 fetch 和普通辅助函数。没有独立的声明式 action 或错误恢复 DSL，学校流程继续用函数调用、`try/catch` 与返回值表达；持久调度及长期网页生命周期仍是待实施接口。

## 从旧 ctx 接口迁移到 SDK17

迁移以一个学校包为单位进行，不需要重写全部模块。先把 manifest 的 `sdkVersion` 提升到 17，并提升包 `version`；保留学校身份、原有能力/schema、网络范围与账号声明。使用支持 SDK17 的宿主重新审查安装，新接口不会给已安装旧包自动授权。

| 旧写法 / 假设 | SDK17 迁移方式 |
|---|---|
| `handler(ctx, params)` | 原签名继续使用；也可在函数内通过全局 `elecon` 调用同一上下文 |
| `ctx.credentials`、`ctx.accounts` 等 | 可逐个改成 `elecon.credentials`、`elecon.accounts`，无需额外声明第二份权限 |
| `ctx.fetch(url, init)` | 可保留；要采用全局 `fetch` 时，逐项核对 body、headers、读取次数及错误处理 |
| 响应先 `text()` 再 `json()` | 全局 Response 的有正文对象只能消费一次；需要两份时先 `clone()` |
| 按响应 charset 读 Latin-1 | 全局 `text/json` 使用 UTF-8；需要旧解码语义时保留 `ctx.fetch` 或读取 bytes 自行解码 |
| `headers.raw()` | 全局 Headers 使用 entries/迭代；Cookie 多值用 `getSetCookie()`；raw 只在旧接口存在 |
| 用异常 message 正则判断业务 | 改为稳定 `code` / `businessCode`，学校私有流程可使用自己的普通 Error 子类 |
| `AbortSignal.timeout()`、URL、FormData 等浏览器习惯 | 当前不提供，不能只改 SDK 版本就直接调用；支持清单见上文 |

SDK 版本变化不自动改变业务数据版本。`notice.list/1.1` 仍须返回它的字段，不能返回 `Response`、`Request` 或 Error 实例；这些对象只在一次 JS 执行内部使用。迁移后先跑脚本合成测试，再跑实际 QuickJS/工作台；Node 可以执行代码不代表宿主已具备所用 API。

## 请求与响应的复制、取消

以下均为 SDK17 普通辅助代码，地址与数据为合成示例，不发起真实学校业务。

```js
// 离线示例：读取前 clone，分别读取两份缓冲区。
async function inspectPayload() {
  const response = Response.json({ items: [] });
  const copy = response.clone();
  const data = await response.json();
  const text = await copy.text();
  return { itemCount: data.items.length, text };
}
```

`clone()` 复制已缓冲正文，会占用额外内存；通常只读取一次再复用解析结果即可。已经消费的正文不能再次读取或克隆。Request 同样有正文消费状态：`fetch(request)` 会消费所用请求正文；需要在提交前检查请求内容时先克隆供本地读取，而不是为了失败后重发保留副本。

```js
// 仅本地构造和检查，不发送 POST。
async function inspectRequest() {
  const request = new Request("https://campus.example.edu/api/filter", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ term: "demo-term" })
  });
  const payload = await request.clone().json();
  return { payload, originalBodyUsed: request.bodyUsed };
}
```

调用内多个只读请求可以共享一个 AbortController；用户操作或脚本自己的控制分支调用 `abort()` 后，这些请求的本地等待一起结束。以下例子先取消再调用，保证不会进入网络端口：

```js
async function cancelledRead() {
  const controller = new AbortController();
  controller.abort();
  try {
    await fetch("https://campus.example.edu/api/notices", {
      signal: controller.signal
    });
  } catch (error) {
    if (controller.signal.aborted && error === controller.signal.reason) {
      return { kind: "cancelled" }; // 内部辅助函数结果，不是 notice.list 输出。
    }
    throw error;
  }
  throw new Error("expected_abort");
}
```

默认取消原因是名为 `AbortError` 的 Error；如果使用 `abort(customReason)`，应按 signal.reason 判断，而不假定总有这个 name。signal 一旦取消不能复位，新操作需要新的 controller。请求发出后的取消只停止等待并丢弃迟到结果；取消后也不能继续消费关联 Response 的正文。远端副作用是否发生仍须按学校协议核实。

## HTTP 调用（既有 ctx 接口）

以下是使用虚构学校协议的请求函数；manifest 需声明 `https://campus.example.edu`。返回值仍须由能力处理器转换成对应标准 schema。

```js
async function fetchSchoolNotices(ctx) {
  const response = await ctx.fetch("https://campus.example.edu/api/notices", {
    method: "GET", redirect: "manual", headers: { Accept: "application/json" }
  });
  if (response.status === 401) {
    throw Object.assign(new Error("authentication_required"), { code: "authentication_required" });
  }
  if (!response.ok) throw new Error("notice_http_failed");
  const data = await response.json();
  if (!data || !Array.isArray(data.items)) {
    throw Object.assign(new Error("source_response_invalid"), { code: "source_response_invalid" });
  }
  return data.items;
}
```

response 提供 status/ok/url，headers 的 `get/getSetCookie/raw`，以及 `text/json/bytes/arrayBuffer`。没有自动 Cookie jar、自动认证或学校签名；登录与重定向需要中间 Cookie 时使用 manual 并由脚本逐跳处理。

`network.origins` 精确匹配协议、主机和端口，不接受路径或通配符；每次跳转重新检查。可选 `ipAllow` 是额外 IP 限制，空数组会拒绝全部连接，不会授予新域名。允许校内 origin 不等于已取得查询或共享私密数据的授权。

text/json 支持 UTF-8/ASCII 和显式 Latin-1；其他编码可能报 `unsupported_encoding`，用 bytes 配合学校侧解码器处理。SDK10 的 Uint8Array body 最多 1 MiB；构造 multipart、签名或协议消息仍由学校脚本实现。

WebSocket 独立声明 `websocketOrigins:["wss://service.example.edu"]`，HTTP origins 不授予连接权限。调用 `ctx.websocket.open/send/receive/close`，每次执行最多一条前台 TLS 连接、30 秒，禁止自动重连；完整预算见 SDK 类型。

## 脚本多语言

SDK13+ 的 manifest 片段：

```json
{
  "localization": {
    "defaultLocale": "zh",
    "messages": {
      "zh": { "query.title": "查询条件", "hello": "你好，{name}" },
      "en": { "query.title": "Query options", "hello": "Hello, {name}" }
    }
  }
}
```

```js
const title = ctx.i18n.t("query.title");
const greeting = ctx.i18n.t("hello", { name: "Student" });
```

`ctx.locale` 是请求语言，`ctx.i18n.locale` 是包字典实际匹配语言。按精确、语言+文字系统、基础语言、默认语言回退；作者可选择核心界面尚未翻译的语言。默认字典定义完整 key，其他字典不能新增 key 或改变占位符；支持 `{name}`，不支持 ICU、HTML 或表达式。动态模板文案按调用返回，静态账号/卡片声明不会自动变成翻译键。

核心 Flutter 文案使用项目 ARB，不从学校字典覆盖全局界面。修改语言取消旧调用，相关缓存按请求语言区分。字段及大小限制见 [SDK 类型](../../contract/script-sdk/types.d.ts)，作者选用语言可查[语言代码参考](../reference/script_language_codes.md)。

## Flutter：复用现有业务组件

以下是**仓库内部 Flutter 用法**，不是学校 JS API 或稳定的外部 UI SDK。现有页面需放在已有 SessionScope/主题/本地化环境中；`package` 来自当前学校已经批准、启用的安装记录。

直接复用成绩区域，并固定来源：

```dart
import 'package:flutter/widgets.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/grades_section.dart';

Widget buildGrades(ScriptPackage package) => CapabilitySourceScope(
  source: CapabilitySource(
    packageId: package.manifest.id,
    digest: package.digest,
  ),
  child: const GradesSection(),
);
```

`CapabilitySourceScope` 保留来源，跨路由使用同文件中的 `openCapabilityPage(context,page)` 继续传递。不要在详情页面重新按全局默认 provider 获取实体，避免把一个来源的 ID 交给另一个来源。

只读能力调用使用会话层共同入口：

```dart
import 'package:elecon/session/capability_query.dart';
import 'package:elecon/session/session_controller.dart';

Future<Object?> readGrades(SessionController session, CapabilitySource source) async {
  final result = await CapabilityQueries(session, source: source).runCapability(
    'grades.list',
    params: const {'term': 'demo-term'},
    interactive: false,
  );
  if (!result.ok) return null; // 产品组件需按 failureKind/reason 渲染相应状态。
  return result.data; // 使用前继续经领域解码器转换；不是任意 UI 字段。
}
```

该函数只演示请求。异步结果写回 UI 前应核对 mounted、请求序号、来源和 `trustedScriptViewGeneration`；现有 [CachedQuerySection / runOnceDecoded / isCurrentQuery](../../client/lib/ui/home/query_section.dart)提供复用方式。缓存 API 用 `CapabilityQueries.cachedCapability/latestCachedCapability`，不要自行复制存储或刷新时间。

## Flutter：添加明确的前台按钮

[ForegroundRequestSection](../../client/lib/ui/home/foreground_request_section.dart)封装来源、执行、浏览器/输入呈现、取消、前后台和忙碌状态。以签到入口为例，实际能力必须由该包声明并实现：

```dart
import 'package:flutter/material.dart';
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/foreground_request_section.dart';

Widget buildCheckIn(
  SessionController session,
  ScriptPackage package, {
  required String title,
  required String buttonLabel,
  required Widget Function(BuildContext, String, CapabilityRun) resultBuilder,
}) => ForegroundRequestSection(
  session: session,
  package: package,
  title: title,
  actions: [
    ForegroundRequestAction(
      capability: 'attendance.checkin',
      label: buttonLabel,
      icon: Icons.qr_code_scanner,
      params: () => const {},
    ),
  ],
  resultBuilder: resultBuilder,
);
```

title/buttonLabel 来自调用方本地化。此处 `actions` 是 **Dart 组件构造参数**，不是 manifest 字段。组件不缓存命令结果；构建按钮不会发起请求，用户点击才执行。resultBuilder 要按 confirmed/cancelled/unknown 等领域状态呈现，不能把一次 HTTP 成功直接当签到成功。

## 新增宿主模板时改哪里

| 层 | 现有入口 | 职责 |
|---|---|---|
| 能力查询与固定来源 | [capability_query.dart](../../client/lib/session/capability_query.dart) | 统一调用、缓存入口 |
| 页面公共查询状态 | [query_section.dart](../../client/lib/ui/home/query_section.dart) | loading、缺配、登录、失败、stale、迟到结果 |
| 领域区域与结果展示 | [home/](../../client/lib/ui/home/) 的 `*_section.dart`、`result_cards.dart`、`decoders/` | 原生组件与领域解码 |
| 首页组装 | [home_page.dart](../../client/lib/ui/home/home_page.dart) | 卡片类型映射、来源和页面组合 |
| 布局 | [card_layout.dart](../../client/lib/ui/home/card_layout.dart)、[editable_card_board.dart](../../client/lib/ui/home/editable_card_board.dart) | 尺寸、排序、显隐及用户布局 |
| 浏览器容器 | [script_browser_surface.dart](../../client/lib/ui/scripts/script_browser_surface.dart) | 统一来源提示与关闭、清理 |

现有标准数据能表达的新页面可复用领域组件；新 `cards.type` 需要同步宿主、包 schema 与校验，不是仅加一行 manifest。新能力/字段语义或核心抽象变化先按[功能工作流](../rules/feature_workflow.md)写 ADR，更新注册表、schema、SDK、生成物、消费者和 CHANGELOG。学校选择器、密码协议和签名留在学校脚本。
