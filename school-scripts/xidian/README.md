# 西电 SDK 2 脚本

版本：数据包 `school-xidian@0.6.0`，登录包 `school-xidian-login@0.1.0`；客户端本地构建基线 `0.2.1+3` 包含长字符串跨桥修复（SDK 2 不变）。参考本机 `traintime_pda` 的 `e780e4d01ea740c979ff5c31b9db439dbc586864`（2026-10-14）。这是对该提交的协议与字段适配，未声称已经用真实学校账号或原生设备验收。

旧西电源码还在 `adapters.pin` 指向的外部仓，签名包仍在 bootstrap。本目录更新的是新的受信脚本路径，不修改缓存、外部仓 pin 或签名内字节。导入数据包后，客户端优先用它提供的同名能力，旧路径只作为未覆盖能力的兼容入口。

## 构建与导入

在仓库根目录执行：

```sh
npm ci
npm run scripts:xidian -w tools
```

生成：

- `dist/school-xidian.elecon.json`：HTTP 数据包，SDK 2、11 个现有标准能力。
- `dist/school-xidian-login.elecon.json`：可见浏览器登录包，SDK 2、`generic.section` 登录工作流。

也可传 `-- --out-dir /tmp/xidian-scripts`。构建器先编译、校验两个包，不执行学校代码、不签名。所有本地模块合并成一个 ESM，`elecon:html` 保留为宿主内置模块。输出保留 MPL 版权和来源说明。安装时仍须分别查看源码、域名和权限并确认。

数据与登录分包：公开通知、已有会话查询不要求打开 WebView；登录包只在需要认证时由用户运行。数据包也能在 Linux/Windows 使用；当前可见浏览器桥只支持 Android/iOS/macOS。

## 首次使用

1. 在选校页或设置中的“学校脚本”导入两个包，切换到西电。
2. 运行登录包的 `generic.section`，传入所需系统和自己的学号（学号只保存在当前学校的会话内，不放进运行结果）：

   ```json
   {"system":"ehall","studentId":"你的真实学号"}
   ```

   `system` 支持 `ehall`（本科教务）、`yjspt`（研究生）、`card`、`library`。密码、滑块、短信或企业微信二次认证在学校自己的可见页面完成。完成一套登录后，IDS Cookie 可用于其它目标的 SSO，但服务票据始终按目标重新取得，不复用一次性 ST。
3. 返回数据包运行能力，例如课表 `{"week":3}`，成绩/考试 `{"term":"2026-2027-1"}`。成功登录本科/研究生时记住所选角色；也可显式传 `role:"undergraduate"` 或 `role:"postgraduate"`。学号优先使用显式参数或对应业务会话，不从旧的另一角色会话猜测。
4. 校园卡先登录 `card`。若账户页没有明确卡号，首次在 `card.balance` 或 `card.transactions` 参数中提供真实 `cardNumber`，成功后会保存在该系统会话中。不能用学号、openid 或占位值替代卡号。
5. 新图书馆登录 `library`；数据包从实际登录 URL/Cookie 取得的 JWT 和 groupCode 查询借阅。没有借阅的有效响应返回空列表，认证失败或分页不完整会报错。

每校仍只有一个当前账号身份；更换账号请先登出，避免把两个账号的业务会话混在一起。切校保留凭据，登出清除当前学校所有命名空间。这里不提供真实账号数据、默认密码或真实 openid。

## 能力范围

| 能力 | 本轮行为 | 保留的限制 |
|---|---|---|
| `notice.list` | 主动获取教务处 HTML，使用内置 HTML parser | 仅首页，未伪造更多分页 |
| `schedule.week` | 本科 `SKZC` / 研究生 `ZCBH` 位图；本科调停补课、部分节次变更；实际校历日期 | 未排课程没有周时段，暂不塞进周课表 |
| `grades.list` | 本科/研究生独立字段与等级成绩、0 分、重修来源；有界完整分页；按学期过滤 | 不猜 GPA/绩点换算；构成明细未建模 |
| `exam.list` | 本科安排及待安排、研究生发布过滤；中国墙钟转 UTC | 当前 schema 无结束时刻；待安排保持未知状态 |
| `classroom.buildings` / `classroom.available` | 楼宇发现、日期或周/星期、节次/时间窗口；缺节次保持未知 | 两种角色都查询 E-Hall 公共教室应用，需相应会话 |
| `card.balance` | 明确余额标签及参考仓见证的首个 li 元素布局；精确整数分 | 现有 schema 强制卡号；源未给出时需用户提供，否则 `card_number_required` |
| `card.transactions` | JSON `beginDate/endDate/tradeType/openid`、日期数组、本地分页；收入/支出与特殊类型 | 默认中国当地近 30 天；不把本地分页冒充服务端分页 |
| `library.loans` | 超星 CAS → 新 OPAC，JWT header/cookies、预热、groupCode、实际借阅字段和有界分页 | 不迁入旧 shuwo/openId 链，不自动续借，不为每本书扇出封面请求 |
| `term.list` | 返回来源明确提供的当前学期 | 未证实历史列表接口，不声称列全历史 |
| `calendar.academic` | 本科开始日期 / 研究生 `QSRQ` | 不猜结束日期、假期与教学周总数 |

