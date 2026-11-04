# 交互、查询条件与按钮响应

[返回目录](README.md) · 相关：[卡片模板](cards.md)、[宿主调用](sdk-and-host.md)

## 选用哪种交互

| 需求 | 使用方式 |
|---|---|
| 学校自定义的成绩/空教室筛选条件 | 同包 `query.controls` 2.1（兼容 2.0），脚本创建通用控件实例，宿主渲染表单 |
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

### 2.0：脚本创建字段

依据 [ADR-082](../adr/adr_082_script_query_forms.md)，核心提供控件种类，脚本决定字段实例。核心没有一套预置的“座位数/楼层”开关；任意学校字段可以重复使用数字、文本等控件，无需修改宿主代码。当前支持目标仍为 `grades.list` 和 `classroom.available`。

同包声明 `query.controls` 的 `schemaVersion: "2.0"`，以及目标领域能力。第一次读取可以省略 current 或传入空对象，例如 `{"target":"classroom.available","current":{}}`；依赖条件变化时为 `{"target":"classroom.available","current":{"campus":"demo"},"changed":"campus"}`。current 只包含字段草稿值，不包含宿主调用配置。

下面是可返回的合成表单；它展示同一种数字控件可创建多个业务字段，不表示每所学校必须支持这些条件：

```json
{
  "target": "classroom.available",
  "title": "教室筛选",
  "submitLabel": "查询",
  "controls": [
    {"id":"minimumSeats","kind":"number","label":"教学座位数至少","integer":true,"minimum":1},
    {"id":"maximumFloor","kind":"number","label":"最高楼层","integer":true,"minimum":1},
    {"id":"accessible","kind":"boolean","label":"需要无障碍设施"}
  ]
}
```

提交值为 `{"filters":{"minimumSeats":40,"maximumFloor":3,"accessible":true}}`；字段名不提升成顶层参数。脚本必须检查允许的字段、类型及组合，再映射源站请求或过滤完整响应。学校未提供容量或设施信息时不声明相应字段，未知数据不能当成满足条件。

| kind | 值 | 主要约束 |
|---|---|---|
| text | 字符串 | maxLength，可选空值省略 |
| number | 有限数字 | minimum/maximum，integer=true 表示整数；0有效 |
| boolean | 布尔值 | false有效，与省略不同 |
| select | 字符串 | 必须属于 options 的 value |
| multiSelect | 不重复的字符串数组 | 至多32项，必须属于 options |
| date | YYYY-MM-DD字符串 | 真实日历日期 |
| timeRange | `{start,end}`，HH:mm | 同日start<end；控件提供timeZone说明学校时区 |

每项的 id/kind/label 必填；description、required、disabled、disabledReason、initialValue 和 dependsOn 可选。字段 id 稳定唯一、符合 `[a-z][a-zA-Z0-9._-]{0,63}`，不能使用 constructor/prototype/__proto__。最多32字段、每个选择字段200选项、字符串512字符；filters/current至多32KiB，元数据至多128KiB。空 controls 合法，表示当前没有学校筛选项。

依赖用 `dependsOn:["campus"]` 表达。上级改变时清除下级草稿，再调用同包 query.controls 读取新选项。引用必须存在且无环。未选择上级时可以返回 disabled=true、disabledReason="请先选择校区"、options=[]；元数据读取失败由页面显示失败/重试，不要伪装成没有选项。迟到响应不能覆盖新的草稿；只有最终提交才执行领域查询，取消不会应用草稿。禁用字段和未声明字段不提交。

默认值只在字段首次出现且缺少值时初始化，不能覆盖有效草稿，也不重新填充用户清除或依赖变化清除的字段。动态选项由学校代码读取，核心不执行学校表达式；字段的私有业务含义不要求标准语义绑定。本版没有把字段名/中文标签解释为自动跨学校参数的机制。

查询、缓存、选项元数据始终固定目标来源、批准 digest 和当前身份；旧来源结果不能继续填入新表单。西电 0.28.1 接入日期、校区/楼栋、时段、类型、教学/考试座位数，完整性指实际所选楼栋与日期；无占用记录不等于保证开放。输出 classroom.available 1.3 区分 teachingCapacity/examCapacity，保留旧 capacity 含义；未知值省略，原因沿 intervals.reason 返回。

### 2.1：可选字段后台补充

依据 [ADR-083](../adr/adr_083_deferred_query_fields.md)，需要远端选项的可选字段可以先返回声明，基础表单直接可用：

```json
{"id":"roomTypes","kind":"multiSelect","label":"教室类型","options":[],"dependsOn":["date","building"],"deferred":true}
```

此字段先隐藏，宿主单独请求 `{"target":"classroom.available","current":{"date":"2026-11-04","building":"demo-building"},"load":["roomTypes"]}`。current 仅含本批字段及其声明依赖；不要依赖其他未声明条件。未选上级时设置 disabled 和原因，宿主暂不请求。脚本返回完整的有效表单，补充字段去掉 deferred 并提供 options；宿主只合入请求字段，其余内容不覆盖用户正在编辑的草稿。

延迟字段必须是非必填叶子，没有 initialValue；解析后 id/kind/dependsOn 不变、仍非必填且无默认值。总字段数沿用32项，load 为1–32个唯一id。补充失败可手动重试，未解析且无已有值的字段不阻塞查询；已选值若尚未核验，会明确显示待确认与清除入口，避免静默放宽条件。已返回但不可用的可选字段保持隐藏；已有值仍须确认或清除。依赖改变清空其下游并取消旧补充，无关编辑不重取；关闭或提交取消剩余补充等待，不保证已发送请求从服务器撤回。

西电基础读取与普通依赖刷新只用包内校区/楼栋目录，最终查询仍校验学校目录。类型取数留在显式 load 分支；不能启动未 await 的网络任务后返回基础表单，那不具有后台执行保证。timeRange 用原生时间选取器，起止默认值由脚本按学校时区给出；核心不硬编码学校当前时间或楼栋策略。

声明 2.1 的包需重新批准 digest；旧宿主拒绝未知版本。2.0/1.0 包仍按原协议执行，不接收 load/deferred。

### 1.0：旧包固定参数控件

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
