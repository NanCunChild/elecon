# 规则 · 测试原则

配合 [`AGENTS.md`](../../AGENTS.md) 阅读。一条主原则：**信任与能力越高的组件，测试越严格。** 测试的严格度沿信任链递增。

---

## 1. 严格度分级（按信任）

| 组件 | 信任/能见度 | 测试要求 |
|---|---|---|
| 执行信任 / Credential Store / 宿主网络出口 | 最高（决定代码能否运行、profile/namespace 隔离、出网不可绕过） | 最严：单元 + 集成 + 安全用例（未受信不执行、digest 绑定、iOS official-only、跨 profile 永久拒绝、namespace/mode 越权拒绝、复合键、出口越界在 transport 前被拒）。**AI 不得独自编写并作为唯一作者**，需人工审阅。 |
| 传输底座 | 看到全部流量 | 严：连接生命周期、失败降级、签名校验、不泄露明文边界。 |
| official adapter | 自动受信；完整控制当前 profile 的 self namespace，同 profile 跨 adapter 访问受 manifest mode 上限 | 夹具驱动归一化回归 + namespace 越权负例 + 出网范围合规 + 官方发布治理。 |
| local signed adapter | 首次确认 signer；同 signer 更新按权限 diff；完整控制当前 profile 的 self namespace | 与 official 使用同一 sandbox/schema/出网测试；另测 signer identity、扩权确认、identity 冲突、bytecode-only 风险和跨 profile拒绝。 |
| local unsigned adapter（过渡） | 首次按 digest 受信；signed local 就绪后仅留一个稳定版本 | 另测无效签名不降级、退役版本门和最终所有 artifact 不含 unsigned grant。 |

---

## 2. 夹具驱动（Fixture-driven）

- **CI 不打真实学校接口**：学校接口会变、需鉴权，live 测试既不稳定又有合规风险。真实学校 adapter 由 `adapters.pin` 固定的外部仓提供，测试使用其 `adapters/school-<id>/fixtures/` 脱敏样本；本仓 `adapters_tests/` 只保留探针、研究证据与脱敏回归材料。
- **Fixture expected-output**：固定“脱敏响应/mock transport → 期望标准 schema 或错误”，归一化逻辑变更必须先更新 expected output 并解释原因。fixture 不是客户端/服务端 runtime 等价证明。
- **夹具必须脱敏**：见红线 #8，样本中不得含真实学生姓名、学号、token 等。脱敏在采样阶段完成，提交前由 `tools/` 的校验器扫描。

---

## 3. 契约一致性

- **schema 一致性**：adapter 输出、UI 输入、`contract/schema/` 三者必须对得上，由 CI 自动校验。
- **manifest 合规**：adapter 声明的能力与域名白名单合法、无越界，由 `tools/` 静态校验。
- **客户端 runtime 权威**：adapter 的产品行为以全平台共用的客户端 QuickJS/host API 契约为准。服务端工具可预检 fixture，但不得宣称与客户端逐字节、逐异常或逐调度等价；official 发布必须包含目标客户端 runtime 的 fixture replay 证据（ADR-001 §4.5–§4.9）。

---

## 4. 性能与并发

- **不卡顿是机制保证，不是测出来的**：在测试里断言 adapter 不在 UI isolate 同步执行（核心 runtime 的契约测试）。
- adapter 性能问题几乎都来自 I/O 与并发纪律，不来自脚本本身；性能测试聚焦"是否阻塞 UI / 是否正确异步"，而非脚本微基准。

---

## 5. AI 与测试

- AI 生成的逻辑代码**必须同时附带测试**，无测试不合并。
- **安全敏感路径**（核心/凭证/传输/签名）：AI 写的实现，其测试需由人工编写或至少人工实质性审阅——避免"AI 写代码 + AI 写测试"自证正确的闭环。
- 测试本身也算改动：AI 不得通过放宽断言/删除用例来"让 CI 变绿"，这类改动需在 PR 显式说明理由。
