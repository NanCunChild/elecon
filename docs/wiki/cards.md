# 卡片模板目录与调用

[返回目录](README.md) · 前置：[快速开始](quick-start.md)

## 统一接入方式

每张卡片由模板类型、能力声明和标准输出组成。以下是合入 manifest 的片段；其余必需字段沿用[入门示例](examples/hello/manifest.json)：

```json
{
  "capabilities": [
    { "id": "grades.list", "schema": "elecon.grades.list", "schemaVersion": "1.1" }
  ],
  "cards": [
    { "id": "academic-grades", "type": "grades", "title": "教务成绩", "defaultVariant": "regular" }
  ]
}
```

SDK12 起，显式 `id` 标识包内卡片实例，`title` 可选；同类型可有多个不同 id。它们的查询、详情、缓存和登录绑定各自的安装包及批准 digest。**同一个包里重复声明同类型实例不会产生不同处理器或默认参数**：`cards` 没有 `params` 字段；实例的输入仍由原生功能提供。

当前最多声明十项。模板需要的能力须由同包提供；给卡片改名不会改变其数据语义。以下版本指输出 schema，完整声明形式都是 `{id:"能力名",schema:"elecon.能力名",schemaVersion:"版本"}`。

| `type` | 同包需要提供 | 当前输出版本 | 可选补充 |
|---|---|---|---|
| `notice` | `notice.list` | 1.1 | `notice.detail` 1.0 |
| `schedule` | `schedule.week` | 1.2 | `term.list`、`calendar.academic` 1.0 |
| `grades` | `grades.list` | 1.1 | `term.list` 1.0、`gpa.summary` 1.1、`query.controls` 1.0 |
| `library` | `library.loans` | 1.0 | 此模板用于个人借阅 |
| `card` | `card.balance` / `card.transactions` / `card.qr` 至少一个 | 均 1.0 | 可组合余额、流水、二维码 |
| `exam` | `exam.list` | 1.0 | 学期参数 |
| `classroom` | `classroom.buildings`、`classroom.available` | 1.0、1.2 | `query.controls` 1.0 |
| `energy` | `energy.meters`、`energy.usage` | 1.0、1.1 | 表具选择、历史窗口 |
| `climate` | `climate.devices`、`climate.status` | 均 1.0 | `climate.command` 1.0 |
| `generic` | `generic.section` | 1.0 | 语义字段、简单表格 |

注册表里存在能力不等于已有独立首页模板。教师搜索、账号、聊天、签到和包内网页使用各自原生功能入口，不应填成新的 `cards.type`。

### 尺寸建议

`notice/schedule/grades/library` 的 `defaultVariant` 支持 `compact/regular/expanded`；其余类型只接受 `regular`。用户可在客户端编辑三档尺寸，保存的选择优先。

SDK12 显式 id 实例直接对应宿主尺寸：compact 为图标入口，regular 为半宽摘要，expanded 为全宽。旧式未提供 id 的声明沿用历史建议映射：compact 为半宽，regular/expanded 为全宽。不能据此把其他模板的 manifest 建议改成 expanded；用户仍可在客户端把它展开。

以下各节给出**合成处理器示例**，分别合入同一个 `capabilities` 对象，不要重复导出同名对象。示例没有真实学校账号、设备或网络请求。参数栏是工作台输入或宿主调用时传入的 JSON，不是脚本内部跨能力调用 API。

## 通知 `notice`

请求 `notice.list`，例如 `{"page":1,"size":20}`；支持的筛选以[参数 schema](../../contract/schema/params.notice.list.schema.json)为准。

```js
export const capabilities = {
  async "notice.list"(ctx, params = {}) {
    return {
      items: [{
        id: "demo-notice-1",
        title: "合成教学通知",
        category: "academic",
        source: "示例教务处",
        publishedAt: "2026-11-03T01:00:00Z",
        summary: "仅供开发预览。"
      }],
      page: params.page ?? 1,
      hasNext: false
    };
  }
};
```

返回稳定的校内通知 ID。列表有正文可提供 `content`；分开获取详情时增加 `notice.detail`，沿同一来源传通知身份。`hasNext/total/cursor` 只有源站提供或可证实时才填写，已加载十条不代表总共十条。字段详见 [notice.list](../../contract/schema/notice.list.schema.json)。

## 课表 `schedule`

请求 `schedule.week`：`{"term":"demo-term","week":1}`。返回周必须与实际查询一致；学校默认当前周逻辑由脚本实现。

