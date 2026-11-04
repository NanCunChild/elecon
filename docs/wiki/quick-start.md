# 快速开始：第一张卡片

[返回目录](README.md) · 下一篇：[卡片模板](cards.md)

## 1. 准备环境

在仓库根目录使用 Node.js 20 或以上版本，安装已有 workspace 依赖：

```bash
npm ci
```

学校脚本运行在客户端背景 QuickJS 中，不具备完整浏览器或 Node 环境。SDK17 提供全局 `fetch`、请求/响应与取消子集，宿主专有端口使用 `elecon`；SDK1–16 的网络接口为 `ctx.fetch`。页面 DOM、Node 内置模块、任意 npm import 和 URL 构造器不能直接假定可用；支持范围见[SDK 手册](sdk-and-host.md#sdk17普通-js-与宿主命名空间)。

## 2. 声明能力与模板

完整文件：[examples/hello/manifest.json](examples/hello/manifest.json)。示例选 SDK16，声明无需账号、无需浏览器、没有网络目标。

```json
{
  "sdkVersion": 16,
  "id": "wiki.hello",
  "version": "1.0.0",
  "schoolId": "wiki-example",
  "name": "Wiki 离线示例",
  "network": { "origins": [] },
  "browser": false,
  "accounts": [],
  "capabilities": [
    { "id": "generic.section", "schema": "elecon.generic.section", "schemaVersion": "1.0" }
  ],
  "cards": [
    { "id": "welcome", "type": "generic", "title": "开发示例", "defaultVariant": "regular" }
  ],
  "home": [
    { "capability": "generic.section", "params": { "section": "welcome" }, "ttlSeconds": 900, "preload": true }
  ]
}
```

`capabilities` 声明可调用的标准入口；`cards` 选择已有模板；`home` 独立决定查询缓存和预加载。显示卡片不要求一定预加载，声明缓存也不会产生任意新模板。

## 3. 返回标准数据

完整文件：[examples/hello/index.js](examples/hello/index.js)。导出名称必须是 `capabilities`，对象键与 manifest 能力 id 一致。

```js
export const capabilities = {
  async "generic.section"(ctx, params = {}) {
    const section = params.section ?? "welcome";
    if (section !== "welcome") throw new Error("unsupported_section");
    return {
      sectionId: "welcome",
      title: "开发示例（合成数据）",
      fields: [
        { label: "状态", role: "status", value: "脚本已运行" },
        { label: "示例数量", role: "quantity", value: 1 }
      ]
    };
  }
};
```

输出是严格 JSON 数据，不放函数、`undefined`、循环引用或 `NaN`。此模板的 `title`、`fields` 交给宿主渲染，不解释为 HTML。

## 4. 打包、导入、查看

在仓库根运行：

```bash
npm run scripts:package -w tools -- \
  --manifest docs/wiki/examples/hello/manifest.json \
  --source docs/wiki/examples/hello/index.js \
  --out /tmp/wiki-hello.elecon.json
```

打包器检查 manifest 和大小，不执行源码，也不验证学校协议。应用中打开“学校脚本”，导入生成的文件，查看内容与权限后安装，切换到示例学校。工作台选择 `generic.section`，参数填 `{"section":"welcome"}`；首页可看到“开发示例”实例，查询后显示合成字段。

运行客户端：

```bash
cd client
fvm flutter pub get
fvm flutter run
```

Apple 和 HarmonyOS 的运行方式见[项目首页](../../README.md#本地运行)。其他功能可用平台以各自实施记录为准。

## 5. 换成学校数据

选用[卡片模板](cards.md)，同时修改 manifest 能力声明和处理器。需要 HTTP 时声明精确 origin，再调用 `ctx.fetch`；需要登录时增加[账号入口](accounts.md)；需要条件与按钮时使用[交互接口](interactions.md)。

现成模板可直接参考：

| 模板 | 用途 |
|---|---|
| [SDK17 普通 JavaScript](../../adapters/_template/trusted/standard-js/README.md) | 全局 Request/Headers/fetch、elecon 业务错误与普通辅助函数 |
| [HTTP](../../adapters/_template/trusted/http/) | 从显式共享 Cookie 快照发起业务查询 |
| [浏览器](../../adapters/_template/trusted/browser/) | 可见网页登录、Cookie 采集、DOM 抽取 |
| [包内表单](../../adapters/_template/trusted/web-form/README.md) | Android 无脚本文档与真实用户事件 |
| [多语言](../../adapters/_template/trusted/localized/README.md) | 包内字典与 `ctx.i18n` |
| [前台签到](../../adapters/_template/trusted/attendance/README.md) | QR、照片、位置与单次提交骨架 |
| [隧道账号](../../adapters/_template/trusted/tunnel-account/manifest.json) | SDK16 固定 Hermes/aTrust 账号声明 |

源码包只有一个 ESM `source`。多文件开发须在构建期合并，`elecon:html` 可保留为宿主内置模块；不要把未合并的本地 import 直接放进最终包。生产学校的构建方式可看 [school-scripts](../../school-scripts/README.md)。

## 6. 多文件开发、构建与类型检查

学校源码可按 `src/index.js`、`src/auth.js`、`src/notices.js` 等普通模块组织。入口只导出能力表，其他文件使用常规 import/export；没有特殊文件名注册、流程 DSL 或必须继承的基类。

```js
// src/index.js：以下 listNotices 是学校作者实现的普通模块函数。
import { listNotices } from "./notices.js";
export const capabilities = { "notice.list": listNotices };
```

包仍只装载一个 ESM source，因此先把本地模块与允许分发的纯 JS 依赖合并，再交给打包器。下面从仓库根运行，假定你已经创建 `school-scripts/demo/manifest.json` 和 `school-scripts/demo/src/index.js`：

```bash
./node_modules/.bin/esbuild school-scripts/demo/src/index.js \
  --bundle --format=esm --platform=neutral --target=es2020 \
  --external:elecon:html --legal-comments=inline --charset=utf8 \
  --outfile=/tmp/demo-script.mjs

npm run scripts:package -w tools -- \
  --manifest school-scripts/demo/manifest.json \
  --source /tmp/demo-script.mjs \
  --out /tmp/demo-script.elecon.json
```

这里使用仓库已安装的 esbuild，不在构建时下载新工具。`elecon:html` 是已有宿主模块，故保留 external；`elecon` 本身是 SDK17 全局对象，不要把它写成未提供的 import 路径。其他依赖应打进产物；带有 Node 原生模块、动态文件读取或完整浏览器依赖的 npm 包不能因为打包成功就推断可在 QuickJS 中使用。记录新增依赖的来源、用途和许可，保留其要求的声明。

可以编写 TypeScript 后构建成 JS，但 esbuild 的转译不执行类型检查。SDK17 类型使用 `ES2022` lib 和 [sdk17.d.ts](../../contract/script-sdk/sdk17.d.ts)，不要用完整 DOM/Node 类型掩盖宿主未实现的 API。仓库提供独立检查命令与[类型示例](../../contract/script-sdk/examples/standard.ts)：

```bash
npm run scripts:check-sdk -w tools
```

该命令只验证仓库 SDK 类型示例，不自动检查你的学校目录；学校项目应将自己的源文件加入单独 tsconfig，再运行 TypeScript 检查。最终交付按“类型/模块合成测试 → 构建 → 包校验 → 真实 QuickJS → 平台与学校验证”的实际改动范围推进，安装前不会执行包源码。

更新时保持 `id` 和 `schoolId`，把 `version` 提升为更高的三段整数版本，例如 `1.0.1`，重新打包并授权。相同版本换内容会被拒绝。排版以外的源码变化、HTML 和翻译变化也在批准内容之内。
