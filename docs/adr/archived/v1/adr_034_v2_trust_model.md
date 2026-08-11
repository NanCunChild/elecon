# ADR-034：V2 adapter 信任与执行边界

- **状态**：已接受（Accepted）
- **日期**：2026-08-11
- **决策纪元**：V2
- **适用范围**：adapter 的执行准入、凭证可见性、Credential Store、宿主网络出口与本地导入
- **覆盖**：ADR-000 §3.1/§3.3、ADR-002 的 adapter 信任档、ADR-009 的凭证不可见保证、ADR-012 的 adapter 凭证边界、ADR-013、ADR-014 的 ctx 凭证面、ADR-022、ADR-023、ADR-024 的 adapter DEPLOY/DEV 隔离、ADR-026、ADR-028、ADR-029 的 opaque 注入部分、ADR-031、ADR-033
- **不覆盖**：公网服务端零凭证、私密数据不经公网、QuickJS isolate、标准数据 schema、transport official-only、bundle 完整性与官方发布治理

---

## 1. 背景

V1 把 adapter 视为需要对其隐藏凭证值的受限代码。为兑现该边界，项目逐步引入 Broker 自动注入、声明式 request graph、`bind/compute/inject`、不透明句柄、封闭计算词表和 mandatory Response Masker。

这些机制降低了善意 adapter 意外泄漏凭证的概率，但也显著抬高了 adapter 的开发、调试、文档和跨端维护成本。项目的第一目标仍是以较少维护人力吸引学校 adapter 作者并快速响应学校接口变化。V2 决定改变信任前提，不再以“adapter 永远看不到凭证”作为产品保证。

---

## 2. 决策

### 2.1 adapter 是用户或项目选择信任的本地程序

V2 不把已获执行信任的 adapter 视为凭证隔离边界之外的不可信解析器。adapter 一旦获准执行，即可：

- 读取 Credential Store 中的全部凭证；
- 写入、更新或删除 Credential Store 中的凭证；
- 读取认证请求的原始业务响应与协议中间值；
- 使用宿主提供的 adapter 能力，不再按凭证类型或 capability 逐项确认。

因此 V2 明确不保证已受信 adapter 不会读取、复制、记录或外传用户凭证及私密数据。用户信任本地 adapter digest，即表示接受该 adapter 对本应用内全部凭证和 adapter 数据的访问风险。

### 2.2 MVP 只有两种执行信任来源

MVP 的执行准入只有两条路径：

1. **official**：通过项目官方验签、身份绑定、吊销和兼容门的 adapter 自动受信，不要求用户确认凭证、网络或高风险 capability 权限。
2. **local unsigned**：用户导入本地 bundle，并明确选择信任该 bundle 的内容 digest。信任只绑定该 digest；内容变化产生新 digest，必须重新选择信任。

manifest 不得自报执行信任或 official 身份。official 由宿主的官方 verifier 裁定；local unsigned 由本地 digest trust 记录裁定。

MVP 不实现：

- 用户自签；
- 第三方发布者证书链；
- “信任某签名者后自动信任其更新”。

未来可增加签名者信任，但不得把“签名有效”自动等价为 official，也不得让 adapter 自报签名者信任。

### 2.3 不建立细粒度用户授权系统

V2 不为以下项目分别弹窗或建立 grant：

- 单个 credential ref；
- 单个 capability；
- 登录、SSO、actuator 等高风险 adapter 能力；
- 每次请求或每次凭证访问。

用户的决策单位是整个 adapter bundle：official 自动信任，local unsigned 按 digest 整体信任。安装界面可以展示来源、digest、声明的出网范围和风险，但这些信息不构成细粒度运行授权。

### 2.4 Credential Store 使用复合键，但不宣称 adapter 间隔离

Credential Store 必须使用结构化复合身份，避免不同学校、账户、服务或凭证名称发生无意重名。精确 schema 由后继凭证 ADR 固定，至少应表达：

- 用户 profile / account；
- school / tenant；
- credential provider 或 service；
- credential name / kind。

宿主 API 不得继续以全局裸字符串 `get("session")` 作为唯一寻址方式。

复合键只解决命名和误覆盖问题，不是针对恶意 adapter 的完整性边界。已受信 adapter 能读取全部键，也能按 API 规则写入 Credential Store；V2 接受受信 adapter 篡改或删除凭证的风险。

