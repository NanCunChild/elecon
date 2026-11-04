# Android 系统助手查询

依据 [ADR-069](../adr/adr_069_android_app_functions.md) 和 [ADR-074](../adr/adr_074_android_app_functions_implementation.md)。

设置 → 系统助手访问，分别开启课表、空教室、成绩。默认均关闭；只授权当前 Profile、学校和已批准脚本来源。进程退出、切身份或来源变更后需要重新开启。系统助手可能处理返回的数据，应用内说明会提示这一点。冷启动不自动解锁凭据、弹登录页或选择其他身份；返回 `unavailable/openApp` 时需用户先打开应用。

AppFunctions 服务要求 Android 16+ 的系统执行权限，API35 上禁用。支持注册并不表示所有版本的 Gemini 已开放接入；[官方总览](https://developer.android.com/ai/appfunctions)仍注明受限预览。

## 固定函数与结果

函数 ID 前缀为 `dev.nancunchild.elecon.BaseEleconAppFunctionService#`。

| 后缀 | 参数 | 读取范围 |
|---|---|---|
| `describeAvailableServices` | 无 | 三种查询的 available/authorized；不枚举身份或读取学校数据 |
| `getSchedule` | `term: string, week: int` | 单学期单教学周；week 1–100 |
| `findAvailableClassrooms` | `startAt, endAt: string, buildingId: string?` | SDK 标准空教室 1.2 已返回范围内，整段绝对时间有空闲证据的教室 |
| `getGrades` | `term: string` | 单学期已返回成绩页；不推算全校或跨学期 GPA |

时间输入使用带明确 offset 的 RFC3339，秒数为 00，同日且同 offset，最长 12 小时。SDK1.1 的同名扩展不获得1.2区间语义；缺口、重叠、无区间不当作空闲。返回的无占用证据不等于允许进入。

返回是 JSON 字符串，`status` 使用 `ok / empty / partial / authenticationRequired / configurationRequired / unavailable / cancelled / failed`。成功保留 `source.packageId/digest`、`schemaVersion`、`observedAt`、`stale`、`partial`、实际 `parameters` 和白名单投影 `data`。`observedAt` 为本次查询结束时间，学校 `updatedAt` 原样保留；本端没有缓存回退所以 `stale=false`，不据此断言源站缓存新鲜。成绩完整性未知返回 partial，`coverage=returnedPage`；教室 `coverage=returnedRooms`，保留 unknownRooms 和原空闲原因。

输出上限200条、128KiB；执行最多28秒，Android桥总上限30秒，并发最多4项。身份/来源更新、用户撤销、平台取消主动取消对应脚本；晚到结果再次检查。没有账号登录、任意 URL、任意脚本、跨身份输入、发消息或控制设备函数。开放 schema 的扩展字段不透传，课程正文等纯文本仍是数据。

## 依赖与构建

| 依赖 | 固定版本及来源 | 用途 | 许可 |
|---|---|---|---|
| AndroidX appfunctions、appfunctions-compiler | 1.0.0-beta01，Google Maven | 服务生成、XML、平台适配 | Apache-2.0 |
| Google KSP | 2.3.12，Gradle Plugin Portal / Maven Central | 编译期符号处理 | Apache-2.0 |
| Android Gradle Plugin | 9.1.0，Google Maven | 满足 AppFunctions AAR min AGP | Apache-2.0 |
| Gradle | 9.3.1，services.gradle.org；wrapper 验证 SHA256 | 构建 | Apache-2.0 |
| flutter_inappwebview | 6.2.0-beta.3，pub.dev 官方包 | 现有浏览器；修复 AGP9 已移除旧 ProGuard 默认文件 | Apache-2.0 |

AppFunctions AAR 元数据要求 compileSdk37和AGP9.1，不能按尚未同步的入门示例使用compileSdk36。保持原targetSdk/minSdk。AGP9拒绝把Provider直接传给旧Android SourceSet；已有生成资源转换为目录值，生成任务依赖仍显式保留。保留Flutter现有 `android.newDsl=false` / `android.builtInKotlin=false` 兼容选项，未来AGP10移除前需再迁移。

WebView更新使用完整官方包，不修改pub缓存或绕过AAR校验。其Android端1.2.0-beta.3、平台接口1.4.0-beta.3等具体传递版本以pubspec.lock为准；Apple独立manifest/lock同步相同版本，在隔离目录解依赖，仅更新8个WebView相关包，保留contract相对路径。Linux下使用Apple依赖环境分析全部lib通过，不等于macOS/iOS原生构建。[发布源](https://pub.dev/packages/flutter_inappwebview/versions/6.2.0-beta.3)。

## 自动与平台验证

`client/test/ai/app_functions_test.dart` 使用合成已批准包经真实QuickJS验证默认拒绝、授权查询、来源更新、进程授权重置、Profile切换、取消和早期取消、并发界限、固定错误、时间范围、未知区间、结果投影及设置页。浏览器升级继续跑原browser/surface回归和编译。

KSP输出位于 `client/build/app/generated/ksp/debug/`；验证4个具名函数与服务，没有通用执行函数。主入口debug APK包含生成XML、官方XSD与应用级instructions资源，并成功编译arm64和x86_64两种Flutter库。

2026-11-03在API37模拟器验证下表。使用独立合成学校包、空成绩/课表和一间带明确区间原因的教室，不导入真实账号或访问学校网络。测试通过ADB写入合成批准注册表，随后使用应用真实设置开关授予数据访问；这不代表学校包人工安装签收。

| 检查 | 实际观察 |
|---|---|
| 系统 `list-app-functions` | 索引4个具名函数和正确生成服务 |
| 直接 `am startservice` | 拒绝，要求 `BIND_APP_FUNCTION_SERVICE` |
| 冷进程调用发现/成绩 | `unavailable/openApp`，未启动Flutter界面解锁 |
| 有活动学校、未授权 | 发现3个available=true、authorized=false；成绩返回authorizationRequired |
| 实际设置分别授权 | 成绩/课表返回empty与来源和范围，教室返回ok、绝对区间及原原因 |
| 撤销成绩开关 | 下一次成绩调用返回authorizationRequired |
| 重装重启进程 | 三种授权恢复为false |
| Home键后台调用 | 确认前台为系统Launcher后，已授权成绩仍成功；没有弹回应用 |

最终17项AI测试通过；此前AI、应用locale和browser/surface合计50项定向回归通过，随后增加了身份与执行代际分离及整个请求期限回归。总期限覆盖registry与发现阶段，超时释放名额，旧future完成不能再发起学校查询；测试用真实QuickJS日志与复用请求ID验证。上述完整平台矩阵对应身份代际修复后的主APK，早于最后的总期限和平台manager可用性检查小修；这些小修通过定向自动回归。最终双ABI主入口APK已统一重建并安装API37模拟器，再次确认系统索引四函数、冷进程发现返回openApp、打开应用后发现三项available=true且authorized=false。

真实平台调用方取消尚未单独验收，已有Dart早期/运行期取消、超时、并发上限和KSP生成取消分发的编译证据。真实学校、API36设备、其他系统助手客户端、受管理Android Profile、Gemini产品接入和人工核心审阅仍需独立验收。真机API35不能代替API37平台验证。
