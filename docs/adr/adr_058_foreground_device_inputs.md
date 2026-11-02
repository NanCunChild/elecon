# ADR-058 前台签到模板与设备输入

- **Decision**：Accepted（2026-11-02，所有者要求通用签到模板支持按钮、二维码、照片、人脸图片及当前位置）。
- **Landing**：本轮实施 SDK 10、原生输入和通用模板；真机、真实学校协议及核心人工审阅另记。
- **范围**：承接 ADR-045/046/055/056。学校认证、活动规则、上传表单和签到协议仍由脚本负责。

## 权限与 API

SDK 10 增加可选 `manifest.deviceInputs`，最多三个不重复枚举 `camera`、`image`、`location`，缺省空。安装/更新页逐项显示，相同源码 digest 授权覆盖权限；SDK 1–9 拒绝此字段，旧宿主拒绝 SDK 10。现有 scanner 独立保留，不授予拍照或相册权限。

`ctx.ui.capturePhoto()`、`pickImage()`、`getCurrentPosition()` 无参数，分别要求上述权限，前台普通请求才可调用。取消返回 null；固定错误码区分未授权/不支持、权限拒绝、输入非法、忙碌、预算和取消。与输入表单/扫码互斥，设备输入每次运行最多 4 次，不自动重试。

图片返回 `{bytes:Uint8Array,mimeType:'image/png',width,height}`，最长边不超过 1280px、大小不超过 512KiB。宿主解码并重编码，移除原 EXIF、文件名和路径；原始读取最多 16MiB、像素最多 32MP，超限拒绝。图片只在本次运行内存中交付，系统相机/选择器返回给宿主的本应用临时副本在处理后删除；进程死亡后的选择结果不恢复到新脚本调用。系统选择器取消而未返回路径的临时文件由系统缓存机制清理；不能声称宿主可靠删除了插件未返回的文件，不扫描或广删整个缓存目录。普通人脸图片仅为用户现场采集或选取的输入，不表示身份已验证、活体检测成功或服务端验证通过。

位置返回 `{latitude,longitude,accuracyMeters,capturedAt,coordinateSystem:'wgs84'}`，十进制度、米及 UTC RFC3339。只取当前前台定位，不读历史位置、不后台追踪、不伪造或随机化，定位等待最多 20 秒；mock 平台位置拒绝，精度原样保留，服务坐标转换由脚本明确实施。既有 1.1 `location.coordinateSystem=service` 手填地点不是 GPS，不自动替代真实定位。

SDK 10 的 `ctx.fetch` 额外接受 `Uint8Array` body（最多 1MiB，沿用既有请求预算），允许脚本构造 multipart 或二进制上传。仅此类型的新语义版本化；旧 string body 不变。上传仍检查声明的网络范围、DNS/TLS、取消和重定向规则，不自动上传、重放或授予任意文件读取。

## 生命周期与模板

首页只展示通用入口，中性“开始签到”按钮触发一次脚本。脚本按活动要求请求 QR、拍照、用户选择图片或当前位置，固定宿主输入界面显示来源与用途；组件不绑定学习通协议，不用照片模拟其未实现的人脸验证。

系统相机/相册 Activity 会使 Flutter 暂停。只在宿主主动启动且有当前调用授权的系统图片输入期间持有最多 90 秒的输入 lease；此时不因暂停撤销自身输入，但同一运行禁止发起其他宿主调用。恢复前台、调用/学校/Profile/安装 digest 仍有效才交付结果，过期/取消/身份变化拒绝晚到结果。其他退后台仍沿用取消。位置请求不使用此例外。任何取消不证明先前网络副作用未发生，未知签到结果继续保留。

## 依赖、迁移与验证

使用 Flutter 官方 [image_picker](https://pub.dev/packages/image_picker) 1.2.4（[BSD-3-Clause，含上游 Apache-2.0 notices](https://pub.dev/packages/image_picker/license)）选择/拍摄图片；Baseflow [geolocator](https://pub.dev/packages/geolocator/versions/14.0.2) 14.0.2（[MIT](https://pub.dev/packages/geolocator/license)）前台定位。不新增后台定位、录音、照片全库读权限或原生侧载。Linux 传递依赖 geoclue 0.1.1 为 MPL-2.0、gsettings/dbus 为 MPL-2.0，未修改其源码；本轮设备输入不在 Linux 启用。Android/iOS 提供实现，其他平台明确 unavailable；没有把 Android 自动构建等同设备或 iOS 验收。

新脚本需提升 SDK/包版本、声明需要的输入并重新确认，不自动修改既有学校包。未核实的学习通 photo/face 上传与验证继续返回 unsupported。回滚拒绝 SDK 10 包，既有 SDK 1–9 行为保持；没有缓存图片/定位或恢复提交队列的数据迁移。

验证包括 TS/Dart manifest 一致、旧版本拒绝、权限/后台/并发/大小/类型负例、真实 QuickJS 图片与位置桥接、有界二进制上传、系统 picker lease、晚到结果、重编码去元数据、模板明确触发及中英文权限文案。

2026-11-02 实施验证：设备输入 SDK/原生页面 33 项 Flutter 回归通过，覆盖系统选择器取消或报错时仍在后台不得继续 HTTP、图片元数据移除和返回临时副本删除；相关 8 文件静态分析无问题。标准模板位于 `adapters/_template/trusted/attendance`，7 项 Node 合成测试与源码打包通过；未配置默认立即报 `configuration_required`，不发请求。此前 SDK/扫码/HTTP/主页前台卡片组合 82 项回归通过，TS 类型检查、共享 manifest 向量和 codegen 检查通过。以上为自动验证，不能代替 Android/iOS 真机、真实学校协议或人工核心审阅；完整依赖许可登记见 [依赖说明](../reference/trusted_scripts_dependencies.md)。