### 2.5 Broker 凭证隔离体系退役

V2 不继续运营以下机制：

- 凭证值永不进入 adapter 的保证；
- Broker 自动代 adapter 完成全部凭证注入；
- declarative / imperative 双 requestGraph；
- `bind/compute/inject`；
- opaque handle；
- 为 opaque flow 建立的跨端封闭 crypto op；
- mandatory Response Masker；
- 以 DEV/DEPLOY profile 隔离 unsigned adapter 执行。

adapter 使用统一的异步 JS API，自行读取所需凭证、自行构造请求并解析响应。V1 Broker 中与上述机制绑定的代码和测试应在 V2 替代门建立后删除，不保留长期双栈。

### 2.6 宿主网络出口仍是强制边界

V2 adapter 不获得 raw socket、Node 网络模块、WebView、原生 FFI 或其他旁路网络能力。所有 adapter 出网必须经过宿主网络 API。

宿主继续强制：

- scheme、host、port、path 和 method 范围；
- 重定向逐跳复核；
- 请求数量、请求体、响应体、超时和取消预算；
- loopback、link-local、私网地址和 DNS 解析策略；
- transport 选择与 TLS 边界。

出网控制只限制 adapter 可以连接的位置，不进行通用内容 DLP。adapter 获得凭证后，可以将其编码进获准目标的 URL、header 或 body；V2 不声称宿主能识别或阻止此类行为。

### 2.7 official 发布治理继续保留

官方 bundle 的签名、YubiKey/PKCS#11 ceremony、catalog sequence、bundle digest、身份绑定、吊销和 release ledger 继续保留。其语义是项目对特定字节的审查与背书，并为官方自动更新和事后吊销提供治理能力。

local unsigned bundle 不进入官方 catalog，不享有官方更新或吊销保证。用户可以撤销本地 digest trust、禁用或删除该 adapter。

### 2.8 平台策略

- Android、desktop 及允许该能力的平台可提供 local unsigned 导入入口。
- iOS MVP 只允许运行 official adapter。本地导入相关代码可以存在，但 UI 入口必须关闭，loader/runtime 也必须执行 official-only 门，不能把隐藏入口作为唯一控制。
- transport 在所有平台继续 official-only；adapter 导入自由不得扩展到原生 transport。

### 2.9 继续成立的边界

以下 V1 原则在 V2 继续成立：

- 公网服务端零凭证、无私密数据持久化；
- 私密数据只走客户端直连或校内授权中继；
- adapter 在 QuickJS/background isolate 中运行；
- UI 只消费标准 schema，adapter 不直接控制原生渲染；
- 测试夹具不得含真实学生数据；
- 新依赖继续受许可证规则约束；
- transport 不向 adapter 开放侧载。

---

## 3. 安全语义

V2 的安全承诺是：

> 未获执行信任的 bundle 不运行；已获执行信任的 adapter 被限制在 QuickJS、宿主 API、网络出口和资源预算内，但对应用持有的 adapter 凭证与私密响应视为受信。

V2 不再承诺：

- 对已受信 adapter 隐藏凭证；
- 防止已受信 adapter 向获准网络目标泄漏凭证或私密数据；
- official adapter 的每项敏感能力均由用户逐项批准；
- local unsigned adapter 获得官方审查、更新或吊销保障。

签名、代码审查、静态检查和出网范围只能降低风险，不能证明 adapter 不泄漏数据。

---

## 4. 迁移约束

迁移顺序必须是：

1. 更新总则、契约和 V2 安全测试；
2. 建立 digest trust、平台 gate、复合 Credential Store API 和宿主唯一出网口；
3. 转换现有 declarative adapter 为统一异步 JS；
4. 验证 official 与 local unsigned 两条执行路径；
5. 删除 declarative/dataflow/opaque handle/Masker 和旧 trust profile；
6. 更新 signer、catalog、release 文档中的 V2 语义。

不得先删除 V1 门禁，再补 V2 的 digest trust、平台 gate 或出网门。

---

## 5. 后继 ADR

以下内容需要独立后继 ADR 后才能修改契约或实现：

- Manifest V2 与统一 adapter SDK；
- Credential Store 复合键和读写 API；
- host egress canonicalization 与地址策略；
- local bundle 导入、digest trust 和更新语义；
- iOS 分发与 App Store 合规结论。