参数继续使用既有标准字段；`role`、`studentId`、`cardNumber` 是该学校的可选配置。查询 `schedule.week` 必须指定 `week`；空教室需楼名/楼号及日期或周/星期。学校业务错误通过工作台的脱敏日志可见，顶层宿主失败码仍由 SDK 统一归一化。

## 会话与网络

两个包显式共享 `xidian.auth` 命名空间，键为 `ids`、`ehall`、`yjspt`、`card`、`library`。每条是有版本的 JSON 会话：`{version:1,service,cookies,data,updatedAt}`；其中 `data` 保存真实来源的 openid/JWT/groupCode、明确提供的学号或卡号等。SDK 2 的完整凭据地址仍是学校、namespace、key，不因脚本升版改变。

普通 JS 自行管理 Cookie、逐跳 HTTP 重定向和认证中间值。新 Cookie 在解析业务结果前保存；同名 Cookie 按 domain/path 区分；已知同一完整地址最后一条生效。校园卡 openid 按参考行为保留五分钟，查询认证失败最多刷新重试一次，不重试取消或输入错误。

Android 未提供 Cookie 属性时，快照只能绑定到采集的业务 URL。登录逐个真实 API 路径采样，空快照清除该路径已删除的旧值；服务器返回明确属性后会替换对应未知范围样本，避免旧值压过轮换值。这不能恢复平台根本未导出的完整 Cookie 库；同名 Cookie 真实路径不明时仍可能需要重新登录。

所有 origin 在 manifest 中精确声明。没有通配域名、公共代理、TLS 证书绕过或绕过登录的接口；HTTP 当前最多 20 次请求、含所有跳转，分页均有上限，达到上限明确报错而非返回截断结果。

## 额外能力是否必要

本轮不需要新增宿主权限、认证 DSL、Masker、加密原语或 capability id。实际需求与后续建议见 [能力差异评估](../../docs/reference/xidian_script_update.md)。需要区分宿主 API、业务输出契约，以及平台/网络条件：卡号约束是契约缺口；长时间 MFA、可恢复浏览器身份是可选宿主改进；校园网可达性不是给脚本增加一个函数就能解决。

## 来源与许可

本目录 JS 与测试以 **MPL-2.0** 分发，完整文本见 [LICENSE](LICENSE)。教务、登录、校园卡、图书馆模块按下列参考源码的协议/字段适配并保留版权，未把 MPL 文件当作根仓库 MIT 代码重新授权：

- `traintime_pda/lib/repository/ids_session/` 下的 `ids_session.dart`、`classtable_session.dart`、`score_session.dart`、`exam_session.dart`、`semester_session.dart`、`empty_classroom_session.dart`、`school_card_session.dart`、`library_session.dart`。
- 相关 `lib/model/xidian_ids/` 及 `lib/model/time_list.dart`。参考滑块求解文件虽单独为 MIT，本轮不复制求解器，官方页面处理验证。

没有修改参考仓、读取其用户配置或复制学生数据。没有新增第三方依赖；构建复用 tools 已声明的 esbuild（MIT），HTML 解析复用已有 SDK stdlib。分发生成包时应同时保留源码获取方式、MPL 许可证和本说明，不能删除 bundle 内的版权说明。

## 验证

```sh
node --test school-scripts/xidian/tests/*.test.mjs
npx tsx tools/src/script/xidian.smoke.ts
cd client
flutter test --no-pub test/scripts/xidian_script_test.dart
```

Flutter 集成测试会用 Node 工作区重新构建实际包，在真实 QuickJS 中执行并校验标准输出；先在仓库根执行 `npm ci`。测试全部使用合成响应和凭据，不请求学校，不等于真实账号或原生设备验收。
