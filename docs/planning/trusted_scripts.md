# 受信学校脚本实施记录

依据：ADR-034 / ADR-035。独立分支 feat/trusted-school-scripts，基线 a60db9f；原工作区已有登录代码修改未纳入，已验签 bundle 字节的只读复用见下文。

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

新工作树 /home/nancunchild/projects/elecon-trusted-scripts；原工作区保持原分支及 22 个文件的已有修改（450 additions / 43 deletions），未混入其登录代码。

## 复核：Masker、多凭据与版本（2026-10-29）

本次检查发现并修复了同校脚本默认键碰撞、隐式旧 ref 覆盖、更新丢失元数据、失败结束缺耐久屏障、设置切校误清全部学校凭据、SameSite 丢失、模板根路径采集遗漏、CLI/安装器已知语义差异，以及 Apple manifest 缺文件导入依赖的问题。

- [x] ADR-035 先行：`c8a8ed0`；SDK 2 的 `(schoolId, namespace, key)` 描述符、显式共享/旧数据访问、保存行为有据。
- [x] 核心与客户端：`7ae7d6d`；完整 id/namespace/key 可往返、默认脚本命名空间、SDK 1 原寻址兼容、失败保存与稳定存储错误、有效过期元数据、切校保留、SameSite 接线。
- [x] 工具与模板：`34531fa`；SDK 2 / 脚本版本 0.2.0，Cookie 按业务 URL 分组保存，不按 name 折叠；CLI 拒绝已知非法端口/CIDR/重复 origin/capability 等，实际模板通过 fake ctx 回归。
- [x] 文档同步：AGENTS、规则、相关旧 ADR 的适用范围、ADR 索引、术语、架构、契约与使用说明已更新；[Masker 审计](../reference/masker_retirement_audit.md) 明确仍在执行的旧链及退役条件。

最终复核结果：Flutter 全量 **1029 通过、11 条件跳过**；主清单与 Apple 清单 analyze 无问题；workspace lint/typecheck、tools smoke **23/23** 通过。Android 与 Linux debug 重新编译通过。Apple manifest/lock 补齐 file_picker，已验证 enforce-lockfile 和静态分析；保留原有 Apple 依赖 pin，没有据此声称 iOS/macOS 构建或真机已验收。对应日志位于 `/tmp/elecon-credential-audit-*`。

契约 ADR changelog 门、旧 adapter validate 与 bootstrap 自洽检查通过。旧签名资产未改，未执行签名私钥操作，也未改变历史人工签收状态。

**仍未完成的迁移**：Masker 没有全仓清除，V1 客户端/TS runtime/发行工具/契约/签名历史仍保留；SDK 1 默认学校共享键与旧 raw-ref 索引仍仅作兼容。SDK 2 的独立描述符不等于对整个旧 store 做了多校重构。同校多账号并存仍未提供；每校多个系统/多份凭据已在新路线回归。Android 缺少 Cookie 元数据的平台无法无损恢复完整 jar，真实学校、原生设备与人工审阅仍开放。
