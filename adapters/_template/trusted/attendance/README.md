# 通用签到源码模板（SDK 11）

这是可打包、可回归的开发模板，默认 `configured:false`，直接运行返回 `configuration_required`，不会访问示例站点或报告假成功。它不绑定学习通，也不实现或替代任何服务的人脸活体流程。

实现真实学校时，先核实该服务的活动要求、账号、上传和只读核验接口，再替换 `configuration.origin`、认证及响应解析。模板中的 `.invalid` 域名不可真实提交；`configured:true` 只用于合成测试或完成实际适配后的源码。同步修改 manifest 的学校、网络范围、包版本和实际需要的 deviceInputs，再重新确认 digest。

客户端“开始签到”仅触发一次能力调用。模板菜单演示按钮、QR、拍照、用户选取本人图片和当前定位；真实学校脚本应从已核实的活动要求决定输入，并在提交前验证其 QR 的固定 host/path/字段。采集照片或用户选取的人脸图片不意味着身份或活体已验证，不生成模拟证明。

图片经宿主重编码为 PNG，`bytes` 是最大 512KiB 的 Uint8Array，无文件名、路径或原 EXIF。`multipart()` 把它与有限字段组装成最大 1MiB 二进制请求。位置是 WGS84 当前观测，带 accuracyMeters/capturedAt；服务坐标转换由脚本明确实施，不能把保存地点或随机数当 GPS。

示例至多一次 POST，然后一次只读状态核验。丢失响应、核验失败或未知字段返回 unknown，不自动重发；只有明确匹配 requestId 的状态结果能显示 confirmed。输入取消返回 cancelled，账户缺失返回 authentication_required，配置缺失返回 configuration_required。

在仓库根目录打包：

```sh
npm -w tools run scripts:package -- --manifest adapters/_template/trusted/attendance/manifest.json --source adapters/_template/trusted/attendance/index.js --out /tmp/attendance-template.elecon.json
node --test adapters/_template/trusted/attendance/template.test.mjs
```

所有测试使用合成输入与假的 fetch；不会请求学校、读取设备相机或操作真实签到。

SDK 11 账号声明目前为 `accounts:[]`，因为此未配置模板没有认证实现。适配真实服务时必须同步声明实际所需账号、登录说明及可选的同包登录绑定，不能把此空声明带入需要认证的生产脚本。
