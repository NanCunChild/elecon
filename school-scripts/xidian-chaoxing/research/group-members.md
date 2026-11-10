# 学习通群成员、显示名与头像研究 · 2026-11-10

研究只取协议事实，学校适配在脚本中实现。核心仍只处理标准会话与稀疏补全，不识别学习通成员角色或占位名称。没有新增依赖、网络来源或原生 SDK。

## 官方接口与独立实现

[Web 群组文档](https://doc.easemob.com/v4/web/group_manage.html)说明 4.15 起所有群成员可使用 getGroupMembers；[API 类型](https://doc.easemob.com/apidoc/web/modules/Group.html)给出 cursor/limit 及角色结构。另核对官方 npm 分发的 easemob-websdk 4.12.0、4.24.1，两个包声明 ISC。仅静态分析请求路径、参数和响应转换，没有执行、复制、翻译或引入 SDK 实现。

| 接口 | 已核实事实 |
|---|---|
| getGroupInfo | 两版本均为 `GET /{org}/{app}/chatgroups/{ids}?joined_time=true`，没有 sdk 前缀；当前脚本原路径正确 |
| getGroupMembers（4.24.1） | `GET /chatgroups/{id}/users`，传 cursor/limit/joined_time=true；原始根级 data 为数组，根级 cursor 表示续页 |
| 原始成员 | 每项为 owner/admin/member 角色键之一及 joined_time；SDK再转为 role/userId/joinedTime，不应将转换后包装当成 HTTP 原始响应 |
| 旧 listGroupMembers | 4.12 使用 pagenum/pagesize；4.24 保留旧接口并加 version=v3，不能混同于新 cursor/limit 接口 |
| getGroupAdmin（4.24.1） | `/chatgroups/{id}/admin?version=v3`；本次成员采样不再额外调用它 |
| sdk 前缀 | 个人禁言查询使用 sdk/chatgroups 路径，不用于普通群详情或成员取样 |

学习通资料字段另沿用已有本地研究：表单 POST getUsers4C，puid 为当前学习通 puid，tuids 为 IM tid 列表，puids 留空；响应为根级 result/data。uid、puid 不相互替代。既有本地反编译资料中的头像访问行为是优先 pic120，缺失时仅将已有 pic 的 psize 参数改为 120_120c。本项目独立实现 URL 参数替换，未复制反编译实现或 GPL 参考代码。

## 可复核的静态证据

### 联系人资料请求签名

原生调用 getUsers4C 时会添加普通 URL 签名。固定无初始查询的资料端点依次加入 `_c_0_`（随机UUID去连字符）、`token`（公开客户端协议常量）及 `_time`（Unix毫秒），按该顺序以 `key=value` 和 `&` 连接，末尾附加固定 `&DESKey=...`，MD5小写十六进制作为 `inf_enc`；表单字段不参加这一层签名。nonce不表示设备身份，不保存或重用；本实现只签固定资料端点和ASCII参数，不提供任意URL签名接口。通用原生编码是Java UTF-8 form编码再将空格改为%20；未来加入非ASCII或特殊字符查询时须另行遵守该编码，不能直接假设encodeURIComponent等价。

该协议由脚本[profile_request.js](../src/profile_request.js)独立实现，复用既有MD5原语。纯合成向量：nonce为32个0、时间1800000000000时，签名为 `dbba77999d61df93f41efe71daba9202`；使用 `0123456789ab4def8123456789abcdef` 时为 `624013f76485006c4e1995ceb1aaa6d1`。

静态语义来自已有学习通反编译文本的 getUsers4C、addTokenInterceptor 与 Keys 调用关系；没有复制或翻译方法代码。该树未记录原APK身份，不声称与另行核验的学在西电APK完全同版。公开协议常量在后者classes.dex中逐字核对：APK SHA-256 `325f45ceca0442d84a194984f3c782c8e67887627010cb33231109ea9f5bc44a`，classes.dex SHA-256 `87a7a9dd1834512673311c4b870af7491119fe76c37696b49895d687802b879c`；REA归档证据为 `ev_478b19ff42c5fb06e2835c7f9b39ecb47129351200fb009827cfc5916a47d850`。没有执行参考客户端、读取用户Cookie、主密钥或设备标识；缺少JADX MCP JAR使本轮REA不能重新反编译Java，此限制不冒充已完成的新反编译证据。

| 版本 | 官方 tarball | tarball SHA-256 | package/group/group.js SHA-256 |
|---|---|---|---|
| 4.12.0 | [npm](https://registry.npmjs.org/easemob-websdk/-/easemob-websdk-4.12.0.tgz) | `5df87d88971662410add81c6774d6559fb0e84dc7a657d5916ea2d966794aa97` | `c162c0ddaa0ee432576cdf91845196505302ece196f8def08d4f43083b4f2dee` |
| 4.24.1 | [npm](https://registry.npmjs.org/easemob-websdk/-/easemob-websdk-4.24.1.tgz) | `db162e1502066ea4088c2d3819bcc355cfae8d935aef81632c39a64479f2d3c0` | `54df208159fd9c7efb79529b1b585e2ac5b39d4203bfd312761a947a8d8bce7b` |

REA 静态 Evidence：4.12.0 为 `ev_a7800e604eb498bc52bc36c5015f3318ae44d5b4d00d4f86ca2016e1d2124ee3`，4.24.1 为 `ev_a18e29939022fe7c7a66728d43f09d1dd24c49acf1a8745f04def9d73c4166ac`。应用图仅部分覆盖；这些证据证明分发 SDK 的协议实现，不证明学习通服务配置或当前用户 token 权限。

### 头像入口与CDN

官方联系人、搜索及通知UI在pic/pic120为空而返回puid已知时，使用 `https://photo.chaoxing.com/p/{puid}_80`；这不是将IM uid/tid当puid。模型本身只有pic/pic120字段，不存在avatar别名。本轮实际成员资料已返回图片字段，未额外增加缺图时的puid派生请求。

公开无用户默认头像 `photo.chaoxing.com/p/0_80` 的一次无凭据GET观察到302及 `https://p.cldisk.com` Location；另一次无凭据CDN GET返回403/text/html，未重试或改头。官方APK的classes.dex同时含photo头像路径、120_120c与p.cldisk.com字面量。结合已授权设备多数图片302的探针，脚本0.7.5在manifest明确添加这一个HTTPS来源，按[ADR-098修正](../../../docs/adr/adr_098_conversation_avatars.md)手动验证并至多跟随一次。两个请求都无Cookie/IM token，不根据文件扩展名接受图片；实际CDN权限和图片结果仍由设备探针及原生显示验证。

## 真机验证范围

已通过用户授权连接的 ADB 设备，在当前已登录来源进行有限只读目录及补全。首轮阶段探针观察到群详情、成员及资料 HTTP 200，成员样本能解析出有效 ID，但资料data缺失、result不成功。加入普通请求签名后，原先显示数字ID的多个群实际显示由成员资料生成的名称；未将真实名称写入此文。图片探针确认多数入口302、部分CDN403，并取得了允许的PNG/JPEG字节。0.7.5的stage23出现 `11110???`，即大小、允许MIME及魔数均满足，但二者类型不对应；按实际字节归一data URI后，stage28图片装配及stage25稀疏图片输出成功，原生列表实际显示头像。剩余CDN拒绝与有限批次/额度未覆盖的会话仍显示默认图标。HTTP200、合成图片和部分可见成功均不等于全部真实头像验收。

官方Glide链显式额外添加Accept-Encoding:identity；已检查的图片fetcher没有固定Referer、额外图片签名或URL参数，图片客户端关闭addToken/addSign而使用OkHttp默认跳转。最终User-Agent由系统及客户端/设备内容生成，并非可照搬的固定字符串。本实现没有复制该UA或伪造设备身份，也未通过改头重试CDN403。

诊断只在本机环缓冲及临时文件中保留，不把实际群名、成员、账号、图片或设备标识写入仓库。合成测试、静态研究、真机可见结果与人工审阅分别记录，最终状态见[统一实施计划](../../../docs/planning/implementation.md)。
