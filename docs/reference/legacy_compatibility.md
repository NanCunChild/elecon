# V1 兼容维护边界

> 当前规则，依据 [ADR-041](../adr/adr_041_current_architecture.md)。历史正文在 [archived](../archived/README.md)；归档不表示实现已退役。

| 路径 | 仍须保持 | 不向新路线扩散的内容 |
|---|---|---|
| V1 official bundle / catalog / revocation | official 验签、身份绑定、吊销、安装字节和版本检查 | 不要求用户授权源码包走签名仪式 |
| V1 Broker / requestGraph / Masker | adapter 不见凭据及其等价物；原有限域、响应处理、负例测试 | 不为新学校协议增加 DSL/Masker 算子 |
| V1 DEV profile / C3 | 未迁移入口继续原编译和执行门；ADR-033 本地 bundle 导入仍未落地 | 新源码安装不依赖 DEV，也不能作为 V1 验签通行证 |
| 已存在的领域 schema / validators | 维持字段含义、版本和规范化结果 | 不把 shared schema 与旧执行机制绑为一体 |
| 平台凭据存储 / transport | 密钥保护、学校身份隔离、编译内原生能力与平台限制 | 不从归档推断可侧载原生代码 |
| V1 public 分发与 campus stub | 公网零凭据，未实现的校内 relay 继续明确失败 | 不把部署命令或 schema.origin 枚举当作中继已上线 |

历史签收记录保留在 [V1 状态快照](../archived/2026-10-31/docs/adr/README.md)与[整改快照](../archived/2026-10-31/docs/planning/2026_08_review_remediation.md)。后续触碰对应代码时，针对实际变更补充验证和人工审阅，不要求先完成历史全部整改，也不能把它们批量勾成已完成。

删除旧执行路径前，逐项检查 bootstrap/回退、测试、签名发布工具、平台构建及用户安装迁移；确认没有活跃消费者，另提单一目的变更。文档归档本身不删除任何兼容代码。

## 历史红线编号

代码/ADR 中的“红线 #n”按[归档总则](../archived/2026-10-31/AGENTS.pre-2026-10-31.md)解释；新总则用 B 编号，避免旧引用静默改义。

| 历史编号 | 原含义 | 当前承接 |
|---|---|---|
| #1 | 路线对应的凭据访问 | B2、B7 |
| #2 / #3 | 公网零凭据 / 私密数据不经公网 | B3 |
| #4 | 明确执行授权 | B1、B7 |
| #5 | 脚本学校流程与宿主能力边界 | B4、B7 |
| #6 | 契约与 ADR | B5 |
| #7 | 背景执行 | B4 |
| #8 | 脱敏数据 | B8 |
| #9 | 依赖许可证 | B9 |
| #10 | 架构先有 ADR | B5、B10 |
