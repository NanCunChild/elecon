# 受信学校脚本实施记录

## 通用请求与触发控制 2026-11-01

依据 [ADR-046](../adr/adr_046_triggered_script_requests.md)，新源码 action/grant 和额外确认已废除；下文 action 相关记录仅反映历史实施。空调通过普通 capability/ctx.fetch：一次控件事件发送一次控制 POST，结束后独立查询一次状态，执行中防重复触发，失败不自动重发。协议留在学校 JS，签到不再有 action 前置，当前社区包实现见末尾 ADR-052/053 记录。

旧 action 安装保留原始内容与 digest，不能作为 provider 或执行；用户导入更高版本无 actions 包后恢复。西电本科包升为 0.15.0；研究生不新增控制。隔离于原有未提交改动的 316 项 Flutter 回归、9 项学校合成协议测试、Dart 静态分析、TS typecheck、包/schema/共享展示夹具校验通过；验证仅使用合成数据与现有同版本 QuickJS Linux 测试库。人工核心/网络审阅及实际设备验收仍开放。


依据：ADR-034 / ADR-035。独立分支 feat/trusted-school-scripts，基线 a60db9f；原工作区已有登录代码修改未纳入，已验签 bundle 字节的只读复用见下文。

**当前工作目录（2026-10-30 所有者指定）**：`/home/nancunchild/projects/elecon`，分支 `feat/trusted-school-scripts`。已接入原新工作区的 `33bcdc4`；原 `elecon-trusted-scripts` 工作树留在 detached HEAD，后续开发在本目录进行。切换前全部已跟踪及未跟踪改动保存于 stash `1837515ffa21666526fe05d1ee1cf4fb493b6a1d`，并由固定引用 `refs/backups/elecon-before-trusted-scripts-20261030` 保留；未把旧登录实现混入新路线。

## 2026-10-31：本科水电与空调（ADR-040 已确认并实现）

所有者在审阅 ADR-040 后明确确认并要求完成。客户端 **0.5.0+8**，本科统一包 **0.14.0 / SDK 5**；研究生因公共 IDS/会话模块变更独立升为 **0.13.1 / SDK 4**，不新增水电/空调能力。规格接受与实现人工安全签收仍分别记录。

- 水电新增 energy.meters 和 energy.usage@1.1，多表发现/选择、余量、累计/前次读数与用量分别归一。旧 energy.usage@1.0 使用独立历史 schema 保留原校验行为，不套用新字段约束。JS 完成校园网 OAuth、逐请求签名、AES-CBC/PKCS7 和有界单表窗口；默认电表近日历月、水表近一年，显式窗口生效。独立 energy 会话复用已验证 IDS，继续学校原页登录，不接回 PDA 密码协议。
- 空调新增 climate.devices/status/command。用户主动绑定并核验自己的设备，保存于当前本科身份的 xidian.climate 命名空间；不扫描设备、不假装存在账户 discovery/token 登录接口。electricAmount 的余量语义未证实，因此省略，不编造剩余电量。
- SDK 5 actions 绑定批准 digest 内的精确 HTTPS POST endpoint。固定控制入口确认设备、学校/包和全部目标/联动设置；普通入口、工作台直接运行及 home 拒绝 command。宿主 grant 绑定身份、代际、设备、参数和有效期，单次占位/单请求、禁重定向/重试/交互重登；取消、退后台、切校、登出、更新或离开页面使确认失效。运行中的第二次/并发请求为致命失败，脚本捕获错误也不能伪报成功。
- 命令结果保留 accepted/rejected/unknown，HTTP/JS 成功不等于 applied；无实际请求不能报已发送。完成或失败后独立读取状态，只有完整目标匹配才确认 applied。界面开关和模式均由已核验状态驱动，原生下拉框不会提前显示用户目标。未知/错误/离线状态不能控制；首版宿主仅在 Android 前台接受控制，其它平台只读。
- 水电及空调为按 schema 选择的固定 Material 3 卡片，双语、可选元信息、窄屏/大字体布局；水电带真实成功时间恢复缓存/历史，空调按初始化/登录及界面可见生命周期同步，不进入周期预加载。未新增第三方依赖，不修改公网服务、V1 official/Masker/签名门或背景执行边界。

验证：Flutter 全量 **1167 通过、11 条件跳过**；学校 Node **144/144**；真实打包源码/SDK action 定向 **15/15**（含首次原生输入绑定、保存凭据类型、独立 OpenSSL 解密校验 QuickJS AES 请求）；工具链 smoke **24/24**、服务端 smoke **29/29**；workspace lint/typecheck、全量 Flutter analyze、54 份生成 schema 及 registry/validator 字节一致性、学校确定性构建/PII 扫描与 diff 检查通过。新增 schema golden 同步至 54 个 schema / 52 个 registry 引用，保留原有负例并新增 SDK 5 正例及未知 SDK 6 拒绝例。标准 codegen 检查通过；可选全仓 require-descriptions 仍报告 **27 处既有缺失**，本次水电/空调全部新增与修改字段已单独验证 description 覆盖，未借本任务改写其它领域。

Android 调试 APK：`client/build/app/outputs/flutter-apk/app-debug.apk`；aapt 核验 versionName=0.5.0 / versionCode=8，APK 内两校 JSON、README 与 MPL 许可证均与工作区逐字节一致。应用内仍须由用户确认新版源码/身份/网络/控制授权；没有覆盖已授权旧 digest，没有安装到手机、访问学校账号或调用真实设备。

**仍开放**：校园网水电及实际学校响应、用户明确选定空调的真机控制验收；核心/action/凭据实现及其测试的人工实质性安全审阅。合成测试、AI 自检和调试 APK 不等于上述签收或生产合并。

## 2026-10-30：登录收尾、首页缓存与公告正文（ADR-038/039）

本轮先将原工作区按决策、SDK/核心、学校集成、脱敏追踪工具保存为4次本地提交，再开展本增量。新客户端为 **0.4.0+7**，本科/研究生源码均为 **0.13.0 / SDK 4**；内置JSON、README和许可证与确定性构建一致。升级顺序是先客户端、后重新确认源码digest，不自动替代旧安装授权。

- IDS首次认证通过即显示固定宿主“正在登录”遮罩，保留取消并清除页面/原生焦点。两个完整Cookie快照至少相隔250ms，六个已授权路径并发读取；旋转/MFA/导航仍拒绝不稳定结果，IDS保存后继续真实业务验证。没有以250ms宣称真实网络总耗时。
- `manifest.home` 由脚本声明缓存TTL、预加载能力及默认参数；成功输出按当前学校、包digest及规范化参数缓存真实fetchedAt，复用H/S/M后端。缓存不算登录凭据、不进入UI凭据库，限制512KiB/条、32条和4MiB/学校、展示最多7天。
- 登录后、首页初次/恢复前台、前台每分钟按TTL非交互刷新，显式刷新可强制更新。后台不弹浏览器/输入/存储许可，不显示刷新动画；失败保留旧值与时间。卡片重建恢复缓存，切校、登出、更新代际清值，多阶段手动查询的旧成功结果不能重新写回UI。
- 公告标题移除嵌套日期，点击通过既有 `notice.detail` 获取纯文本正文、段落/表格分隔和附件名；提供错误重试与图片公告无文字提示。详情视图也绑定身份和执行代际，附件保持仅展示。

验证使用合成夹具：学校Node135项、工具smoke24组、TS类型检查、Biome、契约变更记录门及真实QuickJS/Widget回归通过。最终Flutter全量 **1128项通过、11项跳过**，`flutter analyze --no-pub` 无诊断。既有取消测试补为等待真实isolate清理完成并断言取消/无晚到写入，没有隐藏超时或放宽原断言；新增多阶段Widget测试在真实异步zone初始化QuickJS host port，避免测试自身的FakeAsync生命周期影响后续用例。

本轮学校账号登录、研究生/Apple真机验收尚未执行；不覆盖既有版本的历史手机证据。客户端测试机安装见下节。核心/存储/浏览器改动仍待人工实质性安全审阅，不代表生产合并或发布签收。没有新依赖，没有更改公网服务或V1验签路径。

### 后续：同步显示版本并安装测试机

所有者随后要求同步应用内版本并安装。`app_info.dart` 关于页默认显示从旧 `0.2.1-dev` 修正为 `0.4.0`，与两份pubspec的 `0.4.0+7` 对齐；CI的 `ELECON_VERSION` 注入保持有效。现有关于页/隐私页3项Widget测试及该文件静态分析通过。

本地 Android debug APK 已构建，包元数据为 `dev.nancunchild.elecon` / versionName `0.4.0` / versionCode `7`，信任profile仍为DEPLOY。包内两校0.13.0源码、README和MPL全文已逐字节核验。

通过 `adb install -r` 覆盖更新连接的 CPH2653，未清空应用数据；设备只读包元数据确认从0.3.0+6更新到0.4.0+7，随后成功启动MainActivity并取得运行进程。关于页实机无可读的UI自动化版本标签，未将包元数据核验表述为关于页视觉验收。两校JSON、说明和许可证另复制到 `Download/elecon-scripts/0.13.0/`。未代点源码授权或修改已批准digest，新脚本仍由用户在应用确认更新；不宣称真实学校认证或业务已验收。

