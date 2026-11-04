# 交互、查询条件与按钮响应

[返回目录](README.md) · 相关：[卡片模板](cards.md)、[宿主调用](sdk-and-host.md)

## 选用哪种交互

| 需求 | 使用方式 |
|---|---|
| 成绩学期、空教室日期/名称/时段 | 同包 `query.controls`，宿主提供固定输入与提交按钮 |
| 缺少业务资料，前台临时输入 | `ctx.ui.requestInput` |
| 账号密码与保存密码 | [账号登录入口](accounts.md)，使用 `ctx.accounts.password` |
| 空调开关、温度等 | 原生空调按钮 → `climate.command` → 单独查状态 |
| 扫码签到、消息发送等主动请求 | 原生前台按钮调用既有领域能力 |
| 学校自定义表单布局 | [包内 HTML + 固定 DOM](browser.md#包内网页与表单) |

脚本没有 `ctx.onClick`、通用事件总线或任意按钮注册 API。能力导出函数就是宿主调用入口；按钮可以由既有原生模板提供，也可由宿主开发者在 Flutter 中实现。不要在 manifest 增加 `actions`，当前打包器和解析器拒绝该字段，包括空数组。

## 一次调用的生命周期

原生卡片、工作台和页面按钮最终调用同一个注册处理器。宿主在排队前捕获参数快照与明确来源，实际执行时再核对当前学校、批准 digest 和取消状态；等待期间修改调用方对象不会改写已排队的参数。

一次执行先建立当前上下文（SDK17 同时提供全局 `elecon` 与标准 API 子集），再导入模块，随后调用处理器并传入 `ctx`、等待它的 Promise；返回后校验业务输出并清理运行资源。模块顶层状态可以在本次调用内复用，但不能当作跨调用持久存储。需要跨调用的学校凭据使用凭据端口，页面长期状态按已有宿主管理方式保存。

| 场景 | 作者应如何处理 |
|---|---|
| 先获取参数目录再查询 | 普通辅助函数和 `await` 顺序组合；只把需要宿主独立调用的函数导出为能力 |
| 多个互不依赖的只读请求 | 可用 `Promise.all`，仍共享本次调用的身份、网络与资源预算 |
| 请求输入、扫码或登录 | 在交互调用内请求；这些输入有各自预算，并且仍计入整次调用时间 |
| 处理器启动 Promise 后立即返回 | 未完成工作不具有后台任务保证；把需要完成的工作纳入返回的 Promise |
| `setTimeout` 或等待循环 | 只属于当前短调用，受宿主取消和执行预算约束；不构成持久任务 |
| 希望明天自动选课、页面常驻注入 JS | 属于长期网页/持久计划切片，当前 SDK17 没有可安装的调度声明 |

当前会话通常给无交互/只读状态检查 35 秒，具备现有交互条件的前台调用最多 120 秒；具体分配由宿主决定。脚本不能通过自己的计时器延长调用寿命，也不能假设 UI 关闭、切身份、更新或应用退出后工作继续运行。将流程拆成普通函数有利于复用，但不能绕过整体预算。

前台输入取消的返回值以具体 API 为准，例如 requestInput 返回 null；全局 fetch 的 AbortSignal 则拒绝 Promise。先在内部规范化自己流程需要的状态，再按能力 schema 返回；不要把取消统一伪造为空业务数据。验证码/MFA 独立会话与自动调度的未来设计见[统一计划](../planning/implementation.md#受信扩展)。

## 查询条件与提交按钮

增加能力声明：

```json
{
  "capabilities": [
    { "id": "grades.list", "schema": "elecon.grades.list", "schemaVersion": "1.1" },
    { "id": "query.controls", "schema": "elecon.query.controls", "schemaVersion": "1.0" }
  ]
}
```

宿主以 `{"target":"grades.list"}` 查询同包元数据。合成处理器如下；真实选项应来自该学校 `term.list` 等已验证来源。

```js
export const capabilities = {
  async "query.controls"(ctx, params = {}) {
    if (params.target !== "grades.list") throw new Error("input_invalid_request");
    return {
      target: "grades.list", title: "成绩条件", submitLabel: "查询成绩",
      controls: [{
        id: "academic-term", kind: "select", label: "学期", parameter: "term",
        initialValue: "demo-term",
        options: [{ value: "demo-term", label: "示例学期" }]
      }]
    };
  }
};
```

用户点“查询成绩”后，宿主才应用参数并调用同包 `grades.list({term:"demo-term"})`。此处括号表示能力请求的参数形状，脚本内没有自动生成的 `grades.list()` SDK 函数。取消保留原条件和结果；元数据失败保留已显示内容。

| target | 控件 kind | parameter | 说明 |
|---|---|---|---|
| grades.list | select | term | 选项 value 是学校学期 ID，label 是文案 |
| classroom.available | date | date | YYYY-MM-DD，真实日历日期 |
| classroom.available | text | room | 空值表示移除条件 |
| classroom.available | timeRange | start | 同时生成 start/end，HH:mm，同日且结束晚于开始 |

最多八项，控件 id 和绑定参数各自唯一。select 最多 200 个唯一选项值；timeRange 默认值使用 `initialValue` 和 `initialEnd`，必须同时给出。控件不接函数、URL 或任意学校 filters。`query.controls` 本身是无交互只读查询，不缓存、不预加载，也不能弹登录。

查询来源固定在目标卡片的包及 digest，不按 `query.controls` 的全局覆盖另选包。未提供该能力的旧包沿用原生输入。详见 [ADR-071](../adr/adr_071_script_query_controls.md)与[实际学校实现](../../school-scripts/xidian/src/query_controls.js)。

## 临时原生输入

SDK3+ 的 `ctx.ui.requestInput` 支持 text/password/select。以下函数可用于用户明确进入配置流程时收集信息；宿主不自动保存输入，也不自动重跑查询。

```js
async function requestCampus(ctx) {
  const answer = await ctx.ui.requestInput({
    title: "补充查询信息",
    message: "请选择本次查询校区。",
    fields: [{
      id: "campus", label: "校区", type: "select",
      options: [{ label: "示例校区", value: "demo-campus" }]
    }]
  });
  if (answer === null) return null;
  if (answer.campus !== "demo-campus") throw new Error("input_invalid_request");
  // 学校脚本自行决定是否需要受保护保存，或仅用于本次请求。
  return answer.campus;
}
```

每张表单 1–8 字段，默认 required=true、maxLength=128，上限 4096；select 最多 20 项。密码不允许默认值。请求最多 32 KiB，每次执行最多八次顺序表单，不允许并发；取消返回 null。输入表单不暂停整个调用的预算，后台执行拒绝交互。

缺少必需业务资料可抛固定错误：

```js
throw Object.assign(new Error("configuration_required"), { code: "configuration_required" });
```

宿主记录当前来源、参数和身份的待配置状态，整体刷新跳过；用户明确配置成功后恢复。网络、认证、解析失败不能编码为缺配，也不要返回虚假空列表表示失败。

## 空调控制按钮

需要提供同包 `climate.devices/status/command`，按钮只允许设备声明的命令。请求示例：

```json
{
  "deviceId": "demo-device",
  "command": "temperature",
  "settings": { "targetTemperature": 26 }
}
```

`settings` 还需满足设备模式与联动规则，不能原样转发任意学校 JSON。下面是**协议骨架**，`requireBoundDevice`、`validateDeviceSettings` 和 `sendSchoolCommandOnce` 由学校代码实现：

```js
export const capabilities = {
  async "climate.command"(ctx, params) {
    const device = await requireBoundDevice(ctx, params.deviceId);
    validateDeviceSettings(device, params.command, params.settings);
    // 此函数只发送一次，不包含密码恢复后重试、网络重试或其他来源回退。
    // 返回 accepted/rejected/unknown；只有独立状态证据才可返回 applied。
    return sendSchoolCommandOnce(ctx, device, params.command, params.settings);
  }
};
```

新受信脚本按 [ADR-046](../adr/adr_046_triggered_script_requests.md)：用户点击触发一次控制发送，页面随后查询一次 `climate.status`。运行中禁重复点击，不额外确认、不乐观修改设备状态。响应 accepted 不等于已生效；提交可能已发生但无确认时保留 unknown，失败不自动重发。命令不得放入 home，也不能在构建页面、预加载或恢复认证时执行。V1 保持自身旧确认门。

现有学校实现见 [climate.js](../../school-scripts/xidian/src/climate.js)，宿主行为见 [energy_climate_sections.dart](../../client/lib/ui/home/energy_climate_sections.dart)。

## 扫码、照片和位置

只声明需要的权限：扫码需要 SDK8+ 的 `scanner:true`；照片/选图/定位需要 SDK10+ 的 `deviceInputs`。以下是 manifest 片段，非所有脚本都应声明这些输入：

```json
{ "scanner": true, "deviceInputs": ["camera", "image", "location"] }
```

```js
const qr = await ctx.ui.scanQRCode();
const photo = await ctx.ui.capturePhoto();
const selectedImage = await ctx.ui.pickImage();
const position = await ctx.ui.getCurrentPosition();
```

上面四行是独立 API 调用展示，实际流程按需要选择并逐次处理 null 取消，不要无条件连续弹出全部输入。扫码只返回 `{text,format:"qrCode"}`，不会打开 URL 或自动提交签到。图片为去文件路径/EXIF 后的 PNG bytes，位置为 WGS84 十进制度、精度米和 UTC 取得时间；拍照不等于通过人脸或活体验证。

原生输入只在前台使用，与表单等交互互斥；身份变更、取消和离页后，晚到输入不能写回。完整数据预算和二进制提交方式见 [SDK 类型](../../contract/script-sdk/types.d.ts)及[签到模板](../../adapters/_template/trusted/attendance/README.md)。

消息发送同样由明确按钮触发，`messages.send` 传 accountId、conversationId、conversationKind、clientId、text。只有匹配服务器 messageId 才能确认 sent，unknown 不得重发；界面不能凭离线历史授予发送权限。
