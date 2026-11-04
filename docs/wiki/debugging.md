# 调试、验证与交付

[返回目录](README.md) · 建议先完成[离线入门](quick-start.md)

## 分层定位

| 现象 | 优先检查 |
|---|---|
| 无法打包 | JSON 语法、SDK 字段、同包能力依赖、未知 actions、账号绑定、体积 |
| 能安装但不出现卡片 | 当前学校与启用状态、cards 类型、对应能力、用户显隐；有能力不等于有模板 |
| 工作台运行失败 | 导出键、参数、实际 QuickJS API、固定错误码、标准输出校验 |
| HTTP 被拒绝 | 精确 origins、每个跳转目标、ipAllow、当前账号隧道依赖 |
| 登录后仍需认证 | 业务 API 是否验证、Cookie 目标路径、母票据与子票据、凭据持久化 |
| 页面更新后显示旧内容 | 当前包版本/digest、来源绑定、缓存参数与取得时间 |
| 后台表单不可用 | preload/interactive:false 禁止交互；改为前台明确入口 |
| 包内网页的 JS 或网络不工作 | 文档脚本与直接网络本来就被禁止，使用固定 DOM 与 ctx.fetch |
| 隐藏登录/自动密码恢复不可用 | 当前无隐藏认证 presenter，silentWeb 必须 false |
| 控制或提交超时 | 保留未知结果，不能直接重试或切来源补发 |

## 验证入门示例