构建/检查日志：`/tmp/elecon-version-{test,analyze,apk}.log`；APK为 `client/build/app/outputs/flutter-apk/app-debug.apk`。没有读取手机凭据、私密响应或完整UI内容并写入仓库。

### 早期阶段记录

- [x] 阶段 1：方向 ADR、规则覆盖与实施记录。
- [x] 阶段 2：精确域名/IP/CIDR 白名单及原生 HTTP 传输。
- [x] 阶段 3：新格式、版本/安装授权、真实凭据 API 与背景 QuickJS。
- [x] 阶段 4：浏览器 DOM 桥接、可见操作入口与脚本安装/运行产品接线。
- [x] 阶段 5：集成回归、文档、交叉审阅与剩余限制。

每阶段验证后 no-sign commit。不得将 AI 审阅记录为人工安全签收，不声称完成真实学校/真机验证。

阶段 2 验证：26 项网络/HTTP 测试通过（真实 loopback HTTP、DNS pinning、CIDR、跨域重定向、TLS 握手和取消）；四个相关 Dart 文件 analyze 无问题。文本响应支持 UTF-8 / 显式 Latin-1；其它编码需后续按学校样本扩展。

阶段 3 验证：20 项 manifest/凭据/真实 QuickJS 测试 + 6 项安装注册表测试通过；schema smoke（有效包与 12 项拒绝变体）、tools typecheck 通过。包括源码不在安装阶段执行、版本单调更新、持久化失败保留旧版、原始 Set-Cookie、非 UTF-8 原始字节、DOM API、取消与日志净化。新路径无需 Masker/opaque handle。

基线修复来源：原工作区已有未提交的 catalog 与 5 个 bundle/3，于本次工作中只读验签（预埋 elecon-official-ncc-1 公钥；catalog/revocation domain separation；openBundle 完整性/身份检查）。原字节复制到本工作树，替换基线 /2；没有签名私钥操作，没有补造签署者/仪式/人工复核事实，也没有修改签名内时效。该核验不代表吊销列表新鲜度或生产签收。原工作区登录/凭据代码修改仍未纳入。

阶段 4 验证：浏览器桥接 21 项、会话/真实 QuickJS/loopback 登录链 16 项、工作台与首页 5 项通过；全量 Flutter 1008 通过、11 按既有条件跳过，analyze 无问题。修复 Apple 默认 TLS/Cookie store、浏览器独占租约、同身份刷新串行、关闭/登出/更新取消、损坏安装恢复、内存凭据迁移、切校旧卡片和工作台结果残留。支持 Cookie 保存/恢复而不要求每次页面运行重新登录。Linux debug 编译通过；原生真机矩阵仍待人工。

## 首轮实现验证（2026-10-29，877e536）

- Flutter analyze：无问题。
- Flutter 全量：1008 通过，11 项按既有条件跳过。
- server smoke：29/29；tools smoke：22/22（含新 schema 与真实 CLI/npm workspace 打包回归）。
- Node lint / workspace typecheck、adapter validate、PII scanner：通过。
- server production build 与 public dist 正/负例：通过。
- codegen 后 contract/generated 无漂移；新源码包 schema/SDK 已加入 ADR changelog 门。
- bootstrap 自洽、现有官方签名只读核验、release preflight、客户端静态发布门：通过；不表示签名清单新鲜度或正式发布获准。
- Linux debug 与 Android debug APK：编译通过。APK 在 client/build/app/outputs/flutter-apk/app-debug.apk；Linux 在 client/build/linux/x64/debug/bundle/。
- 独立 agent 交叉审阅发现的问题已修复并回归；最终补齐按所选学校显示登录摘要。

## 范围与后续验收

本轮实现与上述自动回归已完成，未推送、未合并 main、未正式发布。Android/iOS/macOS 浏览器登录、HttpOnly、证书、后台切换等仍需真机；没有真实账号或真实学校在线验收。每校目前只有一个当前身份；同校换账号先登出。旧 official bundle/DSL 兼容路径保留，下一轮按真实学校迁移后再删除；不再扩展其校本算子。人工安全签收仍开放，不能以本记录或 agent 审阅替代。

历史工作区记录（2026-10-29）：当时新工作树为 `/home/nancunchild/projects/elecon-trusted-scripts`，原工作区保留原分支与已有修改；2026-10-30 已按本文开头接入本仓库。

## 复核：Masker、多凭据与版本（2026-10-29）

本次检查发现并修复了同校脚本默认键碰撞、隐式旧 ref 覆盖、更新丢失元数据、失败结束缺耐久屏障、设置切校误清全部学校凭据、SameSite 丢失、模板根路径采集遗漏、CLI/安装器已知语义差异，以及 Apple manifest 缺文件导入依赖的问题。

- [x] ADR-035 先行：`c8a8ed0`；SDK 2 的 `(schoolId, namespace, key)` 描述符、显式共享/旧数据访问、保存行为有据。
- [x] 核心与客户端：`7ae7d6d`；完整 id/namespace/key 可往返、默认脚本命名空间、SDK 1 原寻址兼容、失败保存与稳定存储错误、有效过期元数据、切校保留、SameSite 接线。
- [x] 工具与模板：`34531fa`；SDK 2 / 脚本版本 0.2.0，Cookie 按业务 URL 分组保存，不按 name 折叠；CLI 拒绝已知非法端口/CIDR/重复 origin/capability 等，实际模板通过 fake ctx 回归。
- [x] 文档同步：AGENTS、规则、相关旧 ADR 的适用范围、ADR 索引、术语、架构、契约与使用说明已更新；[Masker 审计](../reference/masker_retirement_audit.md) 明确仍在执行的旧链及退役条件。

最终复核结果：Flutter 全量 **1029 通过、11 条件跳过**；主清单与 Apple 清单 analyze 无问题；workspace lint/typecheck、tools smoke **23/23** 通过。Android 与 Linux debug 重新编译通过。Apple manifest/lock 补齐 file_picker，已验证 enforce-lockfile 和静态分析；保留原有 Apple 依赖 pin，没有据此声称 iOS/macOS 构建或真机已验收。对应日志位于 `/tmp/elecon-credential-audit-*`。

契约 ADR changelog 门、旧 adapter validate 与 bootstrap 自洽检查通过。旧签名资产未改，未执行签名私钥操作，也未改变历史人工签收状态。

**仍未完成的迁移**：Masker 没有全仓清除，V1 客户端/TS runtime/发行工具/契约/签名历史仍保留；SDK 1 默认学校共享键与旧 raw-ref 索引仍仅作兼容。SDK 2 的独立描述符不等于对整个旧 store 做了多校重构。同校多账号并存仍未提供；每校多个系统/多份凭据已在新路线回归。Android 缺少 Cookie 元数据的平台无法无损恢复完整 jar，真实学校、原生设备与人工审阅仍开放。

## 西电对照迁移（2026-10-30）

参考本机 `~/projects/traintime_pda` 的 `e780e4d01ea740c979ff5c31b9db439dbc586864`（2026-10-14）。参考仓只读，原工作区与 V1 adapter 缓存/pin/签名 bootstrap 保持原字节。实现与导入说明见 [西电脚本](../../school-scripts/xidian/README.md)，额外能力分类见[对照评估](../reference/xidian_script_update.md)。

- [x] 代码对照：本科/研究生教学、官方页认证、校园卡日期查询及新 OPAC；明确源码许可，校本目录保留 MPL-2.0 版权和全文。
- [x] 绑定修复：`10370fd`；真实 QuickJS 发现 STRING_ROPE 跨桥变 null，修复现有字符串边界并保留非字符串类型/严格输出校验。客户端基线为 0.2.1+3，SDK 和依赖 pin 未变。
- [x] 学校实现：`818e9e1`；数据包 `school-xidian@0.6.0`（11 个现有能力、无浏览器要求），独立登录包 `school-xidian-login@0.1.0`。没有新增标准 capability 或运行权限。
- [x] 集成：确定性打包、实际源模块与内置 HTML parser 回归、编译包真实 QuickJS 回归、CI Node 构建前置和新源码 lint；测试数据均为明确的合成占位。
- [x] 文档：使用/配置、版本、会话、许可、额外业务契约与宿主能力分开记录。只校正 card.transactions 过期来源注释，没有更改字段/格式/验证语义；codegen 无漂移。

验证：**58** 项合成模块测试通过；**9** 项实际包 QuickJS 集成通过；新增长拼接凭据/HTTP/DOM/输出回归通过；全量 Flutter **1039 通过、11 条件跳过**。主清单 analyze、workspace lint/typecheck、tools smoke **24/24**、学校合成数据 PII 扫描（0 error/0 warn）通过。Android/Linux debug 重新编译通过。具体日志为 `/tmp/elecon-xidian-*`。

当前边界：卡号是现有 card 输出的必填约束，来源缺失时需用户明确配置；未排课、成绩构成、考试结束、图书搜索/续借与其它新业务没有硬塞入不合适的字段。官方页面负责密码/滑块/MFA，脚本交互约 100 秒/总预算 120 秒，完整浏览器指纹/原生 Cookie 元数据与真实校园网络尚未验收。没有真实账号、付款、设备写操作、签名私钥操作或生产发布，人工审阅仍开放。

