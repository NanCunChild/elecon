# 西电学习通增强包

`0.1.0 / SDK 9`，分别绑定 `xidian_undergraduate` 和 `xidian_postgraduate`。提供学习通账号登录/本地退出、前台群消息接收窗口及扫码签到。安装授权、凭据、网络和取消边界见 [ADR-052](../../docs/adr/adr_052_community_accounts_and_chaoxing.md)。不覆盖基本包的教务登录和能力。

## 使用与支持范围

先使用包含 SDK 9 的客户端并选择相应本科/研究生学校，在“学校脚本”选择对应学校，点击“导入学习通增强包”，检查源码、HTTP/浏览器 origins、WebSocket origin 和相机权限后安装。也可构建后手动导入 `.elecon.json`：

```sh
npm run scripts:chaoxing -w tools
```

输出在本目录 `dist/`；`-- --out-dir client/assets/school-scripts` 可重建应用内置资产。基本包不静默安装增强包；卸载/禁用后，如无其他可执行消息来源，消息 Tab 消失。

消息页先通过学习通原站登录，脚本核验 UID/TID/FID 后仅保存该服务 Cookie。不会读取或尝试学校密码，不把学习通 UID 当作学号。账号记录在当前 Profile/学校的 `xidian.services` namespace、`chaoxing` key；namespace 不是同校脚本间的权限隔离。切换账号先本地退出；本地退出不代表服务端注销其他设备。

“获取消息”只接收一次最长 15 秒的当前群消息窗口，空闲 3 秒结束；最多 50 条，保留 uint64 消息 ID、群组、发送人和源站时间。没有历史补拉、私信、未读数、发消息或后台监听。协议 ACK 只用于服务队列接收，不发送用户已读操作。页面离开、应用后台、来源变化与身份变化会取消；正文不写持久缓存。

“扫码签到”登录后触发相机，严格接受固定超星扫码路径及活动 ID/enc。仅支持两次活动查询均明确不要求定位、人脸、照片或验证码的 QR 活动；未知要求保留为不支持。执行 analysis/preSign 后至多一次提交，再查状态；传输丢失不自动重发，无法核实时显示未知。协议客户端标识是脚本计算的字符串，不读取硬件标识或伪造当前位置。签到二维码不进入 params、日志或缓存；签退、定位/人脸活动与验证码续提不在本片范围。

## 来源、许可与验证

本地参考 `Quasar-core@96f36b38a2b01b810a2b45d66f0364183a4b7b87` 的端点、字段及 wire 编号（`chaoxing.go`、`im.go`、`types/im/proto/`、`util/deviceid.go`）。参考仓根许可证为 GPL-3.0。本包不复制或翻译 Go 实现，不链接其模块、不携带生成 protobuf 或地理坐标；以独立有界 JS 状态机与 wire codec 实现协议事实，复用本仓 MPL-2.0 Cookie/AES/MD5 模块。源码按 MPL-2.0 分发，保留 [LICENSE](LICENSE) 及本说明；没有新增外部依赖。

`npm test --prefix school-scripts/xidian-chaoxing` 仅运行合成夹具；tools smoke 检查确定性与内置资产同步，Flutter 测试运行实际编译包与真实 QuickJS。没有使用真实账号、提交真实签到或访问学校服务。参考源码及自动测试不能证明当前学校在线协议可用；仍需人工代码审阅、原生扫码/WebView/TLS 真机与受授权的实际账号验收。