先运行[快速开始的打包命令](quick-start.md#4-打包导入查看)，再验证处理器合成输出。以下命令在仓库根运行，使用已有 Ajv 依赖，不安装新库、不联网、不执行学校服务请求：

```bash
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const source = readFileSync('docs/wiki/examples/hello/index.js', 'utf8');
const module = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const result = await module.capabilities['generic.section']({}, { section: 'welcome' });
const schema = JSON.parse(readFileSync('contract/schema/generic.section.schema.json', 'utf8'));
const ajv = new Ajv2020({ strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);
assert.equal(validate(result), true, JSON.stringify(validate.errors));
assert.equal(result.sectionId, 'welcome');
console.log('Wiki offline example: PASS');
JS
```

这验证源码导出与标准输出形状；实际宿主仍需安装后在工作台/首页运行，核实授权、来源与 QuickJS 桥接。打包成功不能证明所有 JS 可执行，Node 合成检查不能替代设备 WebView 或学校验收。

卡片章节每段 `export const capabilities` 是独立示例；合入项目时只保留一个导出对象，并在 manifest 声明所用能力和正确版本。JSON schema 校验不能替代领域语义检查，例如 unknown 时段不能填 available。

## SDK17 的统一错误

JS 内继续使用普通 `throw`、`try/catch` 和 `Error`。宿主桥以结构化成功/失败信封传递稳定 code，调用方不解析 `message` 或异常显示文字，也不把它们拼成新请求。

学校业务错误用当前包的命名空间，不要求每个学校码进入核心白名单：

```js
const result = await loadSchoolNotices();
// 此处根据学校明确的业务响应分类，网络异常仍按其原分类抛出。
if (result.status === "not_available") {
  throw elecon.errors.create("notice_unavailable");
}
```

`errors.create(localCode)` 产生当前包绑定的业务错误；对宿主保持固定 `script_business_error` 分类，并保留 `packageId:localCode` 元数据。localCode 是稳定标识，不拼接账号、响应正文、URL 或秘密。固定宿主错误沿旧 code 分类处理；未知异常仍不能任意透传文案。

错误不授权自动重试。取消、认证需要交互和结果未知分别处理；写请求可能已到源站时不能因超时、取消或恢复登录而重放。SDK1–16 的固定错误分类保持旧行为。

## 错误分类与恢复边界

`elecon.errors.create(localCode)` 的 localCode 必须以小写字母开头，后续只含小写字母、数字或下划线，总长 1–64 字符。比如包 id 为 `school.example` 时，`notices_unavailable` 对应 `businessCode="school.example:notices_unavailable"`；分类 code 仍是 `script_business_error`。这些是机器标识，不能插入源站响应或用户文案。

下面是包内错误分类示例。`runStep` 为作者传入的普通函数；返回对象只给同包辅助流程使用，能力最终仍须返回其领域 schema。

```js
async function classifyStep(runStep) {
  try {
    return { kind: "ready", value: await runStep() };
  } catch (error) {
    if (error?.code === "authentication_required") {
      return { kind: "needs_login" };
    }
    if (error?.code === "configuration_required") {
      return { kind: "needs_configuration" };
    }
    if (error?.code === "script_business_error") {
      return { kind: "business_failure", businessCode: error.businessCode };
    }
    throw error; // 保留取消、预算和未知失败，交给当前调用的统一出口。
  }
}
```

不要用 `catch` 把网络失败、超时、取消全部改成 authentication_required，也不要在每个页面复制自动登录与重试循环。只读恢复需要学校明确的认证失效证据，成功恢复后按现有策略重查；提交操作必须保留已经发送但未确认的未知状态。HTTP 4xx/5xx 仍返回 Response，应检查 status/ok 并按该学校协议解释，不能把“有 HTTP 响应”当作业务成功。

写自动测试时分别验证错误字段与行为：缺配置不发请求、预取消不进入传输、请求发出后取消不宣布回滚、未知异常不带原始秘密、业务码不自动重试。固定 code、学校私有码、用户文案和日志各有用途；只有稳定机器字段参与程序分支。

## 日志与固定错误

使用 `ctx.log("info","固定阶段标记")` 观察流程，不输出原始请求、响应、DOM、账号密码、Cookie、Token、二维码和设备标识。宿主会净化已知秘密与 URL，但不能识别受信脚本任意编码后的所有秘密。

```js
ctx.log("info", "campus_session_probe_started");
```

需要给 UI 固定分类时，设置 Error 的 code，不透传远端正文：

```js
throw Object.assign(new Error("source_response_invalid"), { code: "source_response_invalid" });
```

| code / 类别 | 含义与处理 |
|---|---|
| authentication_required | 缺少有效认证；用户进入对应同包登录入口 |
| authentication_timeout | 可见认证未按预算完成 |
| configuration_required | 缺少尚未配置的业务信息；显式配置 |
| source_response_invalid | 源站数据不能按约定解析 |
| network_denied | 宿主网络边界拒绝 |
| credential_persist_failed | 内存已接受后持久化失败，不能声称保存完成 |
| account_interactive_fallback | 用户选择学校网页；脚本转自己的可见流程 |
| account_silent_unavailable | 当前未开放自动隐藏认证 |
| input_* / scanner_* / device_input_* | 输入取消、不可用、预算或参数类失败 |

旧 SDK 与宿主分类只转发允许的固定 code；未知 message/code 通常回退为 adapter_failed。SDK17 学校业务码使用上文 errors.create，不扩大宿主码白名单。不要把原始学校报错拼进 code。账号事件与业务错误是不同接口：报告 expired 也不能吞掉当前查询失败。

## 修改后的验证范围

| 修改 | 对应验证 |
|---|---|
| 仅 Wiki / 引用 | 本地链接、JSON/JS 示例、字段与当前实现一致、diff 范围 |
| 学校协议 | 合成/脱敏 fixture → 实际模块 → 标准输出；关键桥接补实际 QuickJS |
| 标准 schema / SDK | 有效 ADR、版本兼容、非法/缺失输入、生成物和消费者同步 |
| 页面 / 按钮 | loading/error/empty/stale/partial、来源保留、取消/离页、适用 widget 回归 |
| 控制 / 发送 / 签到 | 明确触发、单次发送、重复点击、未知态、禁止后台和自动重试 |

现成测试入口包括 [client/test/scripts](../../client/test/scripts/) 和各学校的 `tests/`。Flutter 可按实际修改运行单个相关测试，例如在 client 中执行 `fvm flutter test test/scripts/card_manifest_test.dart`。不要为了文档改动重跑全部产品测试，也不要让 CI 请求真实学校或操作真实设备。

## 更新与审阅

包版本使用三段非负整数，如 `1.2.3`，不接受前导零、prerelease 或 build metadata。相同 id/schoolId 更新必须升版并重新确认；修改源码、网络、HTML、语言、账号声明都会改变批准内容。卸载重装不构成全局防回滚机制。

提交只包含本次任务改动，遵循 [Git 规则](../rules/git.md)。新依赖说明来源、用途和许可证，GPL 组件先明确模块/分发边界。核心、凭据、网络、控制和签名实现需人工实质审阅后合并；自动验证、真机结果、真实学校验收和人工签收分别记录，不相互代替。