## 本仓库接入与西电学校身份隔离（2026-10-30）

依据所有者“将新工作区内容覆盖当前分支，之后均在 elecon 本仓库工作”的指示，已将 `feat/trusted-school-scripts` 接入 `/home/nancunchild/projects/elecon`；备份及旧工作区状态见本文开头。下列修改在本仓库进行，沿用 ADR-034 §3/§5 和 ADR-035 §2，没有新增宿主 API、依赖或业务契约。

- [x] 本科/研究生拆成 `xidian_undergraduate` / `xidian_postgraduate`；分别构建数据包 `0.7.0` 和登录包 `0.2.0`，共四个新 id 的包。同一校的数据/登录共享 namespace，不同学校凭据按 SDK 2 完整地址隔离，不迁入旧 `xidian` 会话。
- [x] 数据包以固定角色选择教务；忽略旧 IDS 角色元数据，冲突的 `role` 在请求前拒绝。本科包不声明 YJSPT origin，也不允许其登录；研究生默认 YJSPT，显式 E-Hall 登录仅供公共教室等共享应用，不改变研究生教务路由。
- [x] 新脚本 MFA 修复：完整加载、当前学期只读业务验证、Cookie/页面至少 1.2 秒稳定、写入前再次检查；临时成功页后进入 MFA 或持续 Cookie 轮换不会落新凭据，失败也不写部分 IDS 快照。六轮采样和既有 100/120 秒预算保留。
- [x] 合成回归：64 项 Node 模块测试；128 项 Flutter 脚本测试，包含 12 项实际包 QuickJS 集成，验证四包安装成为两校、默认目标、角色拒绝、同名凭据、切校和单校登出。Node 确定性打包与 PII error 检查、tools typecheck / 定向 Biome、全客户端 analyze 通过。
- [x] 迁移说明：构建器清理两个旧输出包名；新 id 须重新由用户确认安装，使用者选择对应本科/研究生学校。旧 V1 兼容入口未修改，其历史缺陷不因新脚本修复而视为已签收。
- [x] 本目录 Android debug APK 构建通过：`client/build/app/outputs/flutter-apk/app-debug.apk`，客户端 `0.2.1+3`。四个学校包位于 `school-scripts/xidian/dist/`，需另行导入；没有在 APK 构建时静默授权安装脚本。

真实账号与原生 MFA、后台切换、Cookie 属性仍待人工真机验收；未自动安装脚本、提交 MFA 或导出学生凭据，未推送或合并主干。

## 手机登录后业务不可用诊断（2026-10-30）

本轮只读取安装信息、非敏感选校元数据及经字段筛选的日志；未读取解密凭据、密码、响应体或学生业务结果。

- 手机正式包版本为 `0.2.1` / code 3，但安装 APK 摘要及其 Dart kernel 均与本目录上轮 `app-debug.apk` 不一致；版本标签不能单独证明运行代码一致。
- 当前保存的学校 id 为旧 `xidian`；应用私有凭据目录中没有 `trusted-scripts.json`，新学校脚本尚未持久安装。当前调用仍走 V1 official 路线，上述 SDK 2 的分校及 MFA 修复没有参与本次登录/首页请求。
- 脱敏日志显示公开教务通知 HTTP 200；成绩、课表、考试、教室的本地 `ensure` 曾返回 ready，随后 E-Hall 出现重定向，IDS 最终有 login 页 HTTP 200。本地有条目不代表学校仍认可会话；现有日志没有足够证据将失败明确归因为 MFA。
- 四个最新源码包及 MPL 许可已放入手机 `Download/elecon-scripts/undergraduate/`、`postgraduate/`；对应学校须分别确认导入数据包与登录包，选择新学校后在官方页面重新认证。没有通过写私有注册表绕过安装确认，也未把旧身份凭据复制给新学校。

后续验证以手机运行同一构建、正确学校包已安装且启用为前提：先运行对应登录包，确认其业务验证成功，再查询首页成绩/课表，按新调用的净化错误码区分认证、网络与源字段问题。本轮不记录真实账号 MFA 或所有业务已验收通过。

## 西电内置选校与登录跳转追踪（2026-10-30）

依据本轮“将西电新脚本放入应用默认选择，并追踪登录允许 URL 问题”的授权，沿用 ADR-034 §2/§4/§5/§6 和 ADR-035 §2/§4：

- [x] 首次选校页直接展示本科生/研究生，旧 `xidian` 不再列为默认选校项；设置 → 学校脚本也提供内置选择。四个源码包随应用资源分发，两种学校各自展示数据/登录两包、源码与权限，经一次显式确认再安装和切校。取消不写安装授权；已安装较新版本保持原源码，不降级。旧 `xidian` 身份凭据不迁移。
- [x] 主清单与 Apple 清单均包含学校资源目录；生成资源附 MPL 全文、版权与 README。构建 smoke 逐字节核对四包及许可/说明，避免源码修复后仍分发旧内置副本。
- [x] 未登录的只读入口探测：E-Hall / YJSPT 转向 IDS（包括等价的显式 `:443`）；校园卡为 `v8scan.xidian.edu.cn → xxcapp.xidian.edu.cn → ids.xidian.edu.cn`。后者的精确 HTTPS origin 原先未声明，现已补入四包和脚本自身的 HTTP 重定向列表；数据包升为 `0.7.1`，登录包升为 `0.2.1`，权限变更须重新确认。
- [x] 工作台记录浏览器 loading/ready/blocked 的 origin 与稳定码；脚本记录打开、已验证并保存阶段。被拦截 URL 在宿主丢弃 userinfo/path/query/fragment 后才进入诊断；导航取消错误或旧页面完成回调不覆盖 blocked。真实 QuickJS 只传递已知浏览器稳定码，原生异常仍归一化，脚本不会将白名单拒绝当加载中重试。
- [x] 自动验证：146 项 Flutter 脚本/本地化测试、66 项 Node 合成协议测试、确定性打包与资源一致性、tools typecheck/定向 Biome、客户端 analyze、PII scanner 均通过。覆盖安装取消/双包选校/较新版本保持、两校实际 manifest 的校园卡跳转链、相似恶意域名拒绝、诊断去秘密、Cookie 查询拒绝不清页面，以及真实 QuickJS 错误码桥接。

Android debug APK 已重新构建：`client/build/app/outputs/flutter-apk/app-debug.apk`；逐字节检查 APK 内的四包及许可/说明与工作区资源一致。构建日志为 `/tmp/elecon-bundled-apk.log`，Flutter/Node 测试日志为 `/tmp/elecon-bundled-scripts-test.log`、`/tmp/elecon-bundled-node-test.log`。

没有使用账号提交认证；本次未登录入口探测不能证明认证后跳转或原生 MFA 已验收，也不能据此确定上次报错一定来自校园卡。后续真机重现可从工作台日志中的 blocked origin 与 system 定位。涉及宿主浏览器与错误码处理的人工审阅仍开放；自动验证不等于生产合并或安全签收。

## 统一包与手机同步诊断（2026-10-30）

本节取代上节分包交互。所有者要求登录与取数合包，并授权同步调试；实现继续受 ADR-034 §2/§3/§5/§6 和 ADR-035 §2/§3 约束，没有增加宿主 API 或修改 `contract/`。

- 手机只读元数据确认当时仍启用本科数据 `0.7.0`、独立登录 `0.2.0`。脱敏日志证实 catalog 曾收到 `script:school-xidian-undergraduate-login`；成绩页可选 `gpa.summary` 等未声明能力会走这一错误回退。源码身份现在只使用本地注册表，缺能力/注册表失败明确返回源码路径错误，不查询 catalog；V1 official 验签与吊销路径保留。
- 每校只生成一个 `0.8.0` 包，包含 11 个业务能力和同包 `generic.section` 主动登录。私密查询按目标捕获认证失效，登录验证保存后继续同一查询；每个目标最多重登一次。业务解析错误、输入错误与取消不自动重试。应用内置更新经确认后移除当前学校旧登录安装，保留其共享凭据。
- 浏览器宿主按首次浏览器调用创建页面与独占租约；公开通知/有效会话查询不会打开空页面，HTTP 可在无浏览器平台继续执行。原生 `about:blank` 回调被取消且不记作学校站点越界；学校 URL 仍按精确 origin 检查。此项修复不代表已证实上次短暂越界提示的所有来源。
- 新脚本的净化日志接入 DevLog，浏览器仅记录状态/origin/稳定码，使手机运行时日志可以定位 `adapter_failed` 背后的脚本失败。IDS 正式页输入的数字账号仅在目标业务验证成功后写入当前学校会话，失败不保存，也不进入日志/结果；仍可显式提供 studentId。

自动验证：152 项 Flutter 脚本/本地化测试、71 项 Node 学校合成测试、tools typecheck、定向 Biome、PII 扫描（0 error/0 warn）和客户端 analyze 均通过。包含真实 QuickJS 同包登录后续查/缓存复用、过期重登有界、取消不落部分凭据、统一更新移除旧登录安装但保留凭据、无浏览器取数、空白页回调以及源码缺能力不查 catalog。

