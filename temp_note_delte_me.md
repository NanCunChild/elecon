总体判断
项目目前属于基础设施型 Alpha / 0.1 阶段：
- Adapter 契约、QuickJS 双端运行时、Broker、凭证存储、WebView 登录、签名分发、吊销、bootstrap 等基础链路已经基本形成。
- Xidian 公开通知已经产品闭环；课表、成绩、考试、空教室已有 adapter 和 fixture/smoke，但缺少完整 UI、真实账号持续验收和最新版正式签名发布。
- 目前还不能称为完整校园聚合产品，正式首页仍主要只消费 notice.list，见 client/lib/ui/home/campus_snapshot_loader.dart:1。
- 私密数据仍只能客户端直连；server/src/campus 目前只是 501 stub，不能依赖校内中继。
- Android 路径最成熟；iOS 首版按 ADR-010 仍是 declarative-only，imperative 能力上线前要重新做 App Store 合规评估，见 docs/adr/adr_010_ios_appstore.md:43。
还有明显的状态漂移：
- README.md:109 仍称只到 ADR-022，并把 OS keystore、签名分发列为待办，已经过时。
- 核心现在通过 adapters.pin 按 commit 拉取独立 elecon-adapters 仓库，不再使用子模块。
- 主仓旧 Xidian adapter 是 0.1.0，bootstrap 是已签名 0.3.0，外部仓开发态是 0.3.1。三种状态需要在文档和发布流程中明确区分。
- 当前工作树干净；本次为只读审阅，没有重跑全量构建和真机测试。
当前能力
能力	现在能否开始接入	现在能否称为可用
西电一卡通 openid	可以	不可以，ADR 已有但实现未落地
图书馆只读借阅	可以	不可以，Xidian 认证和 body 注入未闭环
完整图书馆	可以规划	不可以，需要新 mutation 契约和 ADR
物联网空调控制	可以规划和探针	不可直接上线，需要新的副作用能力模型
更智能的 imperative 凭证引用	可以	需分成 C8 bugfix 和独立 ADR 两步
OpenID
你确认的是西电一卡通 URL query 中的 openid。
它已经由 ADR-020 完整裁定：
- openid 是可重放凭证，不是普通业务参数。
- 只允许可信核心收割、保存和注入。
- Adapter 不得读取或自行拼接。
- Manifest 应声明 type: "query" 和 queryParam: "openid"。
- Broker 在每次请求和重定向中处理注入、收割和 URL 脱敏。
见 docs/adr/adr_020_url_query_credential.md:52-136。
但实现清单尚未完成：
- Manifest schema 目前仍只有 cookie | header。
- Validator 尚无 Q1–Q3。
- Dart/TS Broker 尚无 query harvest/inject。
- Xidian card-session 仍临时声明成 cookie。
见 docs/adr/adr_020_url_query_credential.md:195-203。
因此结论是：
可以立即进入实现阶段，不需要再开 ADR；但当前还不能宣称一卡通 OpenID 已接通。
该实现触碰契约和凭证核心，必须人工主导安全审查，不能只改 adapter。
完整图书馆
现有契约已经覆盖：
- library.loans
- library.seats
- library.booking
见 contract/capability/registry.json:23-26 和 contract/capability/registry.json:44-45。
只读借阅 schema 也已包含到期时间、续借次数、逾期和费用等字段。因此展示当前借阅本身不需要新 schema。
真正的阻塞是 Xidian 图书馆认证：
- 登录结果中的 token、userId 来自 HTML/JS body。
- 后续请求把它们注入 application/x-www-form-urlencoded body。
- 当前 Broker 只支持 cookie/header，ADR-023 的声明式注入目前也只支持 URL/header，不支持 form body。
- 让 imperative adapter 自己读取 token 再拼入 body 会直接违反“凭证永不离开核心”。
ADR-020 也明确排除了图书馆 form-body token，见 docs/adr/adr_020_url_query_credential.md:151-157。
“完整图书馆”建议拆成三层：
1. 只读能力：借阅、座位、预约状态，可复用现有 capability。
2. 写操作：续借、创建预约、取消预约，需要新增独立 mutation capability，不能塞进 library.loans。
3. 历史记录、馆藏检索等现有 registry 没有的领域，需要按真实接口另开契约 ADR。
首先需要一个聚焦的 body credential ADR，定义：
- 从响应 body 收割 token/userId。
- form-field 或受限 JSON 字段注入。
- 固定 method、固定 URL、固定字段名。
- Adapter 只能引用不透明句柄，不能读值。
- 日志、fixture 和错误信息脱敏。
- 写操作禁止自动重试，并提供明确用户确认。
物联网空调
底层 ctx.fetch 现在机械上可以发送带 method、headers、body 的 HTTPS 请求，因此官方 imperative adapter 确实“能够发包”。
但当前还不能直接把它暴露成空调控制，原因是现有体系主要按读取数据设计：
- Registry 没有空调或通用 actuator capability。
- 没有“必须由用户手势触发”的核心证明。
- 没有副作用请求的确认、幂等、防重放、禁止自动重试规则。
- Broker 当前会跟随重定向，307/308 可能重放 body。
- 没有固定 body 模板和用户参数绑定。
- 没有标准控制结果 schema。
- iOS 首版不允许 imperative。
建议不要设计成泛化的 url.send，而是：
climate.devices
climate.status
climate.command
climate.command 只接受有限业务参数，例如：
deviceId
powerOn / powerOff
temperature
mode
fan
固定 HTTPS URL 必须来自已签名 manifest，UI 不能传任意 URL。凭证、签名密钥、tokenized URL 只能由 Broker 注入。
专项 ADR 至少应规定：
- 只能由明确用户操作触发，禁止后台刷新或自动执行。
- 每次关键操作显示确认。
- 不自动重试；超时后显示“状态未知”，不能假定失败。
- 禁止跨 origin 重定向，MVP 最好完全禁止控制请求重定向。
- 精确 HTTPS origin/path 白名单。
- 设备 token、签名密钥和用户身份参数全部视为凭证。
- 核心生成幂等键，或明确学校接口自身的幂等语义。
- MVP 先 official-only，不向 release 第三方 adapter 开放物理副作用能力。
- Android 先行；iOS 等 imperative 合规复评，或优先建设 declarative action graph。
因此结论是：
可以添加，而且架构能够承载；但不能只写一个 imperative adapter 直接上线，必须先补 mutation/actuator 契约与核心用户确认闸门。
Xidian C8
当前 C8 是一个 validator 的 mixed-mode false positive：
- Xidian notice.list 是无凭证 declarative。
- 课表、成绩、考试、空教室是 imperative，按 URL scope 隐式使用 ehall-session。
- C8 只统计 declarative requests[].credential，但又拿这个集合检查全部顶层 credentials。
- 因此错误地警告 ehall-session 未使用。
它只是 warning，不阻断校验，也不是凭证泄漏。
建议分两步处理。
第一步：修 C8
只修 validator：
- 如果 manifest 存在 imperative capability，当前无法静态断言顶层 credential 未使用。
- mixed-mode 不应产生 C8_unused_credential。
- 纯 declarative manifest 仍保留 unused warning。
- declarative 引用不存在 credential 仍保持 error。
这属于 validator bugfix，不改契约、不改核心、不需要 ADR。
第二步：Capability 级 credentialRefs
长期建议新增：
{
  "id": "schedule.week",
  "requestGraph": "imperative",
  "credentialRefs": ["ehall-session"]
}
这样每个 imperative capability 只能使用明确授权的 credential ref，而不是看到整个 adapter 的所有 credential scope。
关键执行语义应是：
- 先按全部顶层 credentials 找 URL 的最具体匹配。
- 再检查该 ref 是否在当前 capability 的 credentialRefs 中。
- 命中但未授权时必须 credential_not_permitted，不能退化成无凭证 passthrough。
- 每个 redirect hop 重新检查。
- 只允许收割当前 capability 获准的 durable credential。
- QuickJS 不增加任何读取凭证的 API。
这会改 contract/manifest.schema.json、Dart/TS Broker、launcher 和 adapter manifest，因此必须先开 ADR，并处理旧客户端忽略新字段的问题。要么增加 host/version gate，要么明确旧客户端只能保持 legacy 权限，不能宣称具备 capability 隔离。
建议顺序
 1. 修复 C8 mixed-mode warning，并补对应 validator 回归测试。
 2. 按已接受 ADR-020 落地 query credential，接通 Xidian 一卡通。
 3. 起草 capability 级 credentialRefs ADR，收窄 imperative 最小权限。
 4. 起草 body/form credential 注入 ADR，为图书馆和可能的空调签名请求提供共同基础。
 5. 先实现图书馆只读能力，再为续借、预约创建/取消建立 mutation capability。
 6. 起草 climate actuator ADR，先做 Android official-only 的固定 HTTPS endpoint。
 7. 补 UI：课表、成绩、考试、空教室、一卡通、图书馆和设备控制入口。
 8. 使用脱敏测试账号做 Android/iOS 真机验收；真实凭证和学生数据不得进入 fixture。
 9. 正式签名发布 Xidian 0.3.1 或后续版本，并统一主仓旧 adapter、bootstrap 和外部 adapter 的状态说明。
10. 最后处理 campus relay、备用签名密钥、iOS 正式签名/App Store、OHOS 和多校正式目录。
最合理的近期里程碑是：先完成 C8 修复 + ADR-020 OpenID + Xidian 一卡通闭环，再启动图书馆 body 凭证 ADR；空调与图书馆 mutation 共用一套“用户主动副作用能力”原则，但保持不同 capability。