```js
export const capabilities = {
  async "schedule.week"(ctx, params = {}) {
    return {
      term: params.term ?? "demo-term",
      week: params.week ?? 1,
      days: [{ dayOfWeek: 1, slots: [{
        start: "08:00", end: "09:40", courseName: "合成课程",
        courseId: "demo-course", teacher: "示例教师", location: "示例教学楼"
      }] }]
    };
  }
};
```

`dayOfWeek` 为 1–7。`start/end` 保留契约定义的节次或时间字符串；学校墙钟时间可用 `timeStart/timeEnd` 明确提供。1.2 的 `termWeeks` 可提供整学期周详情，`timeSegments` 与 `weekPreviews` 提供时间段和已知预览。缺少某日或某周证据不等于零门课程。见 [schedule.week](../../contract/schema/schedule.week.schema.json)。

## 成绩 `grades`

请求 `grades.list`：`{"term":"demo-term"}`。

```js
export const capabilities = {
  async "grades.list"(ctx, params = {}) {
    return {
      term: params.term ?? "demo-term",
      items: [{
        courseId: "demo-course", courseName: "合成课程", credit: 2,
        score: { kind: "numeric", value: 90, max: 100 },
        category: "required", status: "final"
      }]
    };
  }
};
```

分数可能是数值、等级、通过/不通过或未知；不要把未发布成绩写成 0。源站单科绩点使用 `gradePoint` 并说明 `gradePointSource`，官方汇总可通过 `gpa.summary` 提供。学期名称用 `term.list` 的 `id/name`，不按学期 ID 猜显示文案。见 [grades.list](../../contract/schema/grades.list.schema.json)及[查询条件](interactions.md#查询条件与提交按钮)。

## 借阅 `library`

请求 `library.loans`：`{}`。

```js
export const capabilities = {
  async "library.loans"(ctx) {
    return { items: [{
      bookId: "demo-book", title: "合成图书",
      borrowedAt: "2026-11-01T00:00:00Z",
      dueAt: "2026-11-30T23:59:59Z",
      renewCount: 0, renewable: false
    }] };
  }
};
```

模板只展示个人借阅与到期信息，`renewable:true` 不会注册续借按钮。馆藏搜索、座位查询和预约有不同语义，不能用借阅列表代替。见 [library.loans](../../contract/schema/library.loans.schema.json)。

## 校园卡 `card`

余额请求 `card.balance`：`{}`；流水请求 `card.transactions`，例如 `{"page":1,"size":20}`。

```js
export const capabilities = {
  async "card.balance"(ctx) {
    return { balance: { amountMinor: 12345, currency: "CNY" }, status: "active" };
  },
  async "card.transactions"(ctx) {
    return { items: [{
      transactionId: "demo-transaction", time: "2026-11-03T03:30:00Z",
      amountMinor: 1200, currency: "CNY", direction: "debit", merchant: "示例食堂"
    }], hasNext: false };
  }
};
```

`12345 CNY` 表示 123.45 元，金额使用整数最小货币单位。流水 `amountMinor` 非负，收支由 `direction` 表达。没有真实卡号时省略 `cardNumber`，不能拿学号、openid 或占位值替代。消费统计由宿主按标准流水派生。

只提供二维码也可使用 card 模板。`card.qr` 返回 `{imageBase64,issuedAt,expiresAt,purpose?}`，`imageBase64` 是无 data URI 前缀的真实 PNG；不提供虚构图片字符串。PNG 最多 256 KiB、最大 2048×2048，宿主最多展示 60 秒。二维码**禁止写入 home**，只由用户前台请求，后台、离开及身份变化清除，不执行支付。见 [card.qr](../../contract/schema/card.qr.schema.json)。

## 考试 `exam`

请求 `exam.list`：`{"term":"demo-term"}`。

```js
export const capabilities = {
  async "exam.list"(ctx, params = {}) {
    return { term: params.term ?? "demo-term", items: [{
      courseName: "合成课程", examAt: "2026-12-01T01:00:00Z",
      room: "示例考场", status: "scheduled"
    }] };
  }
};
```

未提供时间、座位或考试状态时省略，不从课程表推算考试安排。见 [exam.list](../../contract/schema/exam.list.schema.json)。

## 空教室 `classroom`

先请求 `classroom.buildings`：`{}`；再请求 `classroom.available`：`{"buildingId":"demo-building","date":"2026-11-03","start":"09:00","end":"10:00","timeZone":"Asia/Shanghai"}`。

```js
export const capabilities = {
  async "classroom.buildings"(ctx) {
    return { items: [{ buildingId: "demo-building", building: "示例教学楼" }] };
  },
  async "classroom.available"(ctx, params = {}) {
    return {
      date: params.date ?? "2026-11-03", timeZone: "Asia/Shanghai",
      items: [{
        buildingId: "demo-building", building: "示例教学楼", room: "示例教室",
        roomId: "demo-room", status: "unknown"
      }]
    };
  }
};
```

目录与占用查询必须同来源，ID 不跨包复用。1.2 可返回 `intervals:[{startAt,endAt,status,reason?}]`，时间为 UTC，区间左闭右开、同室不重叠；缺口保留未知。没有课程记录不能证明全天空闲，空闲也不保证实际开门。见 [classroom.available](../../contract/schema/classroom.available.schema.json)。

## 水电 `energy`

先请求 `energy.meters`：`{}`；再请求 `energy.usage`：`{"meterId":"demo-meter"}`，可加 UTC `from/to`。

```js
export const capabilities = {
  async "energy.meters"(ctx) {
    return { items: [{
      meterId: "demo-meter", type: "electricity", unit: "kWh", label: "合成电表"
    }] };
  },
  async "energy.usage"(ctx, params = {}) {
    return { items: [{
      meterId: params.meterId ?? "demo-meter", type: "electricity",
      unit: "kWh", reading: 100, previousReading: 98, usage: 2,
      readAt: "2026-11-03T00:00:00Z"
    }] };
  }
};
```

累计读数、区间用量、剩余量是不同字段。不要把余额金额当电量。多表先发现再选择，缓存按身份、来源、表和窗口区分。见 [energy.meters](../../contract/schema/energy.meters.schema.json)、[energy.usage](../../contract/schema/energy.usage.schema.json)。

## 空调 `climate`

先请求 `climate.devices`：`{}`；再请求 `climate.status`：`{"deviceId":"demo-device"}`。下例仅展示只读模拟设备，不声明命令。

```js
export const capabilities = {
  async "climate.devices"(ctx) {
    return { items: [{
      deviceId: "demo-device", label: "合成空调（只读）",
      minTemperature: 16, maxTemperature: 30,
      modes: ["cool"], fanSpeeds: ["auto"], commands: [],
      modeDefaults: [{
        mode: "cool", targetTemperature: 26, fanSpeed: "auto",
        turbo: false, auxiliaryHeat: false, indoorClean: false, outdoorClean: false
      }],
      powerOffClearsAuxiliaryHeat: false, fanSpeedClearsTurbo: false,
      turboUsesAutoFan: false, powerOffClearsCleaning: false
    }] };
  },
  async "climate.status"(ctx, params = {}) {
    return { deviceId: params.deviceId ?? "demo-device", power: false, online: true };
  }
};
```

设备范围、命令集合、模式默认值与联动规则必须来自学校协议，不能照抄模拟值。实际控制另提供 `climate.command`，其参数、一次提交后查状态及未知结果规则见[控制按钮](interactions.md#空调控制按钮)。当前空调产品页面保持 Android 范围。见 [climate.devices](../../contract/schema/climate.devices.schema.json)、[climate.status](../../contract/schema/climate.status.schema.json)。

## 通用信息 `generic`

请求 `generic.section`：`{"section":"service-hours"}`。

```js
export const capabilities = {
  async "generic.section"(ctx, params = {}) {
    return {
      sectionId: params.section ?? "service-hours", title: "示例服务信息",
      fields: [{ label: "状态", role: "status", value: "合成示例" }],
      table: {
        columns: [{ label: "事项", role: "label" }, { label: "说明", role: "label" }],
        rows: [["示例服务", "仅用于模板预览"]]
      }
    };
  }
};
```

语义角色包括 identifier、label、status、datetime、deadline、amount、quantity、link、unknown。金额仍为 `{amountMinor,currency}`。此输出没有按钮回调、任意 HTML 或学校自定义可执行组件；已有领域模型适用时优先使用领域能力。见 [generic.section](../../contract/schema/generic.section.schema.json)。

## 缓存与自动查询

只给适合缓存的只读查询声明 `home`，例如：

```json
{
  "home": [
    { "capability": "grades.list", "params": { "term": "demo-term" }, "ttlSeconds": 900, "preload": false }
  ]
}
```

最多 16 个不同能力，TTL 为 30–86400 秒，参数 JSON 最多 4096 UTF-8 字节。`preload:true` 在后台执行，不能弹登录、表单、扫码或浏览器。宿主缓存验证成功的输出和实际完成时间，刷新失败保留旧结果与 stale 状态；身份、来源 digest、参数和适用语言参与隔离。

禁止加入 home 的能力包括：`climate.command`、`card.qr`、`query.controls`、`account.session`、`forum.session`、`messages.session/list/conversations/history/send`、`attendance.checkin`、`web.content`。卡片显隐不等于注销账号或撤销缓存策略。