Android debug APK 已构建并逐字节核验包内只有两个统一脚本、许可和 README；已通过 `adb install -r` 更新已连接手机并启动应用，没有清空应用数据，也没有直接写设备的安装注册表。安装新 `0.8.0` 源码包的内容确认与学校认证由用户操作；等待本轮复测。日志为 `/tmp/elecon-unified-{flutter,smoke,analyze,apk}.log`，仅采集错误码/浏览器 origin 的同步诊断为 `/tmp/elecon-unified-device.log`。自动部署与合成测试不代表真实 MFA/人工安全签收。


## 登录直达与真实失败原因修复（2026-10-30）

沿用 ADR-034 §2/§3/§5/§6、ADR-035 §2/§3。本轮保留原工作区未提交改动，没有改动 contract、增加依赖、扩大网络清单或访问其他学校身份。

- 设置页登录不再转到脚本工作台；按所选 provider 执行同包 generic.section 认证入口，登录 URL、验证和凭据收割由脚本承担。可取消；缺入口不尝试运行其他学校脚本。校园卡补登请求由脚本选择对应 target。
- `0.8.1`：固定错误类别取代可恢复失败的 adapter_failed；缺卡号/学号提供固定表单，提交后只重试一次，取消/切校不重放。教务可复用同校已验证 IDS 学号，补填学号通过当前学校凭据保存。任意异常 code/message 不透传；未知错误仍净化。实际脚本与真实 QuickJS、设置页/补填/取消回归覆盖。
- 手机实际日志先确认 card_number_required、student_id_required、academic_response_invalid、xidian_redirect_origin_denied；前两项修复并增加合成回归，后两项增加静态表名/形状和 scheme/host 的净化诊断，没有记录学生业务值或认证参数。
- 所有者在手机确认 `0.8.1` 后复测登录，17:18 日志证实 IDS → HTTPS E-Hall → **HTTP E-Hall**，被精确 origin 闸门拒绝。浏览器新增默认端口主框架 GET 的 HTTPS 替换：仅当替代 HTTPS origin 已授权时取消 HTTP 并加载 HTTPS，不允许 HTTP、本体 POST 重放、额外端口或其他站点；保留原 open 等待和取消回调隔离。
- `0.8.2`：学校 HTTP 客户端对无 body GET/HEAD 的旧 HTTP Location 做同样 HTTPS 替换，含显式 :80；307 POST 不被升级重放，仍拒绝跨源敏感 body。浏览器策略拒绝映射为固定 network_denied，不再丢成 adapter_failed。

自动验证：213 项 Flutter 脚本/本地化/旧登录与首页回归、76 项 Node 学校合成测试通过；tools 确定性构建 smoke/typecheck、定向 Biome、测试夹具 PII 扫描（0 error/0 warn）通过。对整个学校源码目录运行 PII 启发式扫描会把既有变量赋值误判为凭据，未修改或放宽扫描器；脱敏验证范围为测试夹具。客户端 analyze 和 Android debug 构建见 `/tmp/elecon-https-fix-*`。

`0.8.1` 客户端调试版曾通过 adb install -r 更新手机，未清除应用数据；源码更新由用户在界面确认。`0.8.2` 浏览器/取数修复完成合成回归；APK 已逐字节核对内置两包及许可，并通过 adb install -r 更新手机、启动进程（本次 pid 2766），保留应用数据。宿主登录修复对已安装 0.8.1 也生效；0.8.2 取数源码仍须用户确认更新。真实账户登录及全部业务最终通过仍待手机复测；不以自动测试替代人工安全签收，未推送/合并/发布。


手机后续复测：只读安装元数据确认已启用 `0.8.2`。17:28:41 净化 WebView 日志记录 `browser HTTPS replacement https://ehall.xidian.edu.cn`，随后 HTTPS 页面加载完成；本轮未重现 navigation blocked。尚未看到 `xidian_login_saved:ehall` / generic.section 成功结束，不把“HTTPS 页面已加载”当作完成业务认证。等待所有者确认当前页面状态，继续定位验证未完成的原因。


## 原始 HTTP 跳转拟真测试（2026-10-30）

所有者反馈 0.8.2 的 HTTPS 替换后页面显示维护，而普通浏览器登录正常，明确要求先允许 HTTP URL 拟真验证。本节取代上节的协议替换尝试，遵循 ADR-034 §4 已允许的精确 HTTP origin 声明路线，不全局关闭白名单。

- 客户端移除隐式 HTTPS 替换及其过渡回调逻辑；主页面按安装脚本的原始 scheme/host/port 清单裁定，TLS 验证保持原样。
- 两校源码包 `0.8.3` 明确增加 `http://ehall.xidian.edu.cn`，未开放 HTTP IDS、其它站点或额外端口；源码更新仍须确认安装内容/digest。
- E-Hall 浏览器业务验证接受此已声明 HTTP 页面，只在学期接口验证及页面/Cookie 稳定后保存实际 origin，按该 origin 收割/恢复 Cookie。后续教务请求沿用已验证 origin，并保留服务器原始 Location；不把 HTTP 页面又换回 HTTPS 维护入口。跨源敏感 POST 仍不重放。
- 加入有界、固定类别的认证等待诊断（业务页尚未到达、接口失败/重定向、格式不符、维护页），不记录页面文本或用户数据；最多八条，不无限增加 host 调用。
- 旧“强制 HTTPS”回归按本次授权变更替换为“精确声明的 HTTP 原样加载”，保留未授权站点、端口、身份、Cookie 和 POST 负例。新增实际编译源码 QuickJS 回归：HTTP 业务页认证、HTTP Cookie 收割、保存 origin、HTTP 取当前学期。

验证：213 项 Flutter 脚本/旧登录/首页/本地化回归、77 项 Node 学校测试，确定性构建 smoke、analyze、定向 Biome 通过；Android debug 构建完成，APK 内两包和许可字节与工作区一致。日志为 `/tmp/elecon-http-replay-*`。真实 HTTP 认证、维护页差异及全部业务是否恢复仍以本轮手机复测为准，未声称人工安全签收或生产发布。

## E-Hall 浏览器认证入口对照（2026-10-30）

按所有者要求参考本地 traintime_pda，在指定 `CPH2653` 设备调试，沿用 ADR-034 §2/§4/§5 和 ADR-035 §4；保留原工作区改动。此项不改宿主能力、网络授权范围、业务成功条件或 V1 路线。

- 未登录请求及设备独立 Chrome 都确认：从 E-Hall `/appShow` 开始会先生成 `/login` 回调，再转到 IDS；外层 CAS service 包含学校生成的会话路径和内层 service。当前脚本参照 Traintime 的 HTTP target，直接构造 `IDS login?service=appShow`，与这条浏览器入口链不同。该差异已证实，但尚不能仅凭未登录链路认定它是全部故障的原因。
- 原版真机 WebView 曾进入 HTTPS `/jwapp/sys/wdkb/*default/index.do`；浏览器内当前学期探测返回 HTTP 200、`text/html`，页面标题“系统异常”、静态提示“正在紧急修复 / 调用接口异常”，没有有效业务 JSON。增加 XHR 头会改变响应格式，但未证明接口成功，因此本修正没有据此更改验证请求或放宽收割条件。
- 两校包升为 `0.8.4`：本科认证及研究生共用 E-Hall 教室认证改从学校 `/appShow` 入口开始，让学校初始化会话并生成完整回调；不保存或手工拼接动态回调。研究生平台、校园卡及图书馆入口保持原行为。脚本更新需重新确认 digest。
- 更新入口断言，仍验证登录前恢复、业务 JSON/稳定性验证、HTTP origin 与 Cookie 保留、取消/MFA 不保存部分会话、学校身份隔离及后续查询复用。77 项 Node 回归、21 项 Flutter 回归（真实 QuickJS 与登录入口）、客户端 analyze、定向 Biome、确定性打包和测试夹具 PII 检查通过。APK 内两包、README、许可逐字节匹配资源。

构建及回归日志为 `/tmp/elecon-ids-{smoke,flutter,apk}.log`。独立 Chrome 调试限本次学校标签，跳转采样只输出脱敏路径、origin、参数键及状态，不采集密码、验证码、Cookie 值或响应业务数据。设备仍需确认新源码并完成账号认证，当前不记录“真机修复已验收”；自动回归不代表人工安全签收或生产合并。

后续所有者反馈仍进入错误页，要求先总结现有收割、再用独立 profile 的 Chrome 手动执行 E-Hall 登录及无 service 的 IDS 门户回访。入口差异仍是待验证假设，不据此记录修复完成。新增本地 `scripts/browser-trace.mjs` 监听工具及合成/真实 Chrome 回归，使用方法与当前收割耦合见[独立 Chrome 认证监听](../reference/browser_auth_trace.md)；不继续修改应用认证流程，等待手动实验的浏览器证据。

手动实验已完成：IDS 登录回跳时即设置 HttpOnly `CASTGC`（`/authserver`），无 service 回访发送同一指纹 Cookie 并进入个人中心；E-Hall 另有 `MOD_AUTH_CAS`。保留用户设置页的后台检查中，相同 `/appShow` 和学期接口在独立 Chrome 返回正常业务 JSON，XHR 头不决定成功。手机只读元数据确认已经启用 `0.8.4`。证据与作用域判读已补入上述文档；本轮不把维护页归因于“未取得通用令牌”或学校接口整体维护，也未将手机问题标记修复完成。当前 IDS 保存与 E-Hall 验证耦合仍待修正，WebView 与正常浏览器的具体差异仍需定位。

