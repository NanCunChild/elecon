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

## Android ADB 与文件调试（ADR-100）

开发构建使用 `com.ncclab.elecon`。这与旧 `dev.nancunchild.elecon` 是不同应用，旧数据/Keystore不会自动迁移；保留旧安装，在新应用重新导入和登录。Apple bundle ID、Linux application ID也同步更新；DEV-SIDELOAD另加 `.devsideload` 后缀。

先在客户端目录运行并让应用保持前台，完成初始化、选择/解锁目标 Profile：

```bash
cd client
fvm flutter run --debug --dart-define=ELECON_DEBUG_TOOLS=true
# 或构建后自行安装：
fvm flutter build apk --debug --dart-define=ELECON_DEBUG_TOOLS=true
```

只有 debug **且**显式开关为true时处理文件命令；普通debug仍写日志，profile/release均无文件调试入口。此入口把开发者的本地文件操作当作安装授权，可以同版本替换，不弹安装确认页；仍校验包/schema/SDK、原文件SHA-256、学校和规范digest，不允许降版或更换学校。只支持 `elecon-script/1`，旧V1 Adapter的验签/发布路径保持独立。

在仓库根使用Python标准库工具（无需安装依赖）：

```bash
python3 scripts/elecon-debug.py status
# 添加/替换，同版本源码迭代也适用；指定已打包的文件
python3 scripts/elecon-debug.py put school-scripts/xidian-chaoxing/dist/enhancement-xidian-undergraduate-chaoxing.elecon.json
python3 scripts/elecon-debug.py remove enhancement-xidian-undergraduate-chaoxing
# 初次导入目录内所有 *.elecon.json，持续监听增删改
python3 scripts/elecon-debug.py sync /tmp/elecon-packages --watch
# 导出全部保留的完整日志，时间从旧到新
python3 scripts/elecon-debug.py logs --output /tmp/elecon-debug.jsonl
```

源码JS修改后先用对应学校打包器重新生成 `.elecon.json`（例如 `npm run scripts:chaoxing -w tools`），也可直接修改包JSON中的source再保存。监听只删除本次进程已成功同步、随后从目录消失的包，不清理设备其他安装；重启监听不推断过去已删除的文件。目录应是存在的专用开发目录；移走整个目录会被视为移除其中已同步的包。不要把同一ID的多个版本放进同一目录。Profile在监听启动时固定，切Profile会停止后续写入并报告错误。安装不执行包能力、不自动登录；替换后旧调用被取消，回到对应页面重新查询。

多设备用 `--serial SERIAL`；其他应用ID用 `--package com.ncclab.elecon.devsideload`；固定Profile用 `--profile ID`，以上选项放在子命令前。桌面开发可用 `--local /absolute/application-support/debug-tools` 完成相同文件工作流。查询Profile ID用status，不读取凭据文件。

### 原始ADB操作及文件协议

应用轮询私有 `files/debug-tools/inbox`（约1秒一次，前台每批至多8个）。命令文件名为32位小写十六进制请求ID加 `.json`。先写临时文件再rename，就绪后才会消费；不能将注册表文件直接替换成新源码。

```bash
adb shell run-as com.ncclab.elecon cat files/debug-tools/status.json
# 本地 command.json 按下表创建；使用新的随机请求ID
adb shell run-as com.ncclab.elecon mkdir -p files/debug-tools/inbox
adb shell "run-as com.ncclab.elecon sh -c 'cat > files/debug-tools/inbox/0123456789abcdef0123456789abcdef.tmp'" < /tmp/command.json
adb shell run-as com.ncclab.elecon mv files/debug-tools/inbox/0123456789abcdef0123456789abcdef.tmp files/debug-tools/inbox/0123456789abcdef0123456789abcdef.json
adb shell run-as com.ncclab.elecon cat files/debug-tools/results/0123456789abcdef0123456789abcdef.json
# 当前日志完整文件，不受logcat行长度限制；.1/.2/.3为更早轮转
adb exec-out run-as com.ncclab.elecon cat files/debug-tools/logs/dev-log.jsonl > /tmp/elecon-current.jsonl
```

| 字段 | 含义 |
|---|---|
| version | 固定1 |
| profileId | status中的当前Profile ID；不匹配或受保护存储未解锁时拒绝 |
| operation | `upsert` 或 `remove`，没有运行能力或任意路径操作 |
| package / sha256 | upsert：完整包JSON文本及此文本UTF-8的SHA-256；不是规范包digest |
| packageId | remove：已安装包ID |

工具自动计算原文件SHA-256；宿主解析后保存其规范digest供执行复核。结果为 `ok` 或固定错误码，如 `debug_command_digest`、`debug_command_identity`、`script_downgrade`；未知解析/存储失败为 `debug_command_rejected`，不返回原始异常。结果最多保留64份，工具读取后删除。进程中断后 `processing/ID.json` 留存，视为结果未知，不自动重放；先核对status/结果及日志，再决定是否生成新请求。退出应用或切后台可能使工具等待超时，超时不表示操作回滚。

### 日志范围

Debug启动自动启用私有JSONL记录，包括现有全部DevLog类别、脚本调用trace/包digest/交互模式/结果/耗时/剩余额度、HTTP各跳状态与调用耗时、Flutter与异步错误类型及栈。不会记录请求/响应正文；已知凭据、URL参数和会话路径继续净化，脚本作者仍须只写安全阶段标记。所谓完整指保留范围内完整的**已净化条目**，不是原始凭据或学校响应。

UI仍显示500条环缓冲；文件独立保留4份、每份目标4MiB、单条不截断。异步写入队列限制2MiB，超量条目丢弃；后续记录的 `dropped` / `writeFailures` 是进程累计计数。磁盘失败不阻断业务。轮转过期、队列溢出或强制结束前未刷入的数据不保证保留；UI清空不删除文件。导出保留文件建议在查询结束后进行，导出过程中发生轮转可能改变快照。无远程上传。release不落这些调试日志，系统 `run-as` 也要求debuggable安装。
