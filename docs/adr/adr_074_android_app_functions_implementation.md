# ADR-074 · Android AppFunctions 首片执行与授权

- 日期：2026-11-03
- 状态：Accepted（按所有者授权继续实施；不代替人工审阅和真实学校验收）
- 承接：ADR-069、044、066、067。

## 固定入口与平台注册

使用 Google Maven 的 `androidx.appfunctions:appfunctions` 和编译器 `1.0.0-beta01`，KSP `2.3.12`；均为 Apache-2.0。新依赖用于生成服务、固定函数 XML 和类型序列化，不执行学校协议。API 以下载的对应版本源码与[发布记录](https://developer.android.com/jetpack/androidx/releases/appfunctions)核对，采用 `AppFunctionDeclaration`、`AppFunctionServiceEntryPoint` 和应用元信息 `instructions`。服务要求系统 `BIND_APP_FUNCTION_SERVICE` 权限，普通应用不能直接绑定绕过平台调用权限。API 36 以下禁用服务。

四个固定函数：`describeAvailableServices`、`getSchedule(term, week)`、`findAvailableClassrooms(startAt, endAt, buildingId)`、`getGrades(term)`。没有自由 capability、URL、脚本、身份参数及写操作。KSP 生成的函数 ID 和 XML 随 APK 一起检查。

返回类型是 JSON 字符串，含固定状态/原因/来源 digest/schemaVersion/observedAt/stale/partial 及 `data` 对象。`data` 是白名单投影后的领域 JSON，描述明确约定对应标准契约；不透传开放 schema 的任意扩展。错误不带响应、堆栈或密码。限制 200 条、128 KiB、30 秒并发上限 4；超过数据范围明确 partial，超过总字节失败，不能静默截断字符串。来源正文始终是数据。

## 执行与用户授权

首片只使用已存在的 Flutter engine 和当前恢复完成的 Profile/学校；冷进程或硬件解锁失败返回 unavailable，引导用户打开应用。不隐式启动解锁，不选第一个 Profile。系统调用权限不等于用户同意共享成绩，设置页分别允许课表、教室、成绩；授权仅在当前进程内有效，绑定当前 session/学校/包 digest，重启后清除。更新来源、切身份、退出时既有授权失效，界面明确说明。

每次调用固定批准来源，使用现有 `runTrustedScript(interactive:false)` 及独立取消令牌。开始与返回重核 Profile、学校、身份 identityRevision、安装 epoch、执行 generation、授权；取消、权限撤回和 scope 改变主动取消本次工作。身份修订与执行取消分开：选校、退出、显式重新登录、密码替换和凭据后端替换撤销授权；普通应用暂停、语言变更和子票据更新只取消旧执行，不撤销已经授予的查询范围。主壳已有后台取消保持不变，后台启动的新系统只读请求仍需同一授权。无后台浏览器、扫码、定位或密码输入。超时不重试，不使用旧缓存伪装成功。

课表使用现有学期/教学周契约，不推断学校学期起点。成绩只查明确学期，保留分页完整性，不查询所有学期。教室仅支持 1.2 绝对区间；输入必须同一日、同一明确 UTC offset、分钟精度且最多 12 小时，传学校墙钟日期/时间，最终以绝对区间验证整段覆盖。缺口、重叠和 unknown 不当作空闲；返回说明无占用记录不保证允许进入。旧 1.1 返回 unavailable。

## 验证与迁移

现有 SDK 包和页面不改含义；来源更新重新授权。纯 Dart 测试验证拒绝/取消/身份切换/来源更新/输出范围及区间覆盖，Android 构建验证生成服务和资源；API 37 模拟器测试另记结果，API 35 真机不能代替平台发现验收。Gemini 开放情况由平台决定，不能由 APK 存在推导可用。