## 按浏览器实验实施分阶段登录（0.8.5，2026-10-30）

所有者明确授权按实验建立脚本登录并升版实验；沿用 ADR-034 §2/§3/§5/§6、ADR-035 §3/§4。保留既有工作区改动，本轮不修改核心、契约、SDK、网络范围或依赖。

- 两校包升为 `0.8.5`。E-Hall 路径先访问 HTTPS 门户根入口，等 `/new/index_xd.html` 的只读响应严格满足 `hasLogin === true` 和应用列表格式；再访问无 service 的 HTTPS IDS login，在个人中心以只读账号设置接口校验成功码及有效账号标识。校方内部标识/设置正文不进入宿主、日志或业务结果。
- IDS 原三个认证 URL 加个人中心页面及账号设置 API，共五个采样/恢复 URL；按实际 path 保留同名 Cookie。独立快照稳定 1.2 秒且最终复查通过后立即保存 `ids`，然后才访问 `/appShow`、验证学期并保存 `ehall`。后续失败、超时或取消不覆盖旧业务快照，已接受的 IDS 写入按 ADR-035 保留；业务阶段不再采集未经 IDS 复查的 Cookie 覆盖它。
- 覆盖本科教务及研究生共用 E-Hall 教室认证；研究生平台、校园卡和图书馆入口保持原逻辑。分阶段共享 140 次轮询、五条等待日志，IDS/业务最多四/五轮采样且至少隔 750ms，100 秒 deadline 不变。边界回归同时达到全部 140 次轮询、16 个恢复 URL、四/五轮快照与等待日志，实际 250 次宿主调用，小于 256 上限；保留 MFA、Cookie 轮换、最终导航复查、切校及未授权 URL 负例。
- 验证通过：84 项 Node 学校回归与测试夹具 PII 扫描、164 项 Flutter 脚本/本地化回归（含编译源码在真实 QuickJS 中的三段导航、提前保存 IDS 后业务失败、同名 Cookie 分路径、学校隔离）、tools typecheck、定向 Biome、客户端 analyze、确定性打包与 APK 资产逐字节核对。
- 在原独立 Chrome 的已登录 profile 中，实际页面检查函数对门户、IDS 和教务三阶段均返回 `ready=true`；后台标签已关闭，用户个人中心保持打开。此结果不替代 Android 首登/MFA 验证。

Android debug APK 已通过 `adb install -r` 更新到指定 CPH2653，保留应用数据。两校源码包、许可证和说明另放在手机 `Download/elecon-scripts/0.8.5/`；APK 同样内置两校 `0.8.5`。已有源码安装仍按 digest 确认，尚不记录手机新版本已启用或修复完成。验证日志为 `/tmp/elecon-staged-{smoke,all-flutter,apk}.log`，实现及测试仍需人工实质审阅，未合并/发布。

## 0.8.5 真机分支与 0.8.6 修正（2026-10-30）

所有者已在指定 CPH2653 确认启用本科 `0.8.5` 并复测。脱敏日志记录门户 → IDS，仍处于 `ehall-portal` 等待时，CDP 只读观察到页面为 `/personalInfo/personalMobile/index.html`（加载完成，无密码框、参数错误或维护提示）。该轮最终 `authentication_timeout`，尚未进入 `xidian_login_saved:ids`；此前桌面路径假设未覆盖此移动落点，不能记录真机修复完成。

- 两校源码升为 `0.8.6`，允许 IDS 桌面和已观测移动个人中心两个明确路径通过同一账号设置接口验证。若门户阶段先到达经接口验证的 IDS 个人中心，先执行无 service 检查与稳定采集并保存 IDS，再在同一浏览器中返回门户一次；必须重新通过门户 `hasLogin` 验证才能访问教务。再次落到 IDS 只会有界失败，不循环重开或丢弃已验证的 SSO。
- 移动个人中心加入采样/恢复，共六个 IDS URL，全部恢复时合计 17 个 URL。分阶段轮询改为 750ms，最多 135 次，100 秒 deadline 不变。四/五轮快照、最多一次恢复和等待日志均有界；最坏调用上界 254，小于 SDK 256。边界回归覆盖有/无移动恢复的全部轮询与最大采样，原 250 次普通路径断言保持。
- 86 项 Node 学校回归及夹具 PII 检查、165 项 Flutter 脚本/本地化回归通过，新增真实 QuickJS 的移动落点 → 保存 IDS → 恢复门户 → 业务成功；未循环恢复和业务失败保留 IDS 等负例继续覆盖。tools 构建一致性、定向 Biome、客户端 analyze、Android debug APK 与两包/许可/README 逐字节检查通过。实际新页面检查函数在仍已登录的独立 Chrome 中，对门户、桌面 IDS、移动 IDS 及业务页均返回 ready。

`0.8.6` APK 已通过 `adb install -r` 更新手机，源码与说明另在 `Download/elecon-scripts/0.8.6/`；部署后只读注册表仍为 `0.8.5`，等待用户确认更新后复测。监听已切换到新进程，纯脱敏阶段日志为 `/tmp/elecon-staged-086-device.log`；上一轮为 `/tmp/elecon-staged-device.log`。不扩大 HTTP IDS、其它网络 origin、SDK 或宿主能力，未声称最终真机验收/人工安全签收。

所有者后续反馈仍有接口调用异常，并要求重新对照 PDA、评估完整复刻认证协议。手机只读注册表确认已启用 `0.8.6`；当前错误页实为 E-Hall `/jwapp/sys/wdkb/*default/index.do` 的“系统异常 / 调用接口异常”，不能直接记为 IDS 认证失败。对参考 `e780e4d0` 的实际调用链复核确认：PDA 是无 service 的原生 HTTP 初登，再按目标签票；当前网页导航实验尚未移植该协议。已形成[源码对照与实施切分](../reference/xidian_pda_auth_comparison.md)，列出 UA、指纹、AES/表单、MFA 后签票、原始 CookieJar、业务 HTTP 和预算/交互缺口，尚未实现或签收 PDA 协议模式。


### 2026-10-30：PDA 协议版 0.9.0

- 本科/研究生源码包升至 0.9.0，客户端实验基线 0.2.2+4。E-Hall/YJSPT 已移植原生 IDS 表单、稳定 bfp、AES、手动滑块、continue、SMS/企业微信 MFA 与重新签票、统一 CookieJar 和学期 POST；校园卡/图书馆保留浏览器登录。
- 浏览器只提供明确标注 elecon 的输入界面及 WebCrypto，不再作为教务 Cookie 来源。密码和 OTP 不持久化；已验证 IDS 与其后轮换独立保存。学校身份隔离、版本 digest 确认及 V1 旧门不变。
- 使用已有 SDK 最大 40 次 HTTP 请求预算，并保留 120 秒/256 次宿主调用边界；新增 40/41 次真实 QuickJS 回归。PDA Location 的 HTTPS 改写仅限 PDA 会话，旧 HTTP 会话回归保留。
- 状态：自动化回归及本地实验产物见本轮验证记录；真实账号登录/取数、人工安全审阅和正式生产发布仍须分别确认，不能由合成测试替代。


0.9.0 验证记录：107 个 Node 协议/业务用例（包含辅助夹具的 PII 扫描）、166 个 Flutter scripts/l10n 用例通过；真实 QuickJS 覆盖密码/滑块宿主交互、全局 SSO、移动个人中心回跳、业务失败保留 IDS、MFA 未完成不产生凭据，以及 40/41 请求边界。Chrome 的合成 HTTPS 页面验证一次性取值、提交后清空和 WebCrypto，不提交学校账号；另以无账号 GET 确认当前 IDS 表单及滑块响应结构。

最终检查补充：设备指纹仅在验证后的 IDS JSON `data.browserFingerprint` 中持久化，未完成主认证不创建单独设备凭据；旧 0.8.x WebView 业务 Cookie 不进入新原生签票 jar。关闭 flutter_inappwebview 默认 debug 原始事件日志，避免 JS handler 参数中的密码/OTP/Cookie 被插件直接输出；测试调用插件实际日志函数验证这一点，宿主脱敏阶段诊断保留。这些是 ADR-034 §6 / ADR-035 §3 既有约束的实施修复，没有增加 API 或开放权限。

最终分发：Android arm64 Debug 与使用本机发布证书签名的 Release APK 已生成，APK 内置学校源码/README/LICENSE 与最终 0.9.0 包逐字节一致；Release 的 DEPLOY 标记、旧侧载符号排除和实际 INTERNET 权限检查通过。指定 CPH2653（192.168.8.103:42557）已安装并启动最终 0.2.2+4 实验版，两校最终源码已同步到 Download/elecon-scripts/0.9.0 并校验 SHA256。设备当时处于系统锁屏；尚待用户解锁、确认新版源码并重新登录。脱敏阶段监听已就绪。本地发版产物与 SHA256SUMS 位于 dist/xidian-pda-0.9.0；未提交生产合并、打正式 Git tag 或创建 GitHub Release，人工安全审阅与真实账号验收仍未完成。

