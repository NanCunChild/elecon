# ADR-085 · 功能快捷方式与系统 AI 页面入口

- 日期：2026-11-04
- 状态：Accepted（所有者要求课表等功能的应用快捷方式与系统 AI 新调用方式）
- 承接：ADR-044、069、074、080、084。

## 决定

新增固定原生功能入口：schedule、grades、exam、classroom、card、library、energy、climate、notice、faculty、directory。Android 应用图标提供四个静态快捷方式（课表、成绩、考试、空教室），其余功能也可从设置页请求固定到桌面。入口指向 `elecon://feature/<id>`，不包含 Profile、学校、凭据、任意脚本参数或命令。

Android `shortcuts.xml` 同时声明 `actions.intent.OPEN_APP_FEATURE` 与上述固定功能清单，供支持 App Actions 的助手打开页面。这是已有四个只读 AppFunctions 之外的导航路径，不新增数据共享权限或后台查询口。助手能否发现/匹配取决于平台、语言和分发条件；APK 中存在声明不等于所有系统 AI 已开放接入。依据 [快捷方式](https://developer.android.com/develop/ui/compose/system/shortcuts/creating-shortcuts)、[App Actions schema](https://developer.android.com/develop/devices/assistant/action-schema)与 [OPEN_APP_FEATURE](https://developer.android.com/reference/app-actions/built-in-intents/common/open-app-feature) 官方说明实施。

四个 Launcher 项有 label 与 intent，另七个仅供 App Actions 的 entity 遵循[官方 inline inventory](https://developer.android.com/develop/devices/assistant/inline-inventory)形状，省略 intent/shortLabel/longLabel。部分 Launcher parser 对后者输出 missing-shortLabel 诊断并丢弃，并不代表助手实体缺失；不为消除该诊断把七个实体变成额外 Launcher 快捷方式。

快捷方式只启动当前应用 Activity。生成资源使用当前 variant 的 applicationId，DEV 不能误启正式包。原生与 Dart 均限制功能 ID；URI 不接收 query/fragment、身份、筛选或控制参数。默认 Flutter 深链接处理关闭，统一经宿主导航桥处理冷启动和已有 Activity 的新 Intent。重复 Activity 恢复不重放旧请求。

启动请求等待正常 Profile 恢复、选校与解锁流程；不自动选择其他身份或解锁。请求一旦绑定已恢复身份，切 Profile/学校则丢弃。打开时按当前学校默认能力来源解析并固定 package/digest；缺少能力显示不可用，不任意改用别的学校或同型包。页面继续使用已有领域组件、缓存、来源和取消规则；不触发校园卡支付、空调控制、拨号等写操作。既有 AppFunctions 的逐范围授权保持原语义。

桌面固定只在用户点击后调用系统 `requestPinShortcut`，返回值表示请求已交给 Launcher，不声称已经固定成功。快捷方式标签、图标和功能标识为宿主静态资源，不含个人课表、姓名、学校账号或私密数据。使用 Android 平台现有 API，不增加第三方依赖；Apple 本次仅同步应用版本。

固定成功通过明确目标、不可变 PendingIntent 到非导出 receiver 通知；收到后及恢复前台重新查询系统已固定集合和支持状态。请求受理与固定成功分别显示，没有回调保持未确认，不推断用户拒绝。系统限制、暂不可用与不支持分别归类，平台检查失败清除过时的已固定显示，不记录异常原文或私密参数。

## 验证与回滚

验证严格 URI/ID、冷/热启动、重复恢复、引导后继续、身份变化、来源固定、缺能力、无自动命令及固定失败。检查生成资源的正式/DEV applicationId、快捷方式和 App Actions 清单，保留 AppFunctions 授权回归。构建、自动测试、Launcher/系统助手真机验证与人工核心审阅分别记录。删除快捷方式元数据和桥可回滚；无学校包或业务 schema 迁移。
