# ADR-045 受信脚本前台二维码扫描

- **Decision**：Accepted（2026-11-01，所有者要求为扫码签到提供脚本调用接口）。
- **Landing**：SDK 8 首片已实现；相关 417 项自动回归与 Android Debug 构建通过，未实现具体学校签到协议。
- **安全签收**：待人工宿主权限审阅、Android/iOS 真机相机验收。

SDK 8 增加可选 `manifest.scanner: true|false`（缺省 false）与 `ctx.ui.scanQRCode(): Promise<{text:string,format:"qrCode"}|null>`。旧 SDK 1–7 不接受 scanner 字段；旧宿主拒绝 SDK 8。SDK 8 继承 SDK 7 字段含义。安装/更新确认明确显示相机扫描权限，随包 digest 授权。调用无参数，仅识别 QR 文本，仅接受平台提供的非空解码文本，超过 4096 UTF-8 字节的结果拒绝，不返回原始二进制、图像、文件或设备信息。不自动访问二维码 URL、不发起签到。

只在交互调用、应用前台、支持的平台及当前授权 Profile/学校/安装代际有效时打开宿主固定相机页。一次执行最多 3 次顺序扫描，不允许并发；取消返回 null，权限拒绝/无相机/不支持平台返回固定错误码，失效返回 invocation_cancelled。后台缓存预加载无权启动相机；ADR-046 已移除 action scope，普通前台能力沿用相同扫描授权。切换 Profile、切校、离页、更新、超时与进入后台均关闭扫描页并停止相机；异步返回再次检查授权。扫描内容进入秘密日志遮蔽集合，不写公共日志或自动持久化；受信脚本仍可按既有授权显式处理数据，宿主不承诺通用防泄漏。

使用精确版本 mobile_scanner 7.4.3（pub.dev，BSD-3-Clause；上游 https://github.com/juliansteenbakker/mobile_scanner）。Android 使用内置 ML Kit 扫描模型，避免首次扫描下载；iOS 使用 AVFoundation/Apple Vision。只启用 Android/iOS，其他平台固定 scanner_unavailable，后续平台适配单独验收。依赖不会为 JS 开放原生模块。新增 iOS 相机用途文本与 Android 相机权限；无相册读取接口。

本接口仅采集用户输入。真正提交签到是有副作用的业务操作，按 ADR-046 使用脚本通用请求；本轮不增加签到 capability/schema/action 或自动重试，不能把扫码成功当作签到成功。回滚可拒绝 SDK 8 包，旧 SDK 行为不变。

验证 manifest 双端一致、旧包兼容、权限未声明/后台/action 拒绝、真实 QuickJS 文本与 null 桥接、大小/次数/并发限制、取消/晚到结果/日志脱敏及页面相机生命周期。自动测试不等于平台真机验收。

2026-11-01 验证：共享准入夹具 22 项由 TS schema 与 Dart parser 双端消费；真实 QuickJS 覆盖 QR/null、次数/并发/大小、直接 host-fn 越权、旧 action scope 拒绝（现已由 ADR-046 废除）、后台拒绝、日志遮蔽、取消/超时与晚到结果。平台替身验证相机启动/停止、返回取消、权限拒绝和后台关闭；两套依赖 lockfile 解析验证及 Android Debug APK 构建通过。Linux 环境未编译 iOS，未执行相机真机或真实学校签到验收。