### 2026-10-30：0.10.0 默认恢复 WebView，PDA 协议解耦

按所有者本轮要求，先完成学校原页 WebView 登录/收割，账号密码代请求留待后续原生界面。遵循 ADR-034 §3/§5、ADR-035 §2/§3；没有增加 SDK、契约、依赖、网络来源或 V1 权限。

- 默认 `login.js` 改调用独立 `webview_login.js`；`pda_login.js`/`pda_ui.js` 仅在实验测试中显式构建，两个默认学校包均不包含密码协议和自绘密码界面。原 PDA Node/QuickJS 用例保留，不以删除测试完成切换。
- 无 service 的 IDS 官方页完成学校密码/滑块/MFA；个人中心通过既有只读设置接口验证后稳定收割并独立保存 IDS，不以 Cookie 存在作成功条件。
- 服务签票与学期 API 单独验证；WebView 不再打开曾报“调用接口异常”的业务 HTML。学校 HTTP 跳转保持原 origin；旧 PDA 会话继续可查询，重新登录走 WebView。
- 校本 HTTP helper 支持暂存新业务 jar：验证前不覆盖旧业务，已验证 IDS 的响应 Cookie 轮换仍即时保存。取消、业务拒绝、跨源重放和白名单检查继续生效。

本轮验证：学校 Node **114/114**；Flutter scripts/l10n **169/169**（含实际包真实 QuickJS **20/20**，保留独立 PDA 实验回归）；Flutter 全量 analyze、学校源码/测试 Biome、tools typecheck、确定性打包及 PII smoke、`git diff --check` 均通过。Android arm64 Debug 构建并覆盖安装至此前指定 CPH2653，内置两个 `0.10.0` 源码包、README 与许可证逐字节核验通过；手机 Download/elecon-scripts/0.10.0 同步两校更新文件。未更改任何已批准的旧 digest 或代点源码安装确认。

**本科真实手机登录已通过（本轮 12:24–12:25 UTC）**：固定日志依次记录 `xidian_login_open:ids → xidian_login_saved:ids → xidian_login_exchange:ehall → xidian_login_probe:ehall → xidian_login_saved:ehall`，`generic.section` 最终 `ok`。浏览器 loading/ready 全部只在 IDS origin，未导航至 E-Hall/教务 HTML；不导出账号、票据或 Cookie 值。随后 12:25:50 UTC 的独立 `grades.list` 同样 `ok`，证明已保存会话能被后续成绩请求复用。此项证明本轮官方页认证、会话收割、CAS 签票、学期验证及随后成绩查询成功，不能扩展为所有教务接口、研究生、校园卡/图书馆、Apple 平台已实测。

脱敏日志位于 `/tmp/elecon-webview-device.log`，测试日志为 `/tmp/elecon-webview-*`。没有生产发布或人工安全签收；遵循 AGENTS 红线 #1/#3/#4/#5/#7/#8，人工代码审阅仍开放。

### 2026-10-30：考试安排、PDA 一卡通读取与默认教学周（0.11.0，待真机复测）

本轮所有者反馈考试安排返回无法识别，并要求参考 PDA 一卡通和当前周。保留既有工作区；主认证继续官方 WebView，不重新接入密码协议。

- 手机只读复现：`exam.list` 的 `wdksap` 进入 `academic_table_invalid:wdksap:rejected`，有行数组但状态校验失败。源码按 PDA `exam_session.dart` 将考试已安排/待安排/研究生表的成功判据独立为顶层 `code=0` 和有效行数组，不套用课表表级 `extParams.code=1`；分页、异常顶层码和缺行数组拒绝不变。需要新版源码真机复测，不以合成回归断言学校当前业务响应已经成功。
- 校历按学校开学日和北京时间计算教学周；首页在用户点击时先查校历，以该学期/当前周查课表。默认模式每次查询都重读校历，手动选周不会被覆盖，未声明校历的旧学校保留原手选。
- 校园卡账户余额优先读取 PDA 的首个账户 li 金额单元格，再支持明确余额标签，不用页面任意币值推断。校本卡 OAuth 最多 30 跳，与参考行为一致，宿主总请求/时间、origin、Cookie 和重放检查不变。
- 手机当前卡查询复测返回 `input_required_card_number`，已到达账户页面。PDA 查询本身不需要卡号，但现有输出契约强制 cardNumber。已先起草 [ADR-036](../adr/adr_036_card_account_identity.md) 并询问所有者是否允许无卡号时按账户显示；**尚未收到选择，未修改 contract 或伪造卡号**。金额读取/跳转修复可独立审阅。

自动验证：学校 Node **118/118**；Flutter scripts/schema decode/l10n **192/192**，包含真实 QuickJS 考试表状态和当前周、首页本周/手选回归；全量 Flutter analyze、学校源码/测试 Biome、tools typecheck、确定性构建/PII smoke、diff 检查通过。客户端实验包 `0.2.3+5`、两校源码 `0.11.0` 已在本机生成，APK 内源码/README/MPL 与当前资源逐字节一致。没有用新内容覆盖已授权旧 digest，尚未安装/执行本轮新版源码，尚不声称本轮真机修复通过。

卡号契约选择和新版源码手机确认/业务复测仍开放，人工安全审阅仍开放。日志为 `/tmp/elecon-campus-*`。

### 2026-10-30：ADR-036/037 已确认，SDK 3 通用输入与可选卡号（0.12.0）

所有者明确确认“没有提供卡号时取消强制手填”，并要求底层由脚本决定何时、哪些字段需要输入。先接受 ADR-036 并记录 ADR-037，再实施；这些决策接受不等于核心代码已由人工安全签收。前节 0.11.0 的卡号契约等待项由本节取代。

- card.balance/card.transactions 的 cardNumber 可省略；有值须为非空字符串。生成类型/输出 validator/解码/固定卡片一起更新，未提供时显示校园卡账户，不以学号/openid/空占位替代。西电余额按 PDA 账户单元格读取，流水不再为了补卡号额外请求账户页。
- SDK 3 新增 `ctx.ui.requestInput`（text/password/select），脚本选择字段/时机、处理取消并自行保存，宿主固定表单及边界验证。SDK 3 凭据继续用 SDK 2 完整地址，不回退 SDK 1；新包让旧客户端在解析阶段拒绝。
- SDK 3 输入不需要 browser=true 或 Cookie 租约；每次调用最多八表单、每表八字段、32 KiB 请求，拒绝并发，保留 host/network/120 秒边界。提交值进入日志秘密集合，原文不出诊断；密码遮挡、关闭建议与键盘个性化学习，提交/取消清空显示。
- MainShell、工作台和手动登录接入同一 presenter 生命周期；切校/登出/禁用/更新/销毁/超时关闭旧弹窗，晚到提交无效。共享首页删除按卡号/学号错误码猜测输入并重跑的逻辑；西电脚本仅在业务确需且缺学号时主动请求。默认主认证仍走官方 WebView，不接回 PDA 密码协议。
- 保留本轮考试成功判据与校历当前周修复；失败诊断仅增加顶层/表级状态的固定分类，不输出服务器 code/message/rows 原文。

验证：Flutter 全量 **1097 通过、11 条件跳过**；学校 Node **120/120**；server smoke **29/29**、tools smoke **24/24**；workspace lint/typecheck、全量 Flutter analyze、生成物一致性、确定性打包/PII 与 diff 检查通过。回归覆盖真实 QuickJS 输入提交/取消、日志净化、长拼接请求、次数/并发/超时、SDK 1/2 不获 API、当前身份寻址，及 widget 切校/登出/禁用/更新/调用者销毁/晚到提交。旧 UI 启动用例调整为非退役合成学校并等待选校重建，保留原有登录/取消/主页故障断言；SDK 未知版本负例从 3 调整为 4，新增 3 正例，未删除拒绝门。

客户端 **0.3.0+6** Debug 已构建并安装/启动此前指定 CPH2653；两校 **0.12.0 / SDK 3** 包已同步到手机 Download/elecon-scripts/0.12.0。APK 内源码/README/MPL 与当前资源逐字节一致，源码安装仍需应用内确认，没有修改旧授权 digest 或代点安装确认。脱敏阶段监听 `/tmp/elecon-input-device.log`，检查日志 `/tmp/elecon-input-*`。

新版学校业务真机复测与人工核心安全审阅仍开放；尚未生产合并或发布。

#### 0.12.0 手机结果与 0.12.1 校本补丁

CPH2653 在本轮 14:23–14:24 UTC 的脱敏日志确认：新版官方 WebView 主认证、IDS 保存、E-Hall 业务验证均通过；随后 `grades.list`、`schedule.week`、`exam.list` 返回 ok。此记录证明相应查询成功，不将未记录参数的 schedule.week 日志扩展为已经单独验收“当前周”或真实原生补填表单。

校园卡通过 OAuth/账户请求后仍报 `card_balance_missing`，已不再停在卡号必填。0.12.1 为校本读取修正：沿用参考 PDA 实际 idsDio UA（不接入其密码协议）、openid 取认证页 hidden 字段而非中间 URL 参数，金额单元格接受明确的“元/（元）”和币种符号，仍严格整数分。新增失败 DOM/格式固定分类，不输出账号/openid/金额/页面正文；无法解析仍报失败，不返回占位金额。

0.12.1 两校包 SDK 仍为 3，宿主/输入 API/权限和客户端 0.3.0+6 不变。学校 Node **122/122**、实际打包源码真实 QuickJS **22/22**、学校确定性打包/PII smoke 通过；最终 APK 内源码/README/MPL 与工作区一致，已再次覆盖更新 CPH2653，并同步 Download/elecon-scripts/0.12.1 的两个 JSON、README 和许可证。移除未使用 URL 取值函数，避免继续暗示可从中间参数推断 openid。

最初手机锁屏时保留未验收状态；随后本轮 14:33–14:34 UTC 脱敏日志已确认 0.12.1：`calendar.academic ok`、`card.transactions ok`、`schedule.week ok`、`exam.list ok`，余额最终 `xidian_card_stage:account_ready → card.balance ok`。表明本轮本科手机的校历/课表/考试、账户余额/流水查询成功；不能扩展为研究生、Apple 平台或所有学校响应形态都已实测，也不以缺少参数的日志宣称具体教学周或实际密码输入已单独验收。

没有代点源码安装授权或覆盖旧 digest，没有读取/输出手机凭据、真实金额或响应正文。最终检查日志为 `/tmp/elecon-input-*-patch.log`，脱敏手机日志为 `/tmp/elecon-input-device.log`；人工核心安全审阅仍开放。


## 2026-11-01：Profiles、扫码 SDK 8 与保护研究

- [ADR-044](../adr/adr_044_local_profiles.md) 已实现本地 Profiles：旧库原位归属 Profile 1；新用户独立会话、凭据/业务缓存与安装授权，重新选择脚本。切换取消旧调用并重建导航，设置逐 Profile 展示脚本/状态和保护图标。
- [ADR-045](../adr/adr_045_script_qr_scanner.md) 已实现可选 `scanner` 权限和 `ctx.ui.scanQRCode()`；前台 Android/iOS 相机返回 QR 文本/null，后台与 action 拒绝。现有学校包未提升 SDK；没有新增签到提交能力。
- [保护研究](../research/script_protection_feasibility.md) 已核对 flutter_qjs_next 1.2.1 本地原生源与官方资料：可 fork QuickJS 或对少数纯函数做 VM 保护；当前未实现加密包、引擎补丁或 VMP。格式/授权变化须另立 ADR。
- 自动验证：session、scripts、启动、凭据 UI 边界、网格/拖动/真实首页与 l10n 共 **417 项通过**；Flutter analyze 无问题；TS schema 共享扫码准入 **22 项**、打包 smoke、tools typecheck/Biome、54 个 schema 生成物检查及契约 CHANGELOG 门通过。生成器仍提示既有 27 处 description 缺失，本轮未扩修历史字段。
- 构建与文档：当前代码 Android Debug APK 构建成功；主/Apple lockfile 均锁定 mobile_scanner 7.4.3，Apple 依赖单独 `--enforce-lockfile` 解析通过；本地文档链接及 iOS 相机用途资源静态检查通过。Linux 未编译 iOS。首页向上重力的行为修订和验证见 ADR-043 §2.3。
- 剩余验收：相机真机、Profile 切换时原生认证/硬件密钥生命周期及核心/权限人工实质审阅。自动测试、APK 构建和研究结论不替代这些签收，也不代表真实学校签到已可用。


## 2026-11-01：课表、消费图、空教室与教师查询

本轮按所有者要求完成并分步提交，客户端基线升为 `0.6.0+9`，两套西电脚本升为 `0.17.0`（本科 SDK 5、研究生 SDK 4）。新增脚本版本仍须在安装界面检查完整源码、学校身份、官网网络范围及 digest 后确认，未改写手机旧授权。

- [ADR-048](../adr/adr_048_schedule_navigation_and_segments.md)：学校时间分段与周预览采用 `schedule.week` 1.1；保留 1.0 精确校验。客户端提供带预览的周按钮、左右切周、满宽七日布局和重叠提示/完整详情；修复非周一起始日期与过期请求回写。
- 一卡通消费图复用 ADR-047 和标准流水，在核心按币种计算商户分布/每日变化，支持近 7/30/90 天与显式更多分页；排除充值/退款/未完成交易，无可统计消费不显示图，分页未完整时明确说明。
- 空教室通过授权 ADB 真机取得并核实 36 个公共教学楼条目，目录已内置学校脚本，不再为列表登录/获取。修复选择楼栋后被旧缓存选项覆盖；真机已确认选择 A 楼保持且取得该楼 66 间教室。仅记录字段形态的临时探针分别核对周日/周一查询，证实 `JC1–JC11` 存在且空值为显式 null，正常教学日同时返回占用与无占用前缀，按 PDA 的既有占用约定修复解析；缺键继续未知。探针与临时构建配置已从源码移除，不保存原始响应/凭据/设备标识。
- [ADR-050](../adr/adr_050_faculty_search.md)：官网公开教师查询按姓名关键词/研究方向单页请求，同名保持来源 ID，保留分页、简介与可复制主页。公开研究预算与证据见[教师查询研究](../research/xidian_faculty.md)，不读取凭据，不预加载或持久缓存检索。

验证：相关组合 Flutter 100 项通过，后补复制链接/空教室真实缓存链组合 10 项通过；最终实际包真实 QuickJS 26 项与学校 155 项 Node 夹具通过。Dart/TS 共享课表版本化 golden、V1 validator、学校确定性打包/PII smoke、tools typecheck、Flutter analyze、相关 Biome、文档链接及 CHANGELOG 门通过。Android ARM64 Release 构建及覆盖安装完成；未执行 iOS 构建。

上述手机结果来自其当时已授权旧脚本及新版客户端；新版源码的学校端到端验收须在用户确认新 digest 后继续，不能把合成回归或字段形态观察宣称为教室现场空置、教师真机查询或人工安全签收。核心/网络/契约人工审阅、研究生和其他平台仍开放；未推送、合并或发布。

## 瑞思与学习通增强（2026-11-01，ADR-052）

- 基本包 0.18.0：`forum.session` 独立瑞思账号，表单 MD5 协议与验证码原站回退；仅在当前用户 UID 核验后存 Cookie，BSD 来源许可随包。
- 增强包 0.1.0：分别绑定本科/研究生，学习通原站登录、`messages.list` 当前群消息窗口和 `attendance.checkin` 受限 QR；独立安装，默认基本包不授予相机/消息网络。
- SDK 9：单独声明 wss origins，有界二进制通道、固定 DNS/TLS、禁止跳转/压缩/自动重连；退出/更新/切身份/后台/离页关闭。新能力禁止 home/cache/background。
- 主壳依据可执行 provider 显示论坛/消息 Tab，按稳定身份保持当前导航。消息和账号由同一包处理，页面离开清除敏感内容。

自动验证包括实际模块及编译包、真实 QuickJS、合成 TLS/帧限制/取消、动态导航及既有脚本回归；详细支持范围见[增强包](../../school-scripts/xidian-chaoxing/README.md)。未访问真实学校/服务、未提交真实签到；协议在线兼容、原生平台及人工安全审阅仍开放。

## 2026-11-02：课表绑定恢复、独立账号与手动社区包（ADR-053）

- 手机只读安装元数据确认旧 v2 课表绑定仍为 1.0，而已批准的学校包已声明 1.1；恢复注册表后，实际首页重新出现今日课程，课表查询成功。registry v3 在已批准基础包更新时同步能力版本，兼容修复旧绑定，保留覆盖选择、禁用状态及批准 digest。
- 服务页只取消自身调用；睿思失败/取消后学校凭据、课表缓存和排队查询保留。全局身份/来源变更仍取消全部任务。无可执行来源时对应 Tab 继续隐藏。
- 学习通移出应用资产、内置导入按钮和推荐文案，作为第三方社区包由用户自行导入；只在测试目录保留实际编译夹具。
- 学校 0.18.1 排除旧会话中的公共后缀 Cookie；设备复现的 Android cookie write rejection 已定位于这类 Cookie。学校与社区网页登录暂态跳转现在在脚本侧等待，避免瞬间耗尽重试。社区包版本 0.1.1。网络授权、学校身份、TLS 与原站认证条件不变。

验证：学校 165 项 Node 合成测试、社区 17 项合成测试、两种确定性打包 smoke、tools typecheck、相关 Biome 与 Flutter analyze 通过。脚本/导航/基础 widget 回归及新增旧绑定、单次取消、实际编译包 QuickJS Cookie 回归通过；新增周缓存隔离断言保留原始取得时间。设备仅做授权调试，未清空应用数据或直接修改安装授权，用户已确认学校 0.18.1 和社区 0.1.1。真实学校登录完成、学习通签到与核心人工实质审阅不以这些自动回归代替；后续排查另记。


## 2026-11-02：整学期课表缓存（ADR-054）

学校基本包 0.19.0 以 `schedule.week` 1.2 同次返回整学期各周详情。详情页新鲜期内切周直接读本地缓存，过期发起一个非交互刷新，旧网格与周选择仍可用；离线失败保留旧数据，晚到结果不回退用户选周。投影不改变原始取得时间与保留期限，首页无参查询仍独立；未枚举周或额外筛选不推断命中，旧 1.0/1.1 继续支持。

验证包括整学期空周/调课解析、真实编译包 QuickJS、缓存时效和 digest 隔离、切周零请求/到期单次刷新/离线继续切周及共享 schema 版本 golden。新包仍须用户通过正常安装确认，自动回归不代表更新后的设备与人工核心验收。


## 2026-11-02：签到定位矩阵与诊断（ADR-055）

- 第三方学习通社区包 0.2.0 使用 `attendance.checkin` 1.1，保留 1.0 输出/空参数快照和版本化工具校验。提交补齐来源页及异步请求头，位置由用户明确选择后传入；两次活动要求检查、至多一次 POST、独立状态确认和未知结果保留继续有效。人脸/照片/验证码、未知要求、位置未接受和 QR 过期以固定原因表达，不回显原始响应。
- 原生消息页提供最多 16 个地点按钮，支持添加、编辑和删除；默认不选位置，坐标由用户从服务地点数据取得。宿主保留地址按 Profile/学校/来源使用已有 H/S/M 后端，UI 只有地点窄接口，不可经脚本凭据枚举/寻址，不计为学校登录状态。没有搬入 GPL 坐标表或增加依赖。
- 验证：社区 25 项 Node 合成协议测试、实际编译包 QuickJS（含定位提交/请求头/状态核验）、地点存储隔离/重启、zh/en 深浅色窄屏 2× 字体/增改删及旧包参数回归通过。受影响 scripts/导航/widget 399 项、session/凭据 UI 边界 22 项通过；Flutter analyze、tools typecheck、确定性打包、65 schema/63 registry 引用 golden、版本兼容与 V1 validator smoke、codegen 同步通过。补全了早期新增能力遗漏的全量 schema golden 样例，而非删除数量/覆盖断言。
- Android ARM64 Debug 和 Release 构建完成，APK 仅含两套学校基本包，社区产物单独提供。指定手机已覆盖安装调试客户端并放入社区包，随后覆盖安装同版 Release；保留原数据，未直接改写批准 digest。只读注册表截至本记录仍是学校 0.18.1 / 社区 0.1.1，新学校 0.19.0 和社区 0.2.0 需正常内容确认后才能继续真机验证。没有发送真实签到；真实活动及人工核心/网络审阅仍待完成。

## 2026-11-02：课表体验、首页签到与阶段探针（ADR-056/057）

- 课表沿用脚本校历的本周字段，首次与再次打开优先默认当前周缓存；周条居中并标记本周，切周显示方向动画，右上角图标刷新。修复最近历史周缓存抢占和背景校历响应迟到后的刷新锁问题。首页更新时效显示刚刚/分钟/小时，严格超过三天才显示本地日期，缓存时间与 TTL 不变。
- [ADR-056](../adr/adr_056_foreground_request_cards.md) 的通用前台请求组件承载主页签到入口；同包显式登录、地点选择与脚本扫码，无预加载、自动重发或协议下沉。返回、后台、来源失效时取消并清除临时状态，扫码子路由不误取消。
- [ADR-057](../adr/adr_057_bounded_script_probes.md) 的通用日志校验让正式版可筛选/复制有界阶段记录。社区包 0.2.1 增加 14 阶段探针，本科/研究生可导入包由源码生成，未放入客户端资产；只有固定阶段、事件、HTTP 状态、耗时和条件位，没有二维码、账号标识、凭据、位置或源站正文。
- 验证：课表及首页缓存 27 项、相对时间/日志 31 项、前台卡片 6 项及关联页面回归通过；社区模块 32 项、打包 smoke 和真实 QuickJS 5 项通过，Flutter analyze 无问题。实际学校失败仍需安装新客户端与社区包后现场复现并采集探针；本轮未操作真实账号/活动、未部署或完成真机与人工安全签收。

## 2026-11-02：通用签到输入、缺配语义与缓存优先桌面（ADR-058–060）

- SDK 10 补齐前台拍照、选图和当前位置，显式 `deviceInputs` 授权随 digest 检查；原生输入只返回有界 PNG 或 WGS84 位置，脚本自有上传协议使用有界二进制 body。标准签到模板覆盖按钮、扫码、照片、本人图片、位置编排，未适配真实源站前拒绝提交；学习通未核实的照片/人脸协议仍明确不支持。通用签到入口使用中性文案，消息 Tab 移除签到控件。
- 查询卡片整卡点击进入详情，右上角刷新图标替代查看/重新查询文字。公告无预加载与 V1 路径仍能首帧后读取、单卡和整体刷新；晚到结果和切身份不会转为新身份请求。
- 新增通用 `configuration_required`，H/S/M 中的标记按 Profile/学校/来源 digest/能力/参数隔离，自动和整体强制刷新跳过；明确配置成功才恢复。西电包 0.20.0 未绑定空调时不弹表单、不发请求；已绑定请求失败保持失败语义。持久化失败恢复缺配标记和原成功缓存，不回滚可能已被学校轮转的凭据。
- 当前 Profile、本地授权脚本、受保护业务缓存和桌面布局先恢复；首张桌面显示后才启动背景查询。其他 Profile 延迟初始化，界面显示「切换后查看」。布局增加进程缓存、写入等待和临时读失败重试，私密内容不进入明文布局。
- 学习通 0.2.1 修复标准签到 QR 的 `STRATEGY_PARA` 参数误拒；仅提取已校验 id/enc，继续固定端点和单次提交。用户提供的过期样例在设备外私有临时目录离线解码和解析通过，真实值未进入仓库、日志或合成夹具，未发送真实签到。
- 自动验证：101 项相关 UI 回归；70 项本地恢复、Profile、来源/缓存、配置、页面接线回归；设备输入 33 项、标准模板 7 项、社区模块 33 项及编译包 QuickJS 5 项；西电确定性打包/模块与实际包 QuickJS、网络传输/旧 SDK 负例通过。补测布局读失败/保存竞态、保存失败缓存回滚和无预加载全局通知刷新；分析和 codegen 同步检查完成，旧 schema 缺 description 基线警告未作为本轮新增问题。自动验证不替代原生设备输入、真实学校和人工核心审阅。
- Android Release 0.7.0+10 已构建，经逐字节核对 APK 内两校 0.20.0 资产后，通过 `adb install -r` 覆盖更新连接设备；保留应用数据，包元数据确认版本。两校包及许可证在 `Download/elecon-scripts/0.20.0/`，社区包及许可证在 `Download/elecon-scripts/chaoxing-0.2.1/`。设备仍锁屏，本轮未操作应用内脚本更新授权、拍照/定位或真实学校登录。图书实际被拒目标尚未采到，未猜测扩大白名单；正式版已增加仅 origin 的拒绝导航网络诊断，待解锁后继续。未推送、合并或公开发布。

### 同日解锁后续验收：图书认证入口与页面复测

- 在用户已授权自动安装与调试的范围内，通过应用内内容确认流程先安装本科基本包 0.20.0 和学习通增强包 0.2.1，未直接修改安装注册表或授权 digest。
- 图书刷新复现 `NAVIGATE https://i.chaoxing.com → browser_navigation_blocked`。公开入口检查发现超星官方 `/auth/xidian/cas/init` 会先初始化登录状态，再发起 IDS `/cas/index` 回调；原脚本直接把 init 当作 IDS service，跳过该初始化。0.20.1 改为直接打开官方 init，保持既有网络范围。经应用内更新后，本科真机到达 `https://mfindxidian.libsp.cn`，借阅查询正常完成并显示更新时间，原异常未再出现。研究生与其它平台未测。
- 真机确认课表首次打开将脚本提供的本周居中，横滑能切换周次；首页显示相对更新时间、图标刷新和空调「未完善信息」。冷启动后恢复已有桌面与课表缓存。消息页已无签到控件，另删除中英文说明中的旧签到句。
- 学习通真机完成已有登录态检查、打开扫码器和取消；正式版记录对应 begin/ok/skipped 阶段，未执行签到提交。过期样例仅作离线解码和解析验证，不作为有效活动签到成功的证据。拍照、选图和定位的原生交互、有效活动及人工核心审阅仍开放。
- 新增官方图书入口、CAS 中间页不保存会话、拒绝跳转不覆盖旧会话的合成回归；学校 smoke 169 项与编译包真实 QuickJS 27 项通过，消息页回归通过。原始截图与二维码只保留在私有临时目录，未进入仓库或夹具。
- 收紧设备输入测试：改用真实本机 HTTP，以前台实际 POST 作为后台取消零请求的正例对照；图片桥接覆盖 512 KiB 上限，相关文件 32 项回归与定向分析通过。未改变已触发非交互查询的后台执行语义。
- 最终 Release 0.7.0+10 重新构建并覆盖安装成功；逐字节核对 APK 仅含两校 0.20.1 基本包及对应说明/许可证，社区包仍单独安装。真机确认消息页旧签到说明已消失。0.20.1 源码包与许可证同步至 `Download/elecon-scripts/0.20.1/`。改动分步不签名提交，未推送、合并或公开发布。
